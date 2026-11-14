package library

import (
	"context"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"
)

const passwordIterations = 600000
const sessionLifetime = 30 * 24 * time.Hour

type User struct {
	DisplayName string `json:"displayName,omitempty"`
	ID          string `json:"id"`
	Email       string `json:"email"`
	Role        string `json:"role"`
	Disabled    bool   `json:"disabled"`
	CreatedAt   int64  `json:"createdAt"`
}
type Invite struct {
	ID        string `json:"id"`
	Code      string `json:"code,omitempty"`
	CreatedBy string `json:"createdBy"`
	ExpiresAt int64  `json:"expiresAt"`
	UsedBy    string `json:"usedBy,omitempty"`
	Revoked   bool   `json:"revoked"`
}
type AuthResult struct {
	User      User   `json:"user"`
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expiresAt"`
}
type authError struct {
	status  int
	message string
}

func (e *authError) Error() string             { return e.message }
func badAuth(status int, message string) error { return &authError{status, message} }

func (s *Store) initAuth() error {
	// Copy legacy records once, preserving existing client data in the first admin account.
	_, err := s.db.Exec(`BEGIN;
 CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, email TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, role TEXT NOT NULL CHECK(role IN ('admin','user')), disabled INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL, expires_at INTEGER NOT NULL);
 CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
 CREATE TABLE IF NOT EXISTS invites (id TEXT PRIMARY KEY, code_hash TEXT NOT NULL UNIQUE, created_by TEXT NOT NULL, expires_at INTEGER NOT NULL, used_by TEXT NOT NULL DEFAULT '', revoked INTEGER NOT NULL DEFAULT 0);
 CREATE TABLE IF NOT EXISTS user_reader_records (user_id TEXT NOT NULL, id TEXT NOT NULL, document TEXT NOT NULL, updated_at INTEGER NOT NULL, device_id TEXT NOT NULL, PRIMARY KEY(user_id,id));
 INSERT OR IGNORE INTO user_reader_records SELECT 'legacy',id,document,updated_at,device_id FROM reader_records;
 DROP TABLE reader_records;
 COMMIT;`)
	return err
}
func randomSecret() string { return hex.EncodeToString(randomBytes(32)) }
func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}
func secretHash(secret string) string {
	h := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(h[:])
}
func passwordHash(password string) (string, error) {
	if !utf8.ValidString(password) || utf8.RuneCountInString(password) < 12 || len(password) > 1024 {
		return "", badAuth(400, "password must contain at least 12 characters and at most 1024 bytes")
	}
	salt := randomBytes(16)
	key, err := pbkdf2.Key(sha256.New, password, salt, passwordIterations, 32)
	return hex.EncodeToString(salt) + ":" + hex.EncodeToString(key), err
}
func passwordMatches(encoded, password string) bool {
	parts := strings.Split(encoded, ":")
	if len(parts) != 2 {
		return false
	}
	salt, e1 := hex.DecodeString(parts[0])
	expected, e2 := hex.DecodeString(parts[1])
	if e1 != nil || e2 != nil || len(salt) != 16 || len(expected) != 32 {
		return false
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, passwordIterations, 32)
	return err == nil && subtle.ConstantTimeCompare(key, expected) == 1
}
func normalizeEmail(email string) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	address, err := mail.ParseAddress(email)
	if err != nil || address.Address != email || len(email) > 254 {
		return "", badAuth(400, "a valid email address is required")
	}
	return email, nil
}

// BootstrapAdmin creates the first account only. Its ID retains the legacy reading history.
func (s *Store) BootstrapAdmin(ctx context.Context, email, password string) (User, error) {
	email, err := normalizeEmail(email)
	if err != nil {
		return User{}, err
	}
	hash, err := passwordHash(password)
	if err != nil {
		return User{}, err
	}
	u := User{ID: "legacy", Email: email, Role: "admin", CreatedAt: time.Now().Unix()}
	result, err := s.db.ExecContext(ctx, `INSERT INTO users(id,email,password_hash,role,created_at) SELECT ?,?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM users)`, u.ID, u.Email, hash, u.Role, u.CreatedAt)
	if err != nil {
		return User{}, err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return User{}, err
	}
	if n == 0 {
		return User{}, badAuth(409, "accounts already exist; use admin user management")
	}
	return u, nil
}
func scanUser(row interface{ Scan(...any) error }) (User, error) {
	var u User
	err := row.Scan(&u.ID, &u.Email, &u.Role, &u.Disabled, &u.CreatedAt)
	return u, err
}

const userColumns = "id,email,role,disabled,created_at"

