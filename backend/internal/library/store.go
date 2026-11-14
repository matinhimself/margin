package library

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	_ "github.com/mattn/go-sqlite3"
)

var ErrNotFound = errors.New("book not found")

type Store struct{ db *sql.DB }

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
 CREATE TABLE IF NOT EXISTS books (id TEXT PRIMARY KEY, document TEXT NOT NULL, updated_at TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS reader_records (id TEXT PRIMARY KEY, document TEXT NOT NULL, updated_at INTEGER NOT NULL, device_id TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS narrations (book_id TEXT NOT NULL, section_index INTEGER NOT NULL, sha256 TEXT NOT NULL, audio BLOB NOT NULL, PRIMARY KEY(book_id,section_index));
 CREATE TABLE IF NOT EXISTS sources (book_id TEXT PRIMARY KEY, filename TEXT NOT NULL, sha256 TEXT NOT NULL, pdf BLOB NOT NULL);`)
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("initialize database: %w", err)
	}
	store := &Store{db: db}
	if err := store.initAuth(); err != nil {
		db.Close()
		return nil, fmt.Errorf("initialize accounts: %w", err)
	}
	if err := store.initProcessing(); err != nil {
		db.Close()
		return nil, fmt.Errorf("initialize processing: %w", err)
	}
	return store, nil
}
func (s *Store) Close() error { return s.db.Close() }
func (s *Store) List(ctx context.Context) ([]Book, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT b.document, COALESCE(s.filename,''), COALESCE(s.sha256,''), COALESCE(u.user_id,''), COALESCE(u.user_name,'') FROM books b LEFT JOIN sources s ON b.id=s.book_id LEFT JOIN book_uploaders u ON b.id=u.book_id ORDER BY b.updated_at DESC, b.id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	books := []Book{}
	for rows.Next() {
		var raw string
		var source Source
		var uploader Uploader
		if err := rows.Scan(&raw, &source.Filename, &source.SHA256, &uploader.ID, &uploader.Name); err != nil {
			return nil, err
		}
		var b Book
		if err := json.Unmarshal([]byte(raw), &b); err != nil {
			return nil, err
		}
		if uploader.ID != "" {
			b.UploadedBy = &uploader
		}
		if source.Filename != "" {
			b.Source = &source
		}
		books = append(books, b)
	}
	return books, rows.Err()
}
func (s *Store) Get(ctx context.Context, id string) (Book, error) {
	var raw string
	var source Source
	var uploader Uploader
	err := s.db.QueryRowContext(ctx, "SELECT b.document, COALESCE(s.filename,''), COALESCE(s.sha256,''), COALESCE(u.user_id,''), COALESCE(u.user_name,'') FROM books b LEFT JOIN sources s ON b.id=s.book_id LEFT JOIN book_uploaders u ON b.id=u.book_id WHERE b.id = ?", id).Scan(&raw, &source.Filename, &source.SHA256, &uploader.ID, &uploader.Name)
	if errors.Is(err, sql.ErrNoRows) {
		return Book{}, ErrNotFound
	}
	if err != nil {
		return Book{}, err
	}
	var b Book
	err = json.Unmarshal([]byte(raw), &b)
	if uploader.ID != "" {
		b.UploadedBy = &uploader
	}
	if source.Filename != "" {
		b.Source = &source
	}
	return b, err
}
func (s *Store) Put(ctx context.Context, b Book) error { return s.Import(ctx, []Book{b}) }

// Import validates the entire batch before making an atomic transaction.
func (s *Store) Import(ctx context.Context, books []Book) error {
	seen := map[string]bool{}
	for i := range books {
		if err := books[i].Validate(); err != nil {
			return fmt.Errorf("book %d: %w", i+1, err)
		}
		if seen[books[i].ID] {
			return fmt.Errorf("duplicate id: %s", books[i].ID)
		}
		seen[books[i].ID] = true
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, b := range books {
		raw, err := json.Marshal(b)
		if err != nil {
			return err
		}
		if _, err = tx.ExecContext(ctx, `INSERT INTO books(id,document,updated_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET document=excluded.document, updated_at=excluded.updated_at`, b.ID, string(raw), b.UpdatedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}
func (s *Store) Delete(ctx context.Context, id string) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	r, err := tx.ExecContext(ctx, "DELETE FROM books WHERE id = ?", id)
	if err != nil {
		return err
	}
	n, err := r.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM sources WHERE book_id=?", id); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM narrations WHERE book_id=?", id); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM book_uploaders WHERE book_id=?", id); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM processing_provenance WHERE book_id=?", id); err != nil {
		return err
	}
	// Preserve personal notes and history even when a book is removed.
	return tx.Commit()
}
