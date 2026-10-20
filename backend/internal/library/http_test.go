package library

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func sample(id string) Book {
	return Book{ID: id, Title: "A focused day", Author: "Margin", Category: "Focus", Color: "#DCE9C9", Minutes: 5, Sections: []Section{{Title: "Begin", Body: "Choose one useful thing."}}}
}
func setup(t *testing.T) (*Store, http.Handler) {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, Handler(s, "secret")
}
func request(h http.Handler, method, path, body, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}
func TestBookLifecycle(t *testing.T) {
	_, h := setup(t)
	if w := request(h, "GET", "/healthz", "", ""); w.Code != 200 {
		t.Fatal(w.Code)
	}
	if w := request(h, "GET", "/v1/books", "", ""); w.Code != 401 {
		t.Fatal(w.Code)
	}
	raw, _ := json.Marshal(sample("focus"))
	if w := request(h, "PUT", "/v1/books/focus", string(raw), "secret"); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	w := request(h, "GET", "/v1/books?q=FOCUSED&category=Focus", "", "secret")
	var books []Book
	if err := json.Unmarshal(w.Body.Bytes(), &books); err != nil || len(books) != 1 || books[0].UpdatedAt == "" {
		t.Fatal(w.Body.String(), err)
	}
	if w := request(h, "GET", "/v1/books?q=missing", "", "secret"); w.Code != 200 || strings.TrimSpace(w.Body.String()) != "[]" {
		t.Fatal(w.Body.String())
	}
	b := sample("focus")
	b.Title = "Changed"
	raw, _ = json.Marshal(b)
	if w := request(h, "PUT", "/v1/books/focus", string(raw), "secret"); w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	if w := request(h, "GET", "/v1/books/focus", "", "secret"); !bytes.Contains(w.Body.Bytes(), []byte("Changed")) {
		t.Fatal(w.Body.String())
	}
	if w := request(h, "DELETE", "/v1/books/focus", "", "secret"); w.Code != 204 {
		t.Fatal(w.Code)
	}
	if w := request(h, "GET", "/v1/books/focus", "", "secret"); w.Code != 404 {
		t.Fatal(w.Code)
	}
	if w := request(h, "DELETE", "/v1/books/focus", "", "secret"); w.Code != 404 {
		t.Fatal(w.Code)
	}
}
func TestInvalidWritesAndOrigin(t *testing.T) {
	_, h := setup(t)
	for _, body := range []string{`{}`, `{"id":"wrong"}`, `{"unknown":true}`, `{} {}`, `{"id":"bad/id"}`} {
		if w := request(h, "PUT", "/v1/books/focus", body, "secret"); w.Code != 400 {
			t.Fatalf("%s: %d", body, w.Code)
		}
	}
	raw, _ := json.Marshal(sample("focus"))
	r := httptest.NewRequest("PUT", "/v1/books/focus", bytes.NewReader(raw))
	r.Header.Set("Origin", "https://example.com")
	r.Header.Set("Authorization", "Bearer secret")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 403 {
		t.Fatal(w.Code)
	}
}
func TestImportAtomicAndPersistent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "books.sqlite")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Import(context.Background(), []Book{sample("one"), {ID: "invalid"}}); err == nil {
		t.Fatal("expected validation error")
	}
	books, err := s.List(context.Background())
	if err != nil || len(books) != 0 {
		t.Fatal(books, err)
	}
	if err := s.Import(context.Background(), []Book{sample("one"), sample("one")}); err == nil {
		t.Fatal("duplicate accepted")
	}
	if err := s.Put(context.Background(), sample("one")); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	b, err := s.Get(context.Background(), "one")
	if err != nil || b.Title != "A focused day" {
		t.Fatal(b, err)
	}
}
