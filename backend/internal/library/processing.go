package library

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Upload attribution is server-owned and deliberately excludes account email addresses.
type Uploader struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}
type ProcessingJob struct {
	ID             string   `json:"id"`
	Kind           string   `json:"kind"`
	Status         string   `json:"status"`
	Filename       string   `json:"filename"`
	BookID         string   `json:"bookID"`
	Provider       string   `json:"provider"`
	UploadedBy     Uploader `json:"uploadedBy"`
	Progress       string   `json:"progress"`
	Error          string   `json:"error"`
	CreatedAt      int64    `json:"createdAt"`
	UpdatedAt      int64    `json:"updatedAt"`
	Attempts       int      `json:"attempts"`
	SummaryMinutes int      `json:"summaryMinutes"`
	CatalogID      string   `json:"catalogID"`
	Title          string   `json:"title"`
	Author         string   `json:"author"`
	Cover          string   `json:"cover"`
}

const jobColumns = "id,kind,status,filename,book_id,provider,user_id,user_name,progress,error,created_at,updated_at,attempts,summary_minutes,catalog_id,title,author,cover"

func scanJob(row interface{ Scan(...any) error }) (j ProcessingJob, err error) {
	err = row.Scan(&j.ID, &j.Kind, &j.Status, &j.Filename, &j.BookID, &j.Provider, &j.UploadedBy.ID, &j.UploadedBy.Name, &j.Progress, &j.Error, &j.CreatedAt, &j.UpdatedAt, &j.Attempts, &j.SummaryMinutes, &j.CatalogID, &j.Title, &j.Author, &j.Cover)
	return
}
func (s *Store) initProcessing() error {
	_, err := s.db.Exec(`CREATE TABLE IF NOT EXISTS processing_jobs (
 id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL, filename TEXT NOT NULL DEFAULT '',
 book_id TEXT NOT NULL DEFAULT '', provider TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL, user_name TEXT NOT NULL,
 progress TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
 attempts INTEGER NOT NULL DEFAULT 0, lease TEXT NOT NULL DEFAULT '', lease_until INTEGER NOT NULL DEFAULT 0,
 pdf BLOB, input_hash TEXT NOT NULL DEFAULT '', summary_minutes INTEGER NOT NULL DEFAULT 10);
 CREATE INDEX IF NOT EXISTS processing_queue ON processing_jobs(status,created_at);
 CREATE TABLE IF NOT EXISTS user_profiles(user_id TEXT PRIMARY KEY,display_name TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS book_uploaders(book_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,user_name TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS processing_provenance(book_id TEXT PRIMARY KEY,document TEXT NOT NULL);`)
	if err != nil {
		return err
	}
	rows, err := s.db.Query("PRAGMA table_info(processing_jobs)")
	if err != nil {
		return err
	}
	columns := map[string]bool{}
	for rows.Next() {
		var cid, notNull, primaryKey int
		var name, dataType string
		var defaultValue sql.NullString
		if err = rows.Scan(&cid, &name, &dataType, &notNull, &defaultValue, &primaryKey); err != nil {
			rows.Close()
			return err
		}
		columns[name] = true
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for _, column := range []struct{ name, definition string }{
		{"summary_minutes", "INTEGER NOT NULL DEFAULT 10"},
		{"catalog_id", "TEXT NOT NULL DEFAULT ''"}, {"title", "TEXT NOT NULL DEFAULT ''"},
		{"author", "TEXT NOT NULL DEFAULT ''"}, {"cover", "TEXT NOT NULL DEFAULT ''"},
	} {
		if !columns[column.name] {
			if _, err = s.db.Exec("ALTER TABLE processing_jobs ADD COLUMN " + column.name + " " + column.definition); err != nil {
				return err
			}
		}
	}

	return err
}
func uploaderFor(u User) Uploader {
	name := u.DisplayName
	if name == "" {
		if u.ID == "legacy" {
			name = "Library admin"
		} else {
			name = "Reader " + u.ID[:min(8, len(u.ID))]
		}
	}
	return Uploader{u.ID, name}
}
func (s *Store) listJobs(ctx context.Context, u User) ([]ProcessingJob, error) {
	query := "SELECT " + jobColumns + " FROM processing_jobs"
	args := []any{}
	if u.Role != "admin" {
		query += " WHERE user_id=?"
		args = append(args, u.ID)
	}
	rows, err := s.db.QueryContext(ctx, query+" ORDER BY created_at DESC,id LIMIT 100", args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []ProcessingJob{}
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, j)
	}
	return result, rows.Err()
}
func (s *Store) getJob(ctx context.Context, id string) (ProcessingJob, error) {
	return scanJob(s.db.QueryRowContext(ctx, "SELECT "+jobColumns+" FROM processing_jobs WHERE id=?", id))
}

