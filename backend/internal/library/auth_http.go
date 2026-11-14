package library

import (
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

type userContextKey struct{}

func currentUser(r *http.Request) User { u, _ := r.Context().Value(userContextKey{}).(User); return u }
func authFailure(w http.ResponseWriter, err error) {
	var e *authError
	if errors.As(err, &e) {
		writeError(w, e.status, e.message)
	} else {
		internalError(w, err)
	}
}
func decodeAuth(w http.ResponseWriter, r *http.Request, input any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(input); err != nil {
		writeError(w, 400, "invalid JSON payload")
		return false
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		writeError(w, 400, "expected a single JSON object")
		return false
	}
	return true
}

// Bound both password hashing concurrency and attempts per remote IP. Forwarded headers
// are intentionally ignored: a client must not be able to choose its limiter key.
type authAttempt struct {
	start time.Time
	count int
}
type authLimiter struct {
	mu       sync.Mutex
	attempts map[string]authAttempt
	hashing  chan struct{}
}

func (l *authLimiter) allow(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	for ip, a := range l.attempts {
		if now.Sub(a.start) >= time.Minute {
			delete(l.attempts, ip)
		}
	}
	a, ok := l.attempts[host]
	if !ok {
		if len(l.attempts) >= 4096 {
			return false
		}
		a.start = now
	}
	if a.count >= 10 {
		return false
	}
	a.count++
	l.attempts[host] = a
	return true
}
func registerAuthRoutes(mux *http.ServeMux, s *Store) {
	limiter := &authLimiter{attempts: map[string]authAttempt{}, hashing: make(chan struct{}, 4)}
	for _, action := range []string{"login", "signup"} {
		mux.HandleFunc("POST /v1/auth/"+action, func(w http.ResponseWriter, r *http.Request) {
			if !limiter.allow(r) {
				w.Header().Set("Retry-After", "60")
				writeError(w, 429, "too many authentication attempts; try again in a minute")
				return
			}
			select {
			case limiter.hashing <- struct{}{}:
				defer func() { <-limiter.hashing }()
			default:
				w.Header().Set("Retry-After", "1")
				writeError(w, 429, "authentication is busy; try again shortly")
				return
			}
			var input struct {
				Email      string `json:"email"`
				Password   string `json:"password"`
				InviteCode string `json:"inviteCode"`
			}
			if !decodeAuth(w, r, &input) {
				return
			}
			if len(input.Password) > 1024 {
				writeError(w, 400, "password is too long")
				return
			}
			var result AuthResult
			var err error
			status := 200
			if action == "signup" {
				result, err = s.signup(r.Context(), input.Email, input.Password, input.InviteCode)
				status = 201
			} else {
				result, err = s.login(r.Context(), input.Email, input.Password)
			}
			if err != nil {
				authFailure(w, err)
				return
			}
			writeJSON(w, status, result)
		})
	}
	mux.HandleFunc("GET /v1/auth/me", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, currentUser(r)) })
	mux.HandleFunc("POST /v1/auth/logout", func(w http.ResponseWriter, r *http.Request) {
		if _, err := s.db.ExecContext(r.Context(), "DELETE FROM sessions WHERE token_hash=?", secretHash(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))); err != nil {
			internalError(w, err)
			return
		}
		w.WriteHeader(204)
	})
	mux.HandleFunc("PUT /v1/auth/password", func(w http.ResponseWriter, r *http.Request) {
		var input struct {
			CurrentPassword string `json:"currentPassword"`
			Password        string `json:"password"`
		}
		if !decodeAuth(w, r, &input) {
			return
		}
		var oldHash string
		err := s.db.QueryRowContext(r.Context(), "SELECT password_hash FROM users WHERE id=?", currentUser(r).ID).Scan(&oldHash)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, 400, "bootstrap an admin account before changing its password")
			return
		}
		if err != nil {
			internalError(w, err)
			return
		}
		if len(input.CurrentPassword) > 1024 || !passwordMatches(oldHash, input.CurrentPassword) {
			writeError(w, 401, "invalid current password")
			return
		}
		hash, err := passwordHash(input.Password)
		if err != nil {
			authFailure(w, err)
			return
		}
		tx, err := s.db.BeginTx(r.Context(), nil)
		if err != nil {
			internalError(w, err)
			return
		}
		defer tx.Rollback()
		result, err := tx.ExecContext(r.Context(), "UPDATE users SET password_hash=? WHERE id=? AND password_hash=?", hash, currentUser(r).ID, oldHash)
		if err != nil {
			internalError(w, err)
			return
		}
		n, err := result.RowsAffected()
		if err != nil {
			internalError(w, err)
			return
		}
		if n != 1 {
			writeError(w, 409, "password changed concurrently; sign in again")
			return
		}
		if _, err = tx.ExecContext(r.Context(), "DELETE FROM sessions WHERE user_id=?", currentUser(r).ID); err != nil {
			internalError(w, err)
			return
		}
		if err = tx.Commit(); err != nil {
			internalError(w, err)
			return
		}
		w.WriteHeader(204)
	})
	mux.HandleFunc("POST /v1/admin/invites", func(w http.ResponseWriter, r *http.Request) {
		input := struct {
			ExpiresInHours int `json:"expiresInHours"`
		}{ExpiresInHours: 168}
		if !decodeAuth(w, r, &input) {
			return
		}
		invite, err := s.createInvite(r.Context(), currentUser(r).ID, input.ExpiresInHours)
		if err != nil {
			authFailure(w, err)
			return
		}
		writeJSON(w, 201, invite)
	})
	mux.HandleFunc("GET /v1/admin/invites", func(w http.ResponseWriter, r *http.Request) {
		rows, err := s.db.QueryContext(r.Context(), "SELECT id,created_by,expires_at,used_by,revoked FROM invites ORDER BY expires_at DESC,id")
		if err != nil {
			internalError(w, err)
			return
		}
		defer rows.Close()
		invites := []Invite{}
		for rows.Next() {
			var invite Invite
			if err = rows.Scan(&invite.ID, &invite.CreatedBy, &invite.ExpiresAt, &invite.UsedBy, &invite.Revoked); err != nil {
				internalError(w, err)
				return
			}
			invites = append(invites, invite)
		}
		if err = rows.Err(); err != nil {
			internalError(w, err)
			return
		}
		writeJSON(w, 200, invites)
	})
	mux.HandleFunc("DELETE /v1/admin/invites/{id}", func(w http.ResponseWriter, r *http.Request) {
		result, err := s.db.ExecContext(r.Context(), "UPDATE invites SET revoked=1 WHERE id=?", r.PathValue("id"))
		if err != nil {
			internalError(w, err)
			return
		}
		n, err := result.RowsAffected()
		if err != nil {
			internalError(w, err)
			return
		}
		if n == 0 {
			writeError(w, 404, "invite not found")
			return
		}
		w.WriteHeader(204)
	})
	mux.HandleFunc("GET /v1/admin/users", func(w http.ResponseWriter, r *http.Request) {
		rows, err := s.db.QueryContext(r.Context(), "SELECT "+userColumns+" FROM users ORDER BY created_at,id")
		if err != nil {
			internalError(w, err)
			return
		}
		defer rows.Close()
		users := []User{}
		for rows.Next() {
			u, err := scanUser(rows)
			if err != nil {
				internalError(w, err)
				return
			}
			users = append(users, u)
		}
		if err = rows.Err(); err != nil {
			internalError(w, err)
			return
		}
		writeJSON(w, 200, users)
	})
	mux.HandleFunc("PATCH /v1/admin/users/{id}", func(w http.ResponseWriter, r *http.Request) {
		var input struct {
			Role     *string `json:"role"`
			Disabled *bool   `json:"disabled"`
		}
		if !decodeAuth(w, r, &input) {
			return
		}
		u, err := s.updateUser(r.Context(), r.PathValue("id"), input.Role, input.Disabled)
		if err != nil {
			authFailure(w, err)
			return
		}
		writeJSON(w, 200, u)
	})
}
