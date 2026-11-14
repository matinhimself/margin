package library

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"local/blinkist/internal/zlibrary"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestZLibrarySearchAndSummarize(t *testing.T) {
	var downloads int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			w.Write([]byte("<html>Library</html>"))
		case "/rpc.php":
			w.Write([]byte(`{"response":{"validationError":false}}`))
		case "/s/Test":
			if r.URL.Query().Get("languages[]") != "english" {
				t.Error("missing language filter")
			}
			if r.URL.Query().Get("page") != "2" {
				t.Error("missing search page")
			}
			w.Write([]byte(`<z-bookcard id="123" href="/book/123/hash/title" year="2020" language="english" extension="PDF" filesize="1 MB"><div slot="title">Test book</div><div slot="author">Author</div></z-bookcard><z-bookcard id="opaque" href="/book/yRaaZZ52RQ/title.html" extension="EPUB"><div slot="title">Another edition</div></z-bookcard><script>pagesTotal: 3,</script>`))
		case "/book/123/hash":
			w.Write([]byte(`<z-cover title="Test book"></z-cover><a href="/download/123" onclick="addDownloadedBook()">Download PDF</a>`))
		case "/download/123":
			downloads++
			// Current file hosts can omit Content-Disposition and detail format metadata.
			w.Header().Set("Content-Type", "application/pdf")
			w.Write([]byte("%PDF-1.4 mock book"))
		default:
			t.Errorf("unexpected upstream path %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()
	s, _ := setup(t)
	h := Handler(s, "secret", NewZLibrary(upstream.URL, "reader", "password"))
	for _, test := range []struct {
		method, path, body, token string
		code                      int
	}{
		{"GET", "/v1/zlibrary/search?q=Test&page=2", "", "", 401},
		{"GET", "/v1/zlibrary/search?q=Test&page=0", "", "secret", 400},
		{"GET", "/v1/zlibrary/search?q=Test&language=invalid123", "", "secret", 400},
		{"GET", "/v1/zlibrary/search?q=Test&page=2&language=english", "", "secret", 200},
		{"POST", "/v1/zlibrary/summarize", `{"id":"../bad","summaryMinutes":10}`, "secret", 400},
		{"POST", "/v1/zlibrary/summarize", `{"id":"123/hash","summaryMinutes":15}`, "secret", 400},
		{"POST", "/v1/zlibrary/summarize", `{"id":"123/hash","summaryMinutes":30,"title":"Test book","author":"Author","cover":"https://covers.example/book.jpg"}`, "secret", 202},
		{"POST", "/v1/zlibrary/summarize", `{"id":"123/hash","summaryMinutes":30,"title":"Test book","author":"Author","cover":"https://covers.example/book.jpg"}`, "secret", 409},
	} {
		w := request(h, test.method, test.path, test.body, test.token)
		if w.Code != test.code {
			t.Fatalf("%s: %d %s", test.path, w.Code, w.Body.String())
		}
		if w.Code == 200 {
			var result struct {
				Books []catalogBook `json:"books"`
				Page  int           `json:"page"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil || len(result.Books) != 2 || result.Books[0].ID != "123/hash" || result.Books[1].ID != "yRaaZZ52RQ" || result.Page != 2 {
				t.Fatal(result, err)
			}
		}
		if w.Code == 202 {
			var j ProcessingJob
			if err := json.Unmarshal(w.Body.Bytes(), &j); err != nil || j.Kind != "pdf" || j.Filename != "zlibrary-123.pdf" || j.SummaryMinutes != 30 || j.UploadedBy.ID != "legacy" || j.CatalogID != "123/hash" || j.Title != "Test book" || j.Author != "Author" || j.Cover != "https://covers.example/book.jpg" {
				t.Fatal(j, err)
			}
			claimed, _, err := s.claimJob(context.Background())
			if err != nil || claimed.Status != "extracting" {
				t.Fatal(claimed, err)
			}
		}
	}
	if downloads != 2 {
		t.Fatal(downloads)
	}
}
func TestZLibraryUnconfigured(t *testing.T) {
	_, h := setup(t)
	w := request(h, "GET", "/v1/zlibrary/search?q=Test", "", "secret")
	if w.Code != 503 {
		t.Fatal(w.Code, w.Body.String())
	}
}
func TestZLibraryRejectsInvalidDownload(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			w.Write([]byte("<html>Library</html>"))
		case "/rpc.php":
			w.Write([]byte(`{"response":{"validationError":false}}`))
		case "/book/1":
			w.Write([]byte(`<a href="/file" onclick="addDownloadedBook()">Download</a>`))
		default:
			w.Header().Set("Content-Disposition", `attachment; filename="book.pdf"`)
			w.Write([]byte("<html>Login required</html>"))
		}
	}))
	defer upstream.Close()
	s, _ := setup(t)
	h := Handler(s, "secret", NewZLibrary(upstream.URL, "reader", "password"))
	w := request(h, "POST", "/v1/zlibrary/summarize", `{"id":"1","summaryMinutes":10}`, "secret")
	if w.Code != 422 {
		t.Fatal(w.Code, w.Body.String())
	}
	jobs, err := s.listJobs(context.Background(), User{Role: "admin"})
	if err != nil || len(jobs) != 0 {
		t.Fatal(jobs, err)
	}
}

func TestZLibraryInputDetectsContentWithoutMetadata(t *testing.T) {
	var epub bytes.Buffer
	archive := zip.NewWriter(&epub)
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
	for _, test := range []struct {
		name, filename     string
		data               []byte
		wantName, wantKind string
	}{
		{"no PDF filename", "", []byte("%PDF-1.4 book"), "zlibrary-abc123.pdf", "pdf"},
		{"no EPUB filename", "", epub.Bytes(), "zlibrary-abc123.epub", "epub"},
		{"misleading extension", "book.epub", []byte("%PDF-1.4 book"), "book.pdf", "pdf"},
		{"missing extension", "book", epub.Bytes(), "book.epub", "epub"},
		{"long filename", strings.Repeat("x", 301) + ".pdf", []byte("%PDF-1.4 book"), "zlibrary-abc123.pdf", "pdf"},
		{"valid filename", "book.pdf", []byte("%PDF-1.4 book"), "book.pdf", "pdf"},
		{"HTML response", "book.pdf", []byte("<html>Login required</html>"), "", ""},
	} {
		t.Run(test.name, func(t *testing.T) {
			name, kind := zLibraryInput("abc123", &zlibrary.Download{Filename: test.filename, Data: test.data})
			if name != test.wantName || kind != test.wantKind {
				t.Fatal(name, kind)
			}
		})
	}
}