type JobSource struct{ ID, Title, Author, Cover string }

func (s *Store) queueUpload(ctx context.Context, u User, kind, filename string, input []byte, summaryMinutes int, sources ...JobSource) (ProcessingJob, error) {
	if summaryMinutes != 10 && summaryMinutes != 30 {
		return ProcessingJob{}, badAuth(400, "Choose a 10 or 30 minute summary.")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ProcessingJob{}, err
	}
	defer tx.Rollback()
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM processing_jobs WHERE user_id=? AND status NOT IN ('complete','failed')", u.ID).Scan(&count); err != nil {
		return ProcessingJob{}, err
	}
	if count >= 3 {
		return ProcessingJob{}, badAuth(429, "You already have three jobs in progress. Wait for one to finish.")
	}
	var total int
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM processing_jobs WHERE status NOT IN ('complete','failed')").Scan(&total); err != nil {
		return ProcessingJob{}, err
	}
	if total >= 100 {
		return ProcessingJob{}, badAuth(429, "The processing queue is full. Try again later.")
	}
	sum := sha256.Sum256(input)
	hash := hex.EncodeToString(sum[:])
	var existing string
	err = tx.QueryRowContext(ctx, "SELECT id FROM processing_jobs WHERE user_id=? AND input_hash=? AND kind=? AND summary_minutes=? AND (status NOT IN ('complete','failed') OR (status='complete' AND EXISTS(SELECT 1 FROM books WHERE books.id=processing_jobs.book_id))) LIMIT 1", u.ID, hash, kind, summaryMinutes).Scan(&existing)
	if err == nil {
		return ProcessingJob{}, badAuth(409, "This file has already been uploaded. Check your processing queue.")
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return ProcessingJob{}, err
	}
	now := time.Now().Unix()
	by := uploaderFor(u)
	id := "job-" + randomSecret()[:24]
	source := JobSource{}
	if len(sources) > 0 {
		source = sources[0]
	}
	_, err = tx.ExecContext(ctx, `INSERT INTO processing_jobs(id,kind,status,filename,book_id,user_id,user_name,created_at,updated_at,pdf,input_hash,summary_minutes,catalog_id,title,author,cover) VALUES(?,?,'queued',?,?,?,?,?,?,?,?,?,?,?,?,?)`, id, kind, filename, "upload-"+randomSecret()[:24], u.ID, by.Name, now, now, input, hash, summaryMinutes, source.ID, source.Title, source.Author, source.Cover)
	if err != nil {
		return ProcessingJob{}, err
	}
	if err = tx.Commit(); err != nil {
		return ProcessingJob{}, err
	}
	return s.getJob(ctx, id)
}
func (s *Store) queuePDF(ctx context.Context, u User, filename string, pdf []byte) (ProcessingJob, error) {
	return s.queueUpload(ctx, u, "pdf", filename, pdf, 10)
}
func bookTextHash(b Book) string {
	var raw []byte // Hash only narration input; existing audio must not affect job identity.
	parts := make([]string, len(b.Sections))
	for i, p := range b.Sections {
		parts[i] = p.Body
	}
	raw, _ = json.Marshal(parts)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}
