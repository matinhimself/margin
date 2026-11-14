package library

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const testPassword = "a long test password"

func authJSON(t *testing.T, h http.Handler, method, path string, body any, token string, status int, result any) {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	w := request(h, method, path, string(raw), token)
	if w.Code != status {
		t.Fatalf("%s %s: got %d, want %d: %s", method, path, w.Code, status, w.Body.String())
	}
	if result != nil {
		if err = json.Unmarshal(w.Body.Bytes(), result); err != nil {
			t.Fatal(err)
		}
	}
}
func newInvite(t *testing.T, h http.Handler) Invite {
	t.Helper()
	var invite Invite
	authJSON(t, h, "POST", "/v1/admin/invites", map[string]any{}, "secret", 201, &invite)
	if len(invite.Code) != 64 {
		t.Fatal("missing invite code")
	}
	return invite
}
func signupUser(t *testing.T, h http.Handler, email string) AuthResult {
	t.Helper()
	invite := newInvite(t, h)
	var result AuthResult
	authJSON(t, h, "POST", "/v1/auth/signup", map[string]string{"email": email, "password": testPassword, "inviteCode": invite.Code}, "", 201, &result)
	return result
}
func TestAccountLifecycleAndAuthorization(t *testing.T) {
	s, h := setup(t)
	ctx := context.Background()
	if _, err := s.BootstrapAdmin(ctx, "ADMIN@example.com", testPassword); err != nil {
		t.Fatal(err)
	}
	if _, err := s.BootstrapAdmin(ctx, "other@example.com", testPassword); err == nil {
		t.Fatal("bootstrap repeated")
	}
	var admin AuthResult
	authJSON(t, h, "POST", "/v1/auth/login", map[string]string{"email": "Admin@EXAMPLE.com", "password": testPassword}, "", 200, &admin)
	user := signupUser(t, h, " Reader@example.com ")
	if user.User.Role != "user" || user.User.Email != "reader@example.com" || user.ExpiresAt <= time.Now().Unix() {
		t.Fatal(user.User)
	}
	var me User
	authJSON(t, h, "GET", "/v1/auth/me", nil, user.Token, 200, &me)
	if me.ID != user.User.ID {
		t.Fatal(me)
	}
	for _, path := range []string{"/v1/admin/users", "/v1/admin/invites"} {
		authJSON(t, h, "GET", path, nil, user.Token, 403, nil)
	}
	authJSON(t, h, "POST", "/v1/admin/invites", map[string]any{}, user.Token, 403, nil)
	for _, method := range []string{"PUT", "DELETE"} {
		authJSON(t, h, method, "/v1/books/book", sample("book"), user.Token, 403, nil)
	}
	authJSON(t, h, "PUT", "/v1/books/book/source", nil, user.Token, 403, nil)
	authJSON(t, h, "GET", "/v1/books", nil, user.Token, 200, nil)
	var users []User
	authJSON(t, h, "GET", "/v1/admin/users", nil, admin.Token, 200, &users)
	if len(users) != 2 {
		t.Fatal(users)
	}
	authJSON(t, h, "PATCH", "/v1/admin/users/legacy", map[string]any{"disabled": true}, admin.Token, 409, nil)
	authJSON(t, h, "PATCH", "/v1/admin/users/legacy", map[string]any{"role": "user"}, admin.Token, 409, nil)
	authJSON(t, h, "PATCH", "/v1/admin/users/"+user.User.ID, map[string]any{"disabled": true}, admin.Token, 200, nil)
	authJSON(t, h, "GET", "/v1/books", nil, user.Token, 401, nil)
	authJSON(t, h, "POST", "/v1/auth/login", map[string]string{"email": me.Email, "password": testPassword}, "", 401, nil)
	authJSON(t, h, "PATCH", "/v1/admin/users/"+me.ID, map[string]any{"disabled": false, "role": "admin"}, admin.Token, 200, nil)
	authJSON(t, h, "POST", "/v1/auth/login", map[string]string{"email": me.Email, "password": testPassword}, "", 200, &user)
	authJSON(t, h, "GET", "/v1/admin/users", nil, user.Token, 200, nil)
	authJSON(t, h, "POST", "/v1/auth/logout", map[string]any{}, user.Token, 204, nil)
	authJSON(t, h, "GET", "/v1/auth/me", nil, user.Token, 401, nil)
	authJSON(t, h, "PUT", "/v1/auth/password", map[string]string{"currentPassword": testPassword, "password": "a new long password"}, admin.Token, 204, nil)
	authJSON(t, h, "GET", "/v1/auth/me", nil, admin.Token, 401, nil)
	authJSON(t, h, "POST", "/v1/auth/login", map[string]string{"email": "admin@example.com", "password": testPassword}, "", 401, nil)
	authJSON(t, h, "POST", "/v1/auth/login", map[string]string{"email": "admin@example.com", "password": "a new long password"}, "", 200, &admin)
	if _, err := s.db.Exec("UPDATE sessions SET expires_at=0 WHERE token_hash=?", secretHash(admin.Token)); err != nil {
		t.Fatal(err)
	}
	authJSON(t, h, "GET", "/v1/auth/me", nil, admin.Token, 401, nil)
}

