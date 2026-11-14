package library

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

// Each annotation, bookmark, and reading session is its own sync record.
// Tombstones participate in the same deterministic last-write-wins ordering.
type ReaderRecord struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	BookID     string `json:"bookID"`
	BookTitle  string `json:"bookTitle"`
	UpdatedAt  int64  `json:"updatedAt"`
	DeviceID   string `json:"deviceID"`
	Deleted    bool   `json:"deleted"`
	Location   string `json:"location"`
	Section    int    `json:"section"`
	Completed  bool   `json:"completed"`
	Value      bool   `json:"value"`
	Text       string `json:"text"`
	Quote      string `json:"quote"`
	Color      string `json:"color"`
	Seconds    int    `json:"seconds"`
	Day        string `json:"day"`
	Offset     int    `json:"offset"`
	Length     int    `json:"length"`
	SourceHash string `json:"sourceHash"`
}

func (r ReaderRecord) Validate() error {
	if len(r.ID) < 1 || len(r.ID) > 240 || len(r.DeviceID) < 1 || len(r.DeviceID) > 100 || r.UpdatedAt < 1 || r.UpdatedAt > time.Now().Add(24*time.Hour).UnixMilli() {
		return errors.New("invalid sync identity or timestamp (check the device clock)")
	}
	if len(r.BookID) > 80 || len(r.BookTitle) > 300 || len(r.Text) > 100000 || len(r.Quote) > 100000 || len(r.Color) > 20 {
		return errors.New("sync record is too large")
	}
	if r.Location != "summary" && r.Location != "chapter" && r.Location != "pdf" {
		return errors.New("invalid reading location")
	}
	if r.Section < 0 || r.Section > 100000 {
		return errors.New("invalid section/page")
	}
	if r.Offset < 0 || r.Length < 0 || r.Offset > 1000000 || r.Length > 100000 {
		return errors.New("invalid highlight range")
	}
	if len(r.SourceHash) > 64 {
		return errors.New("invalid source hash")
	}
	if r.Kind != "goal" && strings.TrimSpace(r.BookID) == "" {
		return errors.New("bookID is required")
	}
	switch r.Kind {
	case "progress", "saved":
		expected := r.Kind + ":" + r.BookID
		if r.Kind == "progress" {
			expected += ":" + r.Location
		}
		if r.ID != expected {
			return errors.New("invalid state record id")
		}
	case "bookmark":
		if r.ID != fmt.Sprintf("bookmark:%s:%s:%d", r.BookID, r.Location, r.Section) {
			return errors.New("invalid bookmark id")
		}
	case "annotation":
		if !strings.HasPrefix(r.ID, "annotation:") || (!r.Deleted && strings.TrimSpace(r.Text) == "" && strings.TrimSpace(r.Quote) == "") {
			return errors.New("an annotation needs a note or highlighted quotation")
		}
	case "session":
		if !strings.HasPrefix(r.ID, "session:") || r.Seconds < 1 || r.Seconds > 3600 {
			return errors.New("invalid reading session")
		}
		day, err := time.Parse("2006-01-02", r.Day)
		if err != nil || day.Format("2006-01-02") != r.Day {
			return errors.New("invalid session day")
		}
	case "goal":
		if r.ID != "goal" || r.Seconds < 60 || r.Seconds > 14400 {
			return errors.New("daily goal must be 1–240 minutes")
		}
	default:
		return errors.New("unknown sync record kind")
	}
	return nil
}

func (s *Store) Sync(ctx context.Context, incoming []ReaderRecord) ([]ReaderRecord, error) {
	return s.syncUser(ctx, "legacy", incoming)
}

func (s *Store) syncUser(ctx context.Context, userID string, incoming []ReaderRecord) ([]ReaderRecord, error) {
	for _, r := range incoming {
		if err := r.Validate(); err != nil {
			return nil, err
		}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	for _, r := range incoming {
		raw, _ := json.Marshal(r)
		_, err = tx.ExecContext(ctx, `INSERT INTO user_reader_records(user_id,id,document,updated_at,device_id) VALUES(?,?,?,?,?)
   ON CONFLICT(user_id,id) DO UPDATE SET document=excluded.document,updated_at=excluded.updated_at,device_id=excluded.device_id
   WHERE excluded.updated_at>user_reader_records.updated_at OR (excluded.updated_at=user_reader_records.updated_at AND excluded.device_id>user_reader_records.device_id)`, userID, r.ID, string(raw), r.UpdatedAt, r.DeviceID)
		if err != nil {
			return nil, err
		}
	}
	rows, err := tx.QueryContext(ctx, "SELECT document FROM user_reader_records WHERE user_id=? ORDER BY id", userID)
	if err != nil {
		return nil, err
	}
	records := []ReaderRecord{}
	for rows.Next() {
		var raw string
		if err = rows.Scan(&raw); err != nil {
			rows.Close()
			return nil, err
		}
		var r ReaderRecord
		if err = json.Unmarshal([]byte(raw), &r); err != nil {
			rows.Close()
			return nil, err
		}
		records = append(records, r)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return nil, err
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return records, nil
}

func (s *Store) PutSource(ctx context.Context, id, filename string, pdf []byte) (*Source, error) {
	// The conditional insert also handles a book being deleted during upload.
	hash := sha256.Sum256(pdf)
	source := &Source{Filename: filename, SHA256: hex.EncodeToString(hash[:])}
	result, err := s.db.ExecContext(ctx, `INSERT INTO sources(book_id,filename,sha256,pdf) SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM books WHERE id=?)
 ON CONFLICT(book_id) DO UPDATE SET filename=excluded.filename,sha256=excluded.sha256,pdf=excluded.pdf`, id, filename, source.SHA256, pdf, id)
	if err != nil {
		return nil, err
	}
	n, err := result.RowsAffected()
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, ErrNotFound
	}
	return source, nil
}
func (s *Store) GetSource(ctx context.Context, id string) ([]byte, error) {
	var data []byte
	err := s.db.QueryRowContext(ctx, "SELECT pdf FROM sources WHERE book_id=?", id).Scan(&data)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	return data, err
}
