package library

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
)

func Handler(store *Store, token string, catalogs ...*ZLibrary) http.Handler {
	mux := http.NewServeMux()
	registerReaderRoutes(mux, store)
	registerNarrationRoutes(mux, store)
	registerAuthRoutes(mux, store)
	registerProcessingRoutes(mux, store)
	var catalog *ZLibrary
	if len(catalogs) > 0 {
		catalog = catalogs[0]
	}
	registerZLibraryRoutes(mux, store, catalog)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, 200, map[string]string{"status": "ok"}) })
	mux.HandleFunc("GET /v1/books", func(w http.ResponseWriter, r *http.Request) {
		books, err := store.List(r.Context())
		if err != nil {
			internalError(w, err)
			return
		}
		q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
		category := r.URL.Query().Get("category")
		result := []Book{}
		for _, b := range books {
			text := b.Title + " " + b.Author + " " + b.Subtitle + " " + b.Category + " " + b.Synopsis
			for _, section := range append(append([]Section{}, b.Sections...), b.Chapters...) {
				text += " " + section.Title + " " + section.Body
			}
			if (category == "" || b.Category == category) && (q == "" || strings.Contains(strings.ToLower(text), q)) {
				result = append(result, b)
			}
		}
		writeJSON(w, 200, result)
	})
	mux.HandleFunc("GET /v1/books/{id}", func(w http.ResponseWriter, r *http.Request) {
		b, err := store.Get(r.Context(), r.PathValue("id"))
		if handleStoreError(w, err) {
			return
		}
		writeJSON(w, 200, b)
	})
	mux.HandleFunc("PUT /v1/books/{id}", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 2<<20)
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		var b Book
		if err := dec.Decode(&b); err != nil {
			writeError(w, 400, "invalid book JSON: "+err.Error())
			return
		}
		if err := dec.Decode(&struct{}{}); err != io.EOF {
			writeError(w, 400, "expected a single JSON object")
			return
		}
		if b.ID != r.PathValue("id") {
			writeError(w, 400, "book id must match URL")
			return
		}
		if err := b.Validate(); err != nil {
			writeError(w, 400, err.Error())
			return
		}
		if err := store.Put(r.Context(), b); err != nil {
			internalError(w, err)
			return
		}
		saved, err := store.Get(r.Context(), b.ID)
		if handleStoreError(w, err) {
			return
		}
		writeJSON(w, 200, saved)
	})
	mux.HandleFunc("DELETE /v1/books/{id}", func(w http.ResponseWriter, r *http.Request) {
		if handleStoreError(w, store.Delete(r.Context(), r.PathValue("id"))) {
			return
		}
		w.WriteHeader(204)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		// Native clients need no CORS. Reject browser-origin writes to the local service.
		if r.Header.Get("Origin") != "" && r.Method != http.MethodGet && r.Method != http.MethodHead {
			writeError(w, 403, "browser-origin writes are not allowed")
			return
		}
		public := r.URL.Path == "/healthz" || (r.Method == http.MethodPost && (r.URL.Path == "/v1/auth/login" || r.URL.Path == "/v1/auth/signup"))
		if !public {
			var user User
			authorization := r.Header.Get("Authorization")
			if token != "" && subtle.ConstantTimeCompare([]byte(authorization), []byte("Bearer "+token)) == 1 {
				user = User{ID: "legacy", Role: "admin"}
			} else {
				if !strings.HasPrefix(authorization, "Bearer ") || len(authorization) > 256 {
					writeError(w, 401, "a valid bearer token is required")
					return
				}
				var err error
				user, err = store.authenticate(r.Context(), strings.TrimPrefix(authorization, "Bearer "))
				if err != nil {
					authFailure(w, err)
					return
				}
			}
			adminOnly := strings.HasPrefix(r.URL.Path, "/v1/admin/") || (strings.HasPrefix(r.URL.Path, "/v1/books/") && r.Method != http.MethodGet && r.Method != http.MethodHead)
			if adminOnly && user.Role != "admin" {
				writeError(w, 403, "admin access is required")
				return
			}
			var name string
			if err := store.db.QueryRowContext(r.Context(), "SELECT display_name FROM user_profiles WHERE user_id=?", user.ID).Scan(&name); err == nil {
				user.DisplayName = name
			}
			r = r.WithContext(context.WithValue(r.Context(), userContextKey{}, user))
		}
		mux.ServeHTTP(w, r)
	})
}

func registerReaderRoutes(mux *http.ServeMux, store *Store) {
	mux.HandleFunc("POST /v1/sync", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 5<<20)
		var input struct {
			Records []ReaderRecord `json:"records"`
		}
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		if err := dec.Decode(&input); err != nil {
			writeError(w, 400, "invalid sync payload")
			return
		}
		if err := dec.Decode(&struct{}{}); err != io.EOF {
			writeError(w, 400, "expected one sync payload")
			return
		}
		if len(input.Records) > 500 {
			writeError(w, 400, "at most 500 records per batch")
			return
		}
		for _, record := range input.Records {
			if err := record.Validate(); err != nil {
				writeError(w, 400, err.Error())
				return
			}
		}
		records, err := store.syncUser(r.Context(), currentUser(r).ID, input.Records)
		if err != nil {
			internalError(w, err)
			return
		}
		writeJSON(w, 200, map[string]any{"records": records})
	})
	mux.HandleFunc("PUT /v1/books/{id}/source", func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 50<<20)
		data, err := io.ReadAll(r.Body)
		if err != nil {
			writeError(w, 413, "PDF must be at most 50 MiB")
			return
		}
		if !bytes.Contains(data[:min(1024, len(data))], []byte("%PDF-")) {
			writeError(w, 400, "expected a PDF file")
			return
		}
		filename := filepath.Base(r.URL.Query().Get("filename"))
		if filename == "." || filename == "" {
			filename = "book.pdf"
		}
		if len(filename) > 300 {
			writeError(w, 400, "filename is too long")
			return
		}
		source, err := store.PutSource(r.Context(), r.PathValue("id"), filename, data)
		if handleStoreError(w, err) {
			return
		}
		writeJSON(w, 200, source)
	})
	mux.HandleFunc("GET /v1/books/{id}/source", func(w http.ResponseWriter, r *http.Request) {
		data, err := store.GetSource(r.Context(), r.PathValue("id"))
		if handleStoreError(w, err) {
			return
		}
		w.Header().Set("Content-Type", "application/pdf")
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
		w.Header().Set("Cache-Control", "no-store")
		w.Write(data)
	})
}
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
func internalError(w http.ResponseWriter, err error) {
	slog.Error("request failed", "error", err)
	writeError(w, 500, "database operation failed")
}
func handleStoreError(w http.ResponseWriter, err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, ErrNotFound) {
		writeError(w, 404, err.Error())
	} else {
		internalError(w, err)
	}
	return true
}