func TestInvitesAndSignupValidation(t *testing.T) {
	s, h := setup(t)
	invite := newInvite(t, h)
	signup := func(email, password, code string, status int) {
		t.Helper()
		authJSON(t, h, "POST", "/v1/auth/signup", map[string]string{"email": email, "password": password, "inviteCode": code}, "", status, nil)
	}
	signup("bad", testPassword, invite.Code, 400)
	signup("one@example.com", "short", invite.Code, 400)
	signup("one@example.com", testPassword, "wrong", 400)
	signup("one@example.com", testPassword, invite.Code, 201)
	signup("two@example.com", testPassword, invite.Code, 400)
	second := newInvite(t, h)
	signup("ONE@example.com", testPassword, second.Code, 409)
	signup("two@example.com", testPassword, second.Code, 201) // failed signup preserves invite
	revoked := newInvite(t, h)
	authJSON(t, h, "DELETE", "/v1/admin/invites/"+revoked.ID, nil, "secret", 204, nil)
	signup("three@example.com", testPassword, revoked.Code, 400)
	expired := newInvite(t, h)
	if _, err := s.db.Exec("UPDATE invites SET expires_at=0 WHERE id=?", expired.ID); err != nil {
		t.Fatal(err)
	}
	signup("three@example.com", testPassword, expired.Code, 400)
	w := request(h, "GET", "/v1/admin/invites", "", "secret")
	if w.Code != 200 || strings.Contains(w.Body.String(), invite.Code) || strings.Contains(w.Body.String(), "code_hash") {
		t.Fatal(w.Body.String())
	}
	var stored string
	if err := s.db.QueryRow("SELECT code_hash FROM invites WHERE id=?", invite.ID).Scan(&stored); err != nil || stored == invite.Code {
		t.Fatal("invite stored in plaintext", err)
	}
	h = Handler(s, "secret")
	for _, body := range []string{`{} {}`, `{"email":"one@example.com","password":"x","role":"admin"}`, `null`} {
		w := request(h, "POST", "/v1/auth/signup", body, "")
		if w.Code != 400 {
			t.Fatal(w.Code, w.Body.String())
		}
	}
}

func TestConcurrentInviteRedemption(t *testing.T) {
	s, h := setup(t)
	invite := newInvite(t, h)
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			_, err := s.signup(context.Background(), fmt.Sprintf("reader%d@example.com", i), testPassword, invite.Code)
			results <- err
		}(i)
	}
	wg.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		} else {
			var e *authError
			if !errors.As(err, &e) {
				t.Fatal(err)
			}
		}
	}
	if successes != 1 {
		t.Fatalf("%d accounts created with one invite", successes)
	}
}

func TestReaderDataIsolation(t *testing.T) {
	_, h := setup(t)
	a := signupUser(t, h, "a@example.com")
	b := signupUser(t, h, "b@example.com")
	record := ReaderRecord{ID: "goal", Kind: "goal", UpdatedAt: time.Now().UnixMilli(), DeviceID: "mac", Location: "summary", Seconds: 600}
	syncAs := func(token string, records []ReaderRecord) []ReaderRecord {
		t.Helper()
		var result struct {
			Records []ReaderRecord `json:"records"`
		}
		authJSON(t, h, "POST", "/v1/sync", map[string]any{"records": records}, token, 200, &result)
		return result.Records
	}
	syncAs(a.Token, []ReaderRecord{record})
	if got := syncAs(b.Token, nil); len(got) != 0 {
		t.Fatal("reading data leaked", got)
	}
	record.Seconds = 1200
	syncAs(b.Token, []ReaderRecord{record})
	if got := syncAs(a.Token, nil); len(got) != 1 || got[0].Seconds != 600 {
		t.Fatal("another account overwrote data", got)
	}
	if got := syncAs("secret", nil); len(got) != 0 {
		t.Fatal("legacy token reads user data", got)
	}
}

func TestAuthRequiredWithoutLegacyTokenAndRateLimit(t *testing.T) {
	s, _ := setup(t)
	h := Handler(s, "")
	authJSON(t, h, "GET", "/v1/books", nil, "", 401, nil)
	authJSON(t, h, "GET", "/healthz", nil, "", 200, nil)
	for i := 0; i < 10; i++ {
		authJSON(t, h, "POST", "/v1/auth/login", map[string]string{"email": "missing@example.com", "password": testPassword}, "", 401, nil)
	}
	authJSON(t, h, "POST", "/v1/auth/signup", map[string]any{}, "", 429, nil)
}

func TestLegacyMigrationAndAccountPersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.sqlite")
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	record := ReaderRecord{ID: "goal", Kind: "goal", UpdatedAt: time.Now().UnixMilli(), DeviceID: "mac", Location: "summary", Seconds: 600}
	raw, _ := json.Marshal(record)
	_, err = db.Exec(`CREATE TABLE reader_records (id TEXT PRIMARY KEY,document TEXT NOT NULL,updated_at INTEGER NOT NULL,device_id TEXT NOT NULL); INSERT INTO reader_records VALUES(?,?,?,?)`, record.ID, string(raw), record.UpdatedAt, record.DeviceID)
	if err != nil {
		t.Fatal(err)
	}
	db.Close()
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.BootstrapAdmin(context.Background(), "admin@example.com", testPassword); err != nil {
		t.Fatal(err)
	}
	login, err := s.login(context.Background(), "admin@example.com", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	var hash string
	if err = s.db.QueryRow("SELECT password_hash FROM users").Scan(&hash); err != nil || strings.Contains(hash, testPassword) || !passwordMatches(hash, testPassword) {
		t.Fatal("bad password storage", err)
	}
	if err = s.db.QueryRow("SELECT token_hash FROM sessions").Scan(&hash); err != nil || hash == login.Token {
		t.Fatal("bad session storage", err)
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err = s.authenticate(context.Background(), login.Token); err != nil {
		t.Fatal(err)
	}
	got, err := s.syncUser(context.Background(), login.User.ID, nil)
	if err != nil || len(got) != 1 || got[0].Seconds != 600 {
		t.Fatal("lost legacy history", got, err)
	}
}
