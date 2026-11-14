package library

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNarrationAudioLifecycle(t *testing.T) {
	s, h := setup(t)
	b := sample("audio")
	b.Sections[0].Narration = &Narration{Provider: "test", Words: []NarrationWord{{Text: "Choose", Start: 0, End: 1, Offset: 0, Length: 6}}}
	if err := s.Put(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	path := "/v1/books/audio/narration/0"
	if w := request(h, "PUT", path, "ID3audio", ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	if w := request(h, "PUT", path, "bad audio", "secret"); w.Code != 400 {
		t.Fatal(w.Code)
	}
	if w := request(h, "PUT", path, "ID3audio", "secret"); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	b, _ = s.Get(context.Background(), b.ID)
	if len(b.Sections[0].Narration.SHA256) != 64 || len(b.Sections[0].Narration.BodySHA256) != 64 {
		t.Fatal("missing integrity hashes")
	}
	if w := request(h, "GET", path, "", ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	r := httptest.NewRequest("GET", path, nil)
	r.Header.Set("Authorization", "Bearer secret")
	r.Header.Set("Range", "bytes=3-7")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 206 || w.Body.String() != "audio" {
		t.Fatal(w.Code, w.Body.String())
	}
	b.Sections[0].Body += " Extra."
	if err := s.Put(context.Background(), b); err != nil {
		t.Fatal(err)
	}
	b, _ = s.Get(context.Background(), b.ID)
	if b.Sections[0].Narration != nil {
		t.Fatal("stale narration survived text edit")
	}
	if w := request(h, "GET", path, "", "secret"); w.Code != 404 {
		t.Fatal(w.Code)
	}
	if err := s.Delete(context.Background(), b.ID); err != nil {
		t.Fatal(err)
	}
	var count int
	s.db.QueryRow("SELECT COUNT(*) FROM narrations").Scan(&count)
	if count != 0 {
		t.Fatal("orphaned audio")
	}
}
func TestNarrationRejectsInvalidUTF16Alignment(t *testing.T) {
	b := sample("utf16")
	b.Sections[0].Body = "👋 Hello"
	b.Sections[0].Narration = &Narration{Provider: "test", Words: []NarrationWord{{Text: "Hello", Start: 0, End: 1, Offset: 3, Length: 5}}}
	if err := b.Validate(); err != nil {
		t.Fatal(err)
	}
	b.Sections[0].Narration.Words[0].Offset = 2
	raw, _ := json.Marshal(b)
	_, h := setup(t)
	if w := request(h, "PUT", "/v1/books/utf16", string(raw), "secret"); w.Code != 400 || !strings.Contains(w.Body.String(), "alignment") {
		t.Fatal(w.Code, w.Body.String())
	}
}
