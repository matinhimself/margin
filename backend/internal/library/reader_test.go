package library

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func syncRequest(t *testing.T, h http.Handler, records ...ReaderRecord) []ReaderRecord {
	t.Helper()
	if records == nil {
		records = []ReaderRecord{}
	}
	raw, _ := json.Marshal(map[string]any{"records": records})
	w := request(h, "POST", "/v1/sync", string(raw), "secret")
	if w.Code != 200 {
		t.Fatalf("sync %d: %s", w.Code, w.Body.String())
	}
	var result struct {
		Records []ReaderRecord `json:"records"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	return result.Records
}
func TestReaderSyncAcrossDevices(t *testing.T) {
	_, h := setup(t)
	now := time.Now().UnixMilli()
	note := ReaderRecord{ID: "annotation:one", Kind: "annotation", BookID: "book", BookTitle: "A book", UpdatedAt: now, DeviceID: "mac", Location: "summary", Quote: "Keep this idea", Text: "My thought"}
	bookmark := ReaderRecord{ID: "bookmark:book:summary:2", Kind: "bookmark", BookID: "book", UpdatedAt: now, DeviceID: "phone", Location: "summary", Section: 2}
	syncRequest(t, h, note)
	// A second device sends an independent bookmark without erasing the first device's note.
	if records := syncRequest(t, h, bookmark); len(records) != 2 {
		t.Fatal(records)
	}
	stale := note
	stale.UpdatedAt--
	stale.Text = "Stale offline edit"
	records := syncRequest(t, h, stale)
	for _, r := range records {
		if r.ID == note.ID && r.Text != "My thought" {
			t.Fatal("stale edit won", r)
		}
	}
	note.UpdatedAt++
	note.Deleted = true
	syncRequest(t, h, note)
	records = syncRequest(t, h, stale)
	for _, r := range records {
		if r.ID == note.ID && !r.Deleted {
			t.Fatal("stale client resurrected a deletion")
		}
	}
	// Equal timestamps resolve deterministically, regardless of delivery order.
	tie := note
	tie.DeviceID = "zzz"
	tie.Deleted = false
	tie.Text = "Concurrent edit"
	syncRequest(t, h, tie)
	records = syncRequest(t, h, note)
	for _, r := range records {
		if r.ID == note.ID && r.DeviceID != "zzz" {
			t.Fatal("tie break is not deterministic")
		}
	}
	session := ReaderRecord{ID: "session:one", Kind: "session", BookID: "book", UpdatedAt: now, DeviceID: "phone", Location: "summary", Seconds: 60, Day: "2026-10-20"}
	syncRequest(t, h, session)
	records = syncRequest(t, h, session)
	count := 0
	for _, r := range records {
		if r.Kind == "session" {
			count++
		}
	}
	if count != 1 {
		t.Fatal("retry double-counted a session")
	}
}
func TestSyncValidationIsAtomic(t *testing.T) {
	s, h := setup(t)
	good := ReaderRecord{ID: "goal", Kind: "goal", UpdatedAt: time.Now().UnixMilli(), DeviceID: "mac", Location: "summary", Seconds: 600}
	bad := good
	bad.ID = "wrong"
	raw, _ := json.Marshal(map[string]any{"records": []ReaderRecord{good, bad}})
	if w := request(h, "POST", "/v1/sync", string(raw), "secret"); w.Code != 400 {
		t.Fatal(w.Code, w.Body.String())
	}
	records, err := s.Sync(context.Background(), nil)
	if err != nil || len(records) != 0 {
		t.Fatal("partially applied invalid batch", records, err)
	}
	future := good
	future.UpdatedAt = time.Now().Add(48 * time.Hour).UnixMilli()
	if err := future.Validate(); err == nil {
		t.Fatal("accepted a future timestamp")
	}
}
func TestSourcePDFAndFullChapters(t *testing.T) {
	s, h := setup(t)
	b := sample("source-book")
	b.Sections[0].SourcePage = 2
	b.Chapters = []Section{{Title: "Original chapter", Body: "A searchable telescope passage."}}
	if err := s.Put(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	if w := request(h, "GET", "/v1/books?q=telescope", "", "secret"); w.Code != 200 || !bytes.Contains(w.Body.Bytes(), []byte("source-book")) {
		t.Fatal(w.Body.String())
	}
	pdf := []byte("%PDF-1.7\nfixture source bytes\n%%EOF")
	r := httptest.NewRequest("PUT", "/v1/books/source-book/source?filename=original.pdf", bytes.NewReader(pdf))
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	stored, err := s.Get(context.Background(), b.ID)
	if err != nil || stored.Source == nil || stored.Source.Filename != "original.pdf" || len(stored.Source.SHA256) != 64 {
		t.Fatal(stored, err)
	}
	got := request(h, "GET", "/v1/books/source-book/source", "", "secret")
	if got.Code != 200 || !bytes.Equal(got.Body.Bytes(), pdf) || got.Header().Get("Content-Type") != "application/pdf" {
		t.Fatal(got.Code)
	}
	if err := s.Put(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	stored, err = s.Get(context.Background(), b.ID)
	if err != nil || stored.Source == nil {
		t.Fatal("editing removed source", err)
	}
	if w := request(h, "PUT", "/v1/books/source-book/source", "not a PDF", "secret"); w.Code != 400 {
		t.Fatal(w.Code)
	}
	note := ReaderRecord{ID: "annotation:preserve", Kind: "annotation", BookID: b.ID, BookTitle: b.Title, UpdatedAt: time.Now().UnixMilli(), DeviceID: "mac", Location: "pdf", Text: "Keep my note"}
	syncRequest(t, h, note)
	if err := s.Delete(context.Background(), b.ID); err != nil {
		t.Fatal(err)
	}
	if w := request(h, "GET", "/v1/books/source-book/source", "", "secret"); w.Code != 404 {
		t.Fatal(w.Code)
	}
	if records := syncRequest(t, h); len(records) != 1 || records[0].Text != "Keep my note" {
		t.Fatal("deleting a book erased notes", records)
	}
}
