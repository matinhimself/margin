package zlibrary

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestExtractAttr(t *testing.T) {
	tag := `<z-bookcard id="12345" isbn="978-0-123" href="/book/12345" year="2020" language="english" extension="PDF" filesize="5.2 MB">`
	tests := []struct {
		name, want string
	}{
		{"id", "12345"},
		{"isbn", "978-0-123"},
		{"href", "/book/12345"},
		{"year", "2020"},
		{"language", "english"},
		{"extension", "PDF"},
		{"filesize", "5.2 MB"},
		{"nonexistent", ""},
	}
	for _, tt := range tests {
		got := extractAttr(tag, tt.name)
		if got != tt.want {
			t.Errorf("extractAttr(%q) = %q, want %q", tt.name, got, tt.want)
		}
	}
}

func TestStripTags(t *testing.T) {
	got := stripTags(`<div class="x">hello <b>world</b></div>`)
	want := "hello world"
	if got != want {
		t.Errorf("stripTags = %q, want %q", got, want)
	}
}

func TestExtractSlotText(t *testing.T) {
	html := `<z-bookcard><div slot="title">My Book Title</div><div slot="author">Author One; Author Two</div></z-bookcard>`
	if got := extractSlotText(html, "title"); got != "My Book Title" {
		t.Errorf("title slot = %q", got)
	}
	if got := extractSlotText(html, "author"); got != "Author One; Author Two" {
		t.Errorf("author slot = %q", got)
	}
}

func TestParseSearchPage(t *testing.T) {
	html := `<html><body>
		<div id="searchResultBox">
			<div class="book-item">
				<z-bookcard id="111" isbn="000" href="/book/111" year="2021" language="english" extension="EPUB" filesize="1.2 MB" rating="4.5">
					<img data-src="https://covers.example.com/1.jpg">
					<div slot="title">Test Book One</div>
					<div slot="author">Alice; Bob</div>
				</z-bookcard>
			</div>
			<div class="book-item">
				<z-bookcard id="222" href="/book/222" year="2019" language="german" extension="PDF" filesize="3.0 MB">
					<div slot="title">Zweites Buch</div>
					<div slot="author">Charlie</div>
				</z-bookcard>
			</div>
		</div>
		<script>var pagerOptions = { pagesTotal: 5, currentPage: 1 };</script>
	</body></html>`

	books, total := parseSearchPage([]byte(html), "https://z.example.com")
	if total != 5 {
		t.Errorf("totalPages = %d, want 5", total)
	}
	if len(books) != 2 {
		t.Fatalf("len(books) = %d, want 2", len(books))
	}

	b := books[0]
	if b.ID != "111" || b.Name != "Test Book One" || b.Year != "2021" {
		t.Errorf("book[0] = %+v", b)
	}
	if len(b.Authors) != 2 || b.Authors[0] != "Alice" || b.Authors[1] != "Bob" {
		t.Errorf("book[0].Authors = %v", b.Authors)
	}
	if b.URL != "https://z.example.com/book/111" {
		t.Errorf("book[0].URL = %q", b.URL)
	}
	if b.Cover != "https://covers.example.com/1.jpg" {
		t.Errorf("book[0].Cover = %q", b.Cover)
	}

	b2 := books[1]
	if b2.ID != "222" || b2.Extension != "PDF" || b2.Language != "german" {
		t.Errorf("book[1] = %+v", b2)
	}
}

func TestBuildSearchParams(t *testing.T) {
	opts := SearchOptions{
		Exact:      true,
		FromYear:   2000,
		ToYear:     2020,
		Languages:  []string{"english", "russian"},
		Extensions: []string{"PDF", "EPUB"},
	}
	got := buildSearchParams(opts)
	if got == "" {
		t.Fatal("empty params")
	}
	for _, want := range []string{"e=1", "yearFrom=2000", "yearTo=2020", "english", "russian", "PDF", "EPUB"} {
		if !contains(got, want) {
			t.Errorf("params %q missing %q", got, want)
		}
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && containsStr(s, sub))
}

func containsStr(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestParseAbsoluteDownloadAndEscapedText(t *testing.T) {
	detail, err := parseBookPage([]byte(`<z-cover title="Books &amp; ideas"><img src="cover.jpg" class="image"></z-cover><a href="https://files.example/book.pdf?x=1&amp;y=2" onclick="addDownloadedBook()">Download</a>`), "https://catalog.example")
	if err != nil || detail.DownloadURL != "https://files.example/book.pdf?x=1&y=2" || detail.Name != "Books & ideas" || detail.Cover != "cover.jpg" {
		t.Fatal(detail, err)
	}
}

func TestLoginEstablishesSession(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			http.SetCookie(w, &http.Cookie{Name: "session", Value: "ready", Path: "/"})
			w.Write([]byte("Library"))
			return
		}
		if _, err := r.Cookie("session"); err != nil {
			t.Error("login did not carry session cookie")
			w.WriteHeader(513)
			return
		}
		w.Write([]byte(`{"response":{"validationError":false}}`))
	}))
	defer server.Close()
	c := New(WithMirror(server.URL))
	if err := c.Login(context.Background(), "reader", "password"); err != nil || !c.LoggedIn() {
		t.Fatal(err)
	}
}
func TestLoginReportsMirrorChallenge(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(513) }))
	defer server.Close()
	c := New(WithMirror(server.URL))
	if err := c.Login(context.Background(), "reader", "password"); !errors.Is(err, ErrAccessChallenge) || c.LoggedIn() {
		t.Fatal(err)
	}
}
