package library

import (
	"archive/zip"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestEPUBUploadAndPublication(t *testing.T) {
	s, h := setup(t)
	var input bytes.Buffer
	archive := zip.NewWriter(&input)
	entry, err := archive.Create("META-INF/container.xml")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = entry.Write([]byte("<container/>")); err != nil {
		t.Fatal(err)
	}
	if err = archive.Close(); err != nil {
		t.Fatal(err)
	}
	w := request(h, "POST", "/v1/uploads?filename=book.epub", input.String(), "secret")
	if w.Code != 202 {
		t.Fatal(w.Code, w.Body.String())
	}
	var job ProcessingJob
	if err = json.Unmarshal(w.Body.Bytes(), &job); err != nil || job.Kind != "epub" {
		t.Fatal(job, err)
	}
	claimed, lease, err := s.claimJob(context.Background())
	if err != nil || claimed.Kind != "epub" || claimed.Status != "extracting" {
		t.Fatal(claimed, err)
	}
	book := sample("generated")
	book.Chapters = []Section{{Title: "First chapter", Body: "Original text"}}
	if err = s.publishProcessed(context.Background(), job, lease, book, input.Bytes(), json.RawMessage(`{"kind":"epub"}`)); err != nil {
		t.Fatal(err)
	}
	saved, err := s.Get(context.Background(), job.BookID)
	if err != nil || saved.Source != nil || len(saved.Chapters) != 1 || saved.UploadedBy == nil {
		t.Fatal(saved, err)
	}
}

func TestUploadSummaryLengthAndExistingDatabase(t *testing.T) {
	s, h := setup(t)
	if _, err := s.db.Exec("ALTER TABLE processing_jobs DROP COLUMN summary_minutes"); err != nil {
		t.Fatal(err)
	}
	if err := s.initProcessing(); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		query                 string
		wantCode, wantMinutes int
	}{
		{"?filename=book.pdf", 202, 10},
		{"?filename=book.pdf&summaryMinutes=30", 202, 30},
		{"?filename=book.pdf&summaryMinutes=30", 409, 0},
		{"?filename=book.pdf&summaryMinutes=15", 400, 0},
	} {
		w := request(h, "POST", "/v1/uploads"+test.query, "%PDF-1.4 same source", "secret")
		if w.Code != test.wantCode {
			t.Fatalf("%s: %d %s", test.query, w.Code, w.Body.String())
		}
		if w.Code == 202 {
			var job ProcessingJob
			if err := json.Unmarshal(w.Body.Bytes(), &job); err != nil || job.SummaryMinutes != test.wantMinutes {
				t.Fatal(job, err)
			}
		}
	}
}

