package library

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"
)

type PipelineResult struct {
	Book       Book            `json:"book"`
	Provenance json.RawMessage `json:"provenance"`
}

// RunWorker is deliberately a separate process from the HTTP server. Leases survive
// restarts; a heartbeat keeps long PDF jobs from being claimed twice.
func (s *Store) RunWorker(ctx context.Context, root, script string) error {
	if err := os.MkdirAll(root, 0700); err != nil {
		return err
	}
	for ctx.Err() == nil {
		job, lease, err := s.claimJob(ctx)
		if errors.Is(err, sql.ErrNoRows) {
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(3 * time.Second):
			}
			continue
		}
		if err != nil {
			return err
		}
		jobCtx, cancel := context.WithTimeout(ctx, 90*time.Minute)
		done := make(chan struct{})
		go func() {
			ticker := time.NewTicker(20 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-done:
					return
				case <-jobCtx.Done():
					return
				case <-ticker.C:
					result, err := s.db.ExecContext(jobCtx, "UPDATE processing_jobs SET lease_until=? WHERE id=? AND lease=?", time.Now().Unix()+120, job.ID, lease)
					if err != nil {
						cancel()
						return
					}
					n, _ := result.RowsAffected()
					if n != 1 {
						cancel()
						return
					}
				}
			}
		}()
		err = s.processJob(jobCtx, job, lease, root, script)
		close(done)
		cancel()
		// On graceful shutdown leave the lease resumable rather than marking failure.
		if ctx.Err() != nil {
			return nil
		}
		s.finishJob(context.Background(), job.ID, lease, err)
		if err != nil {
			log.Printf("Processing job %s failed", job.ID)
		} else {
			log.Printf("Processing job %s complete", job.ID)
		}
	}
	return nil
}
func runPipeline(ctx context.Context, script, kind, dir string) error {
	command := exec.CommandContext(ctx, "python3", script, kind, dir)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return nil
		}
		return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
	}
	command.WaitDelay = 5 * time.Second
	// Provider errors/logs can contain private source content. Keep diagnostics in
	// the private work directory, and only expose a bounded, curated error message.
	logFile, err := os.OpenFile(filepath.Join(dir, "pipeline.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	command.Stdout = logFile
	command.Stderr = logFile
	if err = command.Run(); err != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("Processing timed out or was interrupted. Retry this job.")
		}
		message, _ := os.ReadFile(filepath.Join(dir, "error.txt"))
		if len(message) > 0 {
			return errors.New(string(message[:min(len(message), 400)]))
		}
		return errors.New("Processing failed. An admin can inspect the worker diagnostics and retry.")
	}
	return nil
}
func (s *Store) processJob(ctx context.Context, j ProcessingJob, lease, root, script string) error {
	dir := filepath.Join(root, j.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	os.Remove(filepath.Join(dir, "error.txt"))
	if j.Kind == "pdf" || j.Kind == "epub" {
		var pdf []byte
		if err := s.db.QueryRowContext(ctx, "SELECT pdf FROM processing_jobs WHERE id=?", j.ID).Scan(&pdf); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "source."+j.Kind), pdf, 0600); err != nil {
			return err
		}
		message := "Extracting EPUB chapters"
		if j.Kind == "pdf" {
			message = "Extracting PDF text and checking scanned pages"
		}
		if err := s.jobProgress(ctx, j.ID, lease, "extracting", message); err != nil {
			return err
		}
		if err := runPipeline(ctx, script, "extract", dir); err != nil {
			return err
		}
		if err := s.jobProgress(ctx, j.ID, lease, "summarizing", "Reading the source and writing the summary"); err != nil {
			return err
		}
		options, _ := json.Marshal(map[string]int{"minutes": j.SummaryMinutes})
		if err := os.WriteFile(filepath.Join(dir, "summary-options.json"), options, 0600); err != nil {
			return err
		}
		if err := runPipeline(ctx, script, "summarize", dir); err != nil {
			return err
		}
		raw, err := os.ReadFile(filepath.Join(dir, "result.json"))
		if err != nil {
			return err
		}
		if len(raw) > 20<<20 {
			return errors.New("Processed book exceeds the output size limit.")
		}
		var result PipelineResult
		if err = json.Unmarshal(raw, &result); err != nil {
			return errors.New("Codex returned invalid summary data. Retry this job.")
		}
		if len(result.Book.Sections) == 0 || len(result.Book.Chapters) == 0 {
			return errors.New("The generated book is missing summary or extracted text.")
		}
		return s.publishProcessed(ctx, j, lease, result.Book, pdf, result.Provenance)
	}
	if j.Kind != "narration" {
		return errors.New("Unknown processing job type")
	}
	b, err := s.Get(ctx, j.BookID)
	if err != nil {
		return err
	}
	var hash string
	if err = s.db.QueryRowContext(ctx, "SELECT input_hash FROM processing_jobs WHERE id=?", j.ID).Scan(&hash); err != nil {
		return err
	}
	if hash != bookTextHash(b) {
		return errors.New("The summary changed after narration was queued. Start a new narration job.")
	}
	for index, section := range b.Sections {
		sum := sha256.Sum256([]byte(section.Body))
		bodyHash := hex.EncodeToString(sum[:])
		// A retry resumes completed sections without charging for them again.
		if n := section.Narration; n != nil && n.Provider == j.Provider && n.SHA256 != "" && n.BodySHA256 == bodyHash {
			continue
		}
		if err = s.jobProgress(ctx, j.ID, lease, "narrating", fmt.Sprintf("Narrating idea %d of %d", index+1, len(b.Sections))); err != nil {
			return err
		}
		input, _ := json.Marshal(map[string]string{"text": section.Body, "provider": j.Provider, "language": b.Language})
		if err = os.WriteFile(filepath.Join(dir, "narration-input.json"), input, 0600); err != nil {
			return err
		}
		if err = runPipeline(ctx, script, "narrate", dir); err != nil {
			return err
		}
		raw, err := os.ReadFile(filepath.Join(dir, "alignment.json"))
		if err != nil {
			return err
		}
		var n Narration
		if err = json.Unmarshal(raw, &n); err != nil {
			return err
		}
		audio, err := os.ReadFile(filepath.Join(dir, "audio.mp3"))
		if err != nil {
			return err
		}
		if err = s.saveGeneratedNarration(ctx, j, lease, index, bodyHash, n, audio); err != nil {
			return err
		}
	}
	return nil
}
func (s *Store) saveGeneratedNarration(ctx context.Context, j ProcessingJob, lease string, index int, bodyHash string, n Narration, audio []byte) error {
	if len(audio) < 3 || len(audio) > 25<<20 || !(string(audio[:3]) == "ID3" || audio[0] == 0xff && audio[1]&0xe0 == 0xe0) {
		return errors.New("Narration provider returned invalid MP3 audio.")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var active, raw string
	if err = tx.QueryRowContext(ctx, "SELECT lease FROM processing_jobs WHERE id=?", j.ID).Scan(&active); err != nil {
		return err
	}
	if active != lease {
		return errors.New("job lease expired")
	}
	if err = tx.QueryRowContext(ctx, "SELECT document FROM books WHERE id=?", j.BookID).Scan(&raw); err != nil {
		return errors.New("Book no longer exists.")
	}
	var b Book
	if err = json.Unmarshal([]byte(raw), &b); err != nil {
		return err
	}
	if index >= len(b.Sections) {
		return errors.New("Summary changed during narration.")
	}
	sum := sha256.Sum256([]byte(b.Sections[index].Body))
	if hex.EncodeToString(sum[:]) != bodyHash {
		return errors.New("Summary changed during narration. Start a new narration job.")
	}
	audioHash := sha256.Sum256(audio)
	n.SHA256 = hex.EncodeToString(audioHash[:])
	n.BodySHA256 = bodyHash
	b.Sections[index].Narration = &n
	if err = b.Validate(); err != nil {
		return fmt.Errorf("Generated word timing is invalid: %w", err)
	}
	data, _ := json.Marshal(b)
	_, err = tx.ExecContext(ctx, "INSERT INTO narrations(book_id,section_index,sha256,audio) VALUES(?,?,?,?) ON CONFLICT(book_id,section_index) DO UPDATE SET sha256=excluded.sha256,audio=excluded.audio", b.ID, index, n.SHA256, audio)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, "UPDATE books SET document=?,updated_at=? WHERE id=?", string(data), b.UpdatedAt, b.ID)
	if err != nil {
		return err
	}
	return tx.Commit()
}