func (s *Store) queueNarration(ctx context.Context, u User, id, provider string) (ProcessingJob, error) {
	if provider != "elevenlabs" && provider != "openrouter" {
		return ProcessingJob{}, badAuth(400, "Choose ElevenLabs or OpenRouter narration.")
	}
	b, err := s.Get(ctx, id)
	if err != nil {
		return ProcessingJob{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return ProcessingJob{}, err
	}
	defer tx.Rollback()
	var count int
	err = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM processing_jobs WHERE kind='narration' AND book_id=? AND status NOT IN ('complete','failed')", id).Scan(&count)
	if err != nil {
		return ProcessingJob{}, err
	}
	if count > 0 {
		return ProcessingJob{}, badAuth(409, "Narration is already queued for this book.")
	}
	now := time.Now().Unix()
	by := uploaderFor(u)
	jobID := "job-" + randomSecret()[:24]
	_, err = tx.ExecContext(ctx, `INSERT INTO processing_jobs(id,kind,status,book_id,provider,user_id,user_name,created_at,updated_at,input_hash) VALUES(?,'narration','queued',?,?,?,?,?,?,?)`, jobID, id, provider, u.ID, by.Name, now, now, bookTextHash(b))
	if err != nil {
		return ProcessingJob{}, err
	}
	if err = tx.Commit(); err != nil {
		return ProcessingJob{}, err
	}
	return s.getJob(ctx, jobID)
}
func uploadKind(name string, input []byte) string {
	kind := ""
	switch strings.ToLower(filepath.Ext(name)) {
	case ".pdf":
		if len(input) >= 5 && bytes.Contains(input[:min(1024, len(input))], []byte("%PDF-")) {
			kind = "pdf"
		}
	case ".epub":
		if archive, e := zip.NewReader(bytes.NewReader(input), int64(len(input))); e == nil {
			if len(archive.File) <= 5000 {
				for _, file := range archive.File {
					if file.Name == "META-INF/container.xml" {
						kind = "epub"
						break
					}
				}
			}
		}
	}
	return kind
}

func registerProcessingRoutes(mux *http.ServeMux, s *Store) {
	mux.HandleFunc("POST /v1/uploads", func(w http.ResponseWriter, r *http.Request) {
		summaryMinutes := 10
		if raw := r.URL.Query().Get("summaryMinutes"); raw != "" {
			var err error
			summaryMinutes, err = strconv.Atoi(raw)
			if err != nil || (summaryMinutes != 10 && summaryMinutes != 30) {
				writeError(w, 400, "Choose a 10 or 30 minute summary.")
				return
			}
		}
		r.Body = http.MaxBytesReader(w, r.Body, 50<<20)
		input, err := io.ReadAll(r.Body)
		if err != nil {
			writeError(w, 413, "PDF or EPUB must be at most 50 MiB")
			return
		}
		name := filepath.Base(r.URL.Query().Get("filename"))
		kind := uploadKind(name, input)
		if kind == "" {
			writeError(w, 400, "Choose a valid PDF or EPUB file.")
			return
		}
		if len(name) > 300 {
			writeError(w, 400, "Filename is too long.")
			return
		}
		job, err := s.queueUpload(r.Context(), currentUser(r), kind, name, input, summaryMinutes)
		if err != nil {
			authFailure(w, err)
			return
		}
		writeJSON(w, 202, job)
	})
	mux.HandleFunc("GET /v1/jobs", func(w http.ResponseWriter, r *http.Request) {
		jobs, err := s.listJobs(r.Context(), currentUser(r))
		if err != nil {
			internalError(w, err)
			return
		}
		writeJSON(w, 200, jobs)
	})
	mux.HandleFunc("POST /v1/jobs/{id}/retry", func(w http.ResponseWriter, r *http.Request) {
		job, err := s.getJob(r.Context(), r.PathValue("id"))
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, 404, "Job not found")
			return
		}
		if err != nil {
			internalError(w, err)
			return
		}
		u := currentUser(r)
		if job.UploadedBy.ID != u.ID && u.Role != "admin" {
			writeError(w, 404, "Job not found")
			return
		}
		if job.Kind == "narration" && u.Role != "admin" {
			writeError(w, 403, "Admin access is required.")
			return
		}
		result, err := s.db.ExecContext(r.Context(), "UPDATE processing_jobs SET status='queued',error='',progress='',lease='',lease_until=0,attempts=0,updated_at=? WHERE id=? AND status='failed' AND (kind NOT IN ('pdf','epub') OR (SELECT COUNT(*) FROM processing_jobs active WHERE active.user_id=processing_jobs.user_id AND active.status NOT IN ('complete','failed'))<3) AND (SELECT COUNT(*) FROM processing_jobs active WHERE active.status NOT IN ('complete','failed'))<100", time.Now().Unix(), job.ID)
		if err != nil {
			internalError(w, err)
			return
		}
		n, _ := result.RowsAffected()
		if n != 1 {
			writeError(w, 409, "Only failed jobs with an available queue slot can be retried.")
			return
		}
		job, _ = s.getJob(r.Context(), job.ID)
		writeJSON(w, 202, job)
	})
	mux.HandleFunc("POST /v1/admin/books/{id}/narration", func(w http.ResponseWriter, r *http.Request) {
		var input struct {
			Provider string `json:"provider"`
		}
		if !decodeAuth(w, r, &input) {
			return
		}
		if input.Provider == "" {
			input.Provider = "openrouter"
		}
		job, err := s.queueNarration(r.Context(), currentUser(r), r.PathValue("id"), input.Provider)
		if errors.Is(err, ErrNotFound) {
			writeError(w, 404, "Book not found")
			return
		}
		if err != nil {
			authFailure(w, err)
			return
		}
		writeJSON(w, 202, job)
	})
	mux.HandleFunc("PUT /v1/auth/profile", func(w http.ResponseWriter, r *http.Request) {
		var input struct {
			Name string `json:"displayName"`
		}
		if !decodeAuth(w, r, &input) {
			return
		}
		input.Name = strings.TrimSpace(input.Name)
		if input.Name == "" || len(input.Name) > 80 || strings.ContainsAny(input.Name, "\r\n\t") {
			writeError(w, 400, "Choose a display name of 1–80 bytes.")
			return
		}
		_, err := s.db.ExecContext(r.Context(), "INSERT INTO user_profiles(user_id,display_name) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET display_name=excluded.display_name", currentUser(r).ID, input.Name)
		if err != nil {
			internalError(w, err)
			return
		}
		u := currentUser(r)
		u.DisplayName = input.Name
		writeJSON(w, 200, u)
	})
}