func TestPDFQueueOwnershipPublicationAndAttribution(t *testing.T) {
	s, h := setup(t)
	ctx := context.Background()
	alice := signupUser(t, h, "alice@example.com")
	bob := signupUser(t, h, "bob@example.com")
	authJSON(t, h, "PUT", "/v1/auth/profile", map[string]string{"displayName": "Alice"}, alice.Token, 200, nil)
	if w := request(h, "POST", "/v1/uploads?filename=test.pdf", "not a PDF", alice.Token); w.Code != 400 {
		t.Fatal(w.Code)
	}
	w := request(h, "POST", "/v1/uploads?filename=test.pdf", "%PDF-1.4 source", alice.Token)
	if w.Code != 202 {
		t.Fatal(w.Code, w.Body.String())
	}
	var job ProcessingJob
	json.Unmarshal(w.Body.Bytes(), &job)
	if job.UploadedBy.Name != "Alice" || strings.Contains(w.Body.String(), "alice@example.com") {
		t.Fatal("incorrect public attribution", w.Body.String())
	}
	var jobs []ProcessingJob
	authJSON(t, h, "GET", "/v1/jobs", nil, bob.Token, 200, &jobs)
	if len(jobs) != 0 {
		t.Fatal("other user's jobs leaked")
	}
	authJSON(t, h, "POST", "/v1/jobs/"+job.ID+"/retry", nil, bob.Token, 404, nil)
	authJSON(t, h, "GET", "/v1/jobs", nil, "secret", 200, &jobs)
	if len(jobs) != 1 {
		t.Fatal(jobs)
	}
	claimed, lease, err := s.claimJob(ctx)
	if err != nil || claimed.ID != job.ID {
		t.Fatal(claimed, err)
	}
	if _, _, err = s.claimJob(ctx); !errors.Is(err, sql.ErrNoRows) {
		t.Fatal("job claimed twice", err)
	}
	b := sample("ignored-generated-id")
	b.Chapters = []Section{{Title: "PDF page 1", Body: "Original page text", SourcePage: 1}}
	if err = s.publishProcessed(ctx, job, "wrong-lease", b, []byte("%PDF-source"), json.RawMessage(`{}`)); err == nil {
		t.Fatal("stale worker published")
	}
	if err = s.publishProcessed(ctx, job, lease, b, []byte("%PDF-source"), json.RawMessage(`{"coverage":[]}`)); err != nil {
		t.Fatal(err)
	}
	s.finishJob(ctx, job.ID, lease, nil)
	saved, err := s.Get(ctx, job.BookID)
	if err != nil || saved.UploadedBy == nil || saved.UploadedBy.Name != "Alice" || saved.Source == nil {
		t.Fatal(saved, err)
	}
	saved.UploadedBy = &Uploader{ID: "spoof", Name: "Someone else"}
	raw, _ := json.Marshal(saved)
	if w = request(h, "PUT", "/v1/books/"+job.BookID, string(raw), "secret"); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	saved, _ = s.Get(ctx, job.BookID)
	if saved.UploadedBy.Name != "Alice" {
		t.Fatal("uploader overwritten by book edit")
	}
	authJSON(t, h, "POST", "/v1/admin/books/"+job.BookID+"/narration", map[string]string{"provider": "openrouter"}, alice.Token, 403, nil)
	var narration ProcessingJob
	authJSON(t, h, "POST", "/v1/admin/books/"+job.BookID+"/narration", map[string]string{}, "secret", 202, &narration)
	if narration.Provider != "openrouter" {
		t.Fatal("wrong default provider", narration.Provider)
	}
	authJSON(t, h, "POST", "/v1/admin/books/"+job.BookID+"/narration", map[string]string{}, "secret", 409, nil)
}

func TestJobLeaseRecoveryAndRetry(t *testing.T) {
	s, h := setup(t)
	ctx := context.Background()
	j, err := s.queuePDF(ctx, User{ID: "legacy", Role: "admin"}, "book.pdf", []byte("%PDF-test"))
	if err != nil {
		t.Fatal(err)
	}
	_, first, err := s.claimJob(ctx)
	if err != nil {
		t.Fatal(err)
	}
	s.db.Exec("UPDATE processing_jobs SET lease_until=? WHERE id=?", time.Now().Unix()-1, j.ID)
	recovered, second, err := s.claimJob(ctx)
	if err != nil || recovered.ID != j.ID || second == first || recovered.Attempts != 2 {
		t.Fatal(recovered, err)
	}
	if err = s.jobProgress(ctx, j.ID, first, "summarizing", "stale"); err == nil {
		t.Fatal("stale worker retained lease")
	}
	s.finishJob(ctx, j.ID, second, errors.New("test failure"))
	authJSON(t, h, "POST", "/v1/jobs/"+j.ID+"/retry", nil, "secret", 202, nil)
	recovered, _, err = s.claimJob(ctx)
	if err != nil || recovered.Status != "extracting" {
		t.Fatal(recovered, err)
	}
}

func TestGeneratedNarrationRejectsChangedText(t *testing.T) {
	s, _ := setup(t)
	ctx := context.Background()
	b := sample("queued-audio")
	s.Put(ctx, b)
	j, err := s.queueNarration(ctx, User{ID: "legacy", Role: "admin"}, b.ID, "openrouter")
	if err != nil {
		t.Fatal(err)
	}
	_, lease, err := s.claimJob(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.saveGeneratedNarration(ctx, j, lease, 0, "wrong-body-hash", Narration{Provider: "openrouter"}, []byte("ID3audio")); err == nil {
		t.Fatal("stale audio published")
	}
	b, _ = s.Get(ctx, b.ID)
	if b.Sections[0].Narration != nil {
		t.Fatal("stale narration attached")
	}
}