func (s *Store) authenticate(ctx context.Context, token string) (User, error) {
	u, err := scanUser(s.db.QueryRowContext(ctx, `SELECT u.id,u.email,u.role,u.disabled,u.created_at FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.token_hash=? AND s.expires_at>? AND u.disabled=0`, secretHash(token), time.Now().Unix()))
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, badAuth(401, "a valid bearer token is required")
	}
	return u, err
}
func insertSession(ctx context.Context, tx *sql.Tx, u User) (AuthResult, error) {
	result := AuthResult{User: u, Token: randomSecret(), ExpiresAt: time.Now().Add(sessionLifetime).Unix()}
	if _, err := tx.ExecContext(ctx, "DELETE FROM sessions WHERE expires_at<=?", time.Now().Unix()); err != nil {
		return AuthResult{}, err
	}
	_, err := tx.ExecContext(ctx, "INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?)", secretHash(result.Token), u.ID, result.ExpiresAt)
	return result, err
}
func (s *Store) login(ctx context.Context, email, password string) (AuthResult, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	var u User
	var hash string
	err := s.db.QueryRowContext(ctx, "SELECT "+userColumns+",password_hash FROM users WHERE email=?", email).Scan(&u.ID, &u.Email, &u.Role, &u.Disabled, &u.CreatedAt, &hash)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return AuthResult{}, err
	}
	// Use the same expensive verification for unknown accounts.
	if errors.Is(err, sql.ErrNoRows) {
		hash = strings.Repeat("0", 32) + ":" + strings.Repeat("0", 64)
	}
	valid := passwordMatches(hash, password)
	if !valid || err != nil || u.Disabled {
		return AuthResult{}, badAuth(401, "invalid email or password")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AuthResult{}, err
	}
	defer tx.Rollback()
	// Recheck the password and status after hashing, in case credentials changed concurrently.
	var currentHash string
	var disabled bool
	if err = tx.QueryRowContext(ctx, "SELECT password_hash,disabled FROM users WHERE id=?", u.ID).Scan(&currentHash, &disabled); err != nil {
		return AuthResult{}, err
	}
	if disabled || currentHash != hash {
		return AuthResult{}, badAuth(401, "invalid email or password")
	}
	result, err := insertSession(ctx, tx, u)
	if err != nil {
		return AuthResult{}, err
	}
	return result, tx.Commit()
}
func (s *Store) signup(ctx context.Context, email, password, code string) (AuthResult, error) {
	email, err := normalizeEmail(email)
	if err != nil {
		return AuthResult{}, err
	}
	hash, err := passwordHash(password)
	if err != nil {
		return AuthResult{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AuthResult{}, err
	}
	defer tx.Rollback()
	u := User{ID: randomSecret(), Email: email, Role: "user", CreatedAt: time.Now().Unix()}
	// Consume the invite and create the account in one transaction; rollback restores it on failure.
	result, err := tx.ExecContext(ctx, `UPDATE invites SET used_by=? WHERE code_hash=? AND used_by='' AND revoked=0 AND expires_at>?`, u.ID, secretHash(code), time.Now().Unix())
	if err != nil {
		return AuthResult{}, err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return AuthResult{}, err
	}
	if n != 1 {
		return AuthResult{}, badAuth(400, "invalid, expired, or used invite code")
	}
	result, err = tx.ExecContext(ctx, `INSERT INTO users(id,email,password_hash,role,created_at) VALUES(?,?,?,?,?) ON CONFLICT(email) DO NOTHING`, u.ID, email, hash, u.Role, u.CreatedAt)
	if err != nil {
		return AuthResult{}, err
	}
	n, err = result.RowsAffected()
	if err != nil {
		return AuthResult{}, err
	}
	if n != 1 {
		return AuthResult{}, badAuth(409, "email is already registered")
	}
	auth, err := insertSession(ctx, tx, u)
	if err != nil {
		return AuthResult{}, err
	}
	return auth, tx.Commit()
}
func (s *Store) createInvite(ctx context.Context, creator string, hours int) (Invite, error) {
	if hours < 1 || hours > 24*30 {
		return Invite{}, badAuth(400, "expiresInHours must be between 1 and 720")
	}
	invite := Invite{ID: randomSecret(), Code: randomSecret(), CreatedBy: creator, ExpiresAt: time.Now().Add(time.Duration(hours) * time.Hour).Unix()}
	_, err := s.db.ExecContext(ctx, "INSERT INTO invites(id,code_hash,created_by,expires_at) VALUES(?,?,?,?)", invite.ID, secretHash(invite.Code), creator, invite.ExpiresAt)
	return invite, err
}
func (s *Store) updateUser(ctx context.Context, id string, role *string, disabled *bool) (User, error) {
	if role != nil && *role != "admin" && *role != "user" {
		return User{}, badAuth(400, "role must be admin or user")
	}
	if role == nil && disabled == nil {
		return User{}, badAuth(400, "role or disabled is required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return User{}, err
	}
	defer tx.Rollback()
	u, err := scanUser(tx.QueryRowContext(ctx, "SELECT "+userColumns+" FROM users WHERE id=?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, badAuth(404, "user not found")
	}
	if err != nil {
		return User{}, err
	}
	wasAdmin := u.Role == "admin" && !u.Disabled
	if role != nil {
		u.Role = *role
	}
	if disabled != nil {
		u.Disabled = *disabled
	}
	if wasAdmin && (u.Role != "admin" || u.Disabled) {
		var count int
		if err = tx.QueryRowContext(ctx, "SELECT count(*) FROM users WHERE role='admin' AND disabled=0").Scan(&count); err != nil {
			return User{}, err
		}
		if count <= 1 {
			return User{}, badAuth(409, "cannot remove the last active admin")
		}
	}
	if _, err = tx.ExecContext(ctx, "UPDATE users SET role=?,disabled=? WHERE id=?", u.Role, u.Disabled, id); err != nil {
		return User{}, err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM sessions WHERE user_id=?", id); err != nil {
		return User{}, err
	}
	return u, tx.Commit()
}