func (s *Store) claimJob(ctx context.Context) (ProcessingJob, string, error) {
	if _, err := s.db.ExecContext(ctx, "UPDATE processing_jobs SET status='failed',error='The worker was interrupted repeatedly. Retry this job after checking worker health.',lease='',lease_until=0 WHERE status IN ('extracting','summarizing','narrating') AND lease_until<? AND attempts>=3", time.Now().Unix()); err != nil {
		return ProcessingJob{}, "", err
	}

	lease := randomSecret()
	now := time.Now().Unix()
	// A single atomic UPDATE RETURNING also works across independent worker processes.
	j, err := scanJob(s.db.QueryRowContext(ctx, `UPDATE processing_jobs SET status=CASE WHEN kind IN ('pdf','epub') THEN 'extracting' ELSE 'narrating' END,lease=?,lease_until=?,attempts=attempts+1,updated_at=?
 WHERE id=(SELECT id FROM processing_jobs WHERE status='queued' OR (status IN ('extracting','summarizing','narrating') AND lease_until<?) ORDER BY created_at,id LIMIT 1) RETURNING `+jobColumns, lease, now+120, now, now))
	return j, lease, err
}
func (s *Store) jobProgress(ctx context.Context, id, lease, status, message string) error {
	result, err := s.db.ExecContext(ctx, "UPDATE processing_jobs SET status=?,progress=?,updated_at=?,lease_until=? WHERE id=? AND lease=?", status, message, time.Now().Unix(), time.Now().Unix()+120, id, lease)
	if err != nil {
		return err
	}
	n, _ := result.RowsAffected()
	if n != 1 {
		return errors.New("job lease expired")
	}
	return nil
}
func (s *Store) finishJob(ctx context.Context, id, lease string, err error) {
	status, message := "complete", ""
	if err != nil {
		status = "failed"
		message = err.Error()
		if len(message) > 500 {
			message = message[:500]
		}
	}
	s.db.ExecContext(ctx, "UPDATE processing_jobs SET status=?,error=?,lease='',lease_until=0,updated_at=? WHERE id=? AND lease=?", status, message, time.Now().Unix(), id, lease)
}
func (s *Store) publishProcessed(ctx context.Context, j ProcessingJob, lease string, b Book, pdf []byte, provenance json.RawMessage) error {
	b.ID = j.BookID
	b.CoverURL = j.Cover
	b.UploadedBy = nil
	if err := b.Validate(); err != nil {
		return fmt.Errorf("Generated summary failed validation: %w", err)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var active string
	if err = tx.QueryRowContext(ctx, "SELECT lease FROM processing_jobs WHERE id=?", j.ID).Scan(&active); err != nil {
		return err
	}
	if active != lease {
		return errors.New("job lease expired")
	}
	raw, _ := json.Marshal(b)
	sum := sha256.Sum256(pdf)
	_, err = tx.ExecContext(ctx, "INSERT INTO books(id,document,updated_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET document=excluded.document,updated_at=excluded.updated_at", b.ID, string(raw), b.UpdatedAt)
	if err != nil {
		return err
	}
	if j.Kind == "pdf" {
		_, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO sources(book_id,filename,sha256,pdf) VALUES(?,?,?,?)", b.ID, j.Filename, hex.EncodeToString(sum[:]), pdf)
		if err != nil {
			return err
		}
	}
	_, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO book_uploaders(book_id,user_id,user_name) VALUES(?,?,?)", b.ID, j.UploadedBy.ID, j.UploadedBy.Name)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, "INSERT OR REPLACE INTO processing_provenance(book_id,document) VALUES(?,?)", b.ID, string(provenance))
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE processing_jobs SET status='complete',progress='Ready',error='',lease='',lease_until=0,updated_at=? WHERE id=? AND lease=?", time.Now().Unix(), j.ID, lease); err != nil {
		return err
	}
	return tx.Commit()
}
