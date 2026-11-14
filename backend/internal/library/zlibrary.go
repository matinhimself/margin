package library

import (
	"context"
	"errors"
	"fmt"
	"local/blinkist/internal/zlibrary"
	"log/slog"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ZLibrary keeps credentials and session cookies on the library server.
// A gate serializes access to the upstream account and its login state.
type ZLibrary struct {
	client          *zlibrary.Client
	email, password string
	gate            chan struct{}
}

func NewZLibrary(mirror, email, password string, options ...zlibrary.Option) *ZLibrary {
	if email == "" || password == "" {
		return nil
	}
	opts := append([]zlibrary.Option{}, options...)
	if mirror != "" {
		opts = append(opts, zlibrary.WithMirror(mirror))
	}
	return &ZLibrary{client: zlibrary.New(opts...), email: email, password: password, gate: make(chan struct{}, 1)}
}
func (z *ZLibrary) acquire(ctx context.Context) error {
	select {
	case z.gate <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	if !z.client.LoggedIn() {
		if err := z.client.Login(ctx, z.email, z.password); err != nil {
			<-z.gate
			return err
		}
	}
	return nil
}

type catalogBook struct {
	ID        string   `json:"id"`
	Title     string   `json:"title"`
	Authors   []string `json:"authors"`
	Year      string   `json:"year"`
	Language  string   `json:"language"`
	Extension string   `json:"extension"`
	Size      string   `json:"size"`
	Cover     string   `json:"cover"`
}

var catalogID = regexp.MustCompile(`^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)?$`)
var catalogLanguage = regexp.MustCompile(`^[a-zA-Z-]{1,40}$`)
var legacyCatalogID = regexp.MustCompile(`^[0-9]+$`)

func registerZLibraryRoutes(mux *http.ServeMux, s *Store, z *ZLibrary) {
	ready := func(w http.ResponseWriter) bool {
		if z == nil {
			writeError(w, 503, "Z-Library is not configured on this server. Ask your library admin to configure it.")
			return false
		}
		return true
	}
	upstreamError := func(w http.ResponseWriter, err error) {
		if errors.Is(err, zlibrary.ErrAccessChallenge) {
			writeError(w, 502, "Z-Library verification did not complete. Try again or ask your library admin to check the configured mirror and connection.")
			return
		}
		// Upstream responses can contain account information; return only a generic message.
		writeError(w, 502, "Z-Library could not complete the request. Check the server account and mirror, then try again.")
	}
	mux.HandleFunc("GET /v1/zlibrary/search", func(w http.ResponseWriter, r *http.Request) {
		if !ready(w) {
			return
		}
		q := strings.TrimSpace(r.URL.Query().Get("q"))
		page := 1
		if raw := r.URL.Query().Get("page"); raw != "" {
			var err error
			page, err = strconv.Atoi(raw)
			if err != nil || page < 1 || page > 1000 {
				writeError(w, 400, "Choose a valid search page.")
				return
			}
		}
		if q == "" || len(q) > 300 {
			writeError(w, 400, "Enter a title or author of at most 300 bytes.")
			return
		}
		languages := []string{}
		if language := r.URL.Query().Get("language"); language != "" {
			if !catalogLanguage.MatchString(language) {
				writeError(w, 400, "Choose a valid language.")
				return
			}
			languages = append(languages, strings.ToLower(language))
		}
		ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
		defer cancel()
		if err := z.acquire(ctx); err != nil {
			upstreamError(w, err)
			return
		}
		defer func() { <-z.gate }()

		result, err := z.client.Search(ctx, zlibrary.SearchOptions{Query: q, Page: page, Extensions: []string{"PDF", "EPUB"}, Languages: languages})
		if err != nil {
			upstreamError(w, err)
			return
		}
		books := []catalogBook{}
		for _, b := range result.Books {
			if !strings.EqualFold(b.Extension, "pdf") && !strings.EqualFold(b.Extension, "epub") {
				continue
			}
			u, err := url.Parse(b.URL)
			if err != nil {
				continue
			}
			if !strings.HasPrefix(u.Path, "/book/") {
				continue
			}
			id := strings.TrimPrefix(u.Path, "/book/")
			// Current mirrors use an opaque ID followed by an optional title slug.
			// Older mirrors require the numeric ID and edition hash.
			parts := strings.Split(id, "/")
			if legacyCatalogID.MatchString(parts[0]) && len(parts) > 1 {
				id = strings.Join(parts[:2], "/")
			} else {
				id = parts[0]
			}

			if !catalogID.MatchString(id) {
				continue
			}
			authors := b.Authors
			if authors == nil {
				authors = []string{}
			}
			books = append(books, catalogBook{id, b.Name, authors, b.Year, b.Language, strings.ToUpper(b.Extension), b.Size, b.Cover})
		}
		writeJSON(w, 200, struct {
			Books      []catalogBook `json:"books"`
			Page       int           `json:"page"`
			TotalPages int           `json:"totalPages"`
		}{books, result.Page, result.TotalPages})
	})
	mux.HandleFunc("POST /v1/zlibrary/summarize", func(w http.ResponseWriter, r *http.Request) {
		if !ready(w) {
			return
		}
		var input struct {
			ID             string `json:"id"`
			SummaryMinutes int    `json:"summaryMinutes"`
			Title          string `json:"title"`
			Author         string `json:"author"`
			Cover          string `json:"cover"`
		}
		if !decodeAuth(w, r, &input) {
			return
		}
		if !catalogID.MatchString(input.ID) || len(input.ID) > 300 {
			writeError(w, 400, "Choose a valid book from search results.")
			return
		}
		if input.SummaryMinutes != 10 && input.SummaryMinutes != 30 {
			writeError(w, 400, "Choose a 10 or 30 minute summary.")
			return
		}
		if len(input.Title) > 1000 || len(input.Author) > 1000 || len(input.Cover) > 2048 {
			writeError(w, 400, "Book metadata is too long.")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
		defer cancel()
		if err := z.acquire(ctx); err != nil {
			upstreamError(w, err)
			return
		}
		defer func() { <-z.gate }()
		book, err := z.client.GetBook(ctx, input.ID)
		if err != nil {
			upstreamError(w, err)
			return
		}
		if book.DownloadURL == "" {
			writeError(w, 422, "This edition is unavailable for download. Choose another edition.")
			return
		}
		download, err := z.client.DownloadBook(ctx, book.DownloadURL)
		if err != nil {
			upstreamError(w, err)
			return
		}
		name, kind := zLibraryInput(input.ID, download)
		if kind == "" {
			slog.Warn("zlibrary download rejected", "bookID", input.ID, "contentType", download.ContentType, "bytes", len(download.Data))
			writeError(w, 422, "This edition did not provide a valid PDF or EPUB. Choose another edition.")
			return
		}

		title := strings.TrimSpace(input.Title)
		if title == "" {
			title = book.Name
		}
		author := strings.TrimSpace(input.Author)
		if author == "" {
			names := []string{}
			for _, a := range book.Authors {
				names = append(names, a.Name)
			}
			author = strings.Join(names, ", ")
		}
		cover := input.Cover
		if cover == "" {
			cover = book.Cover
		}
		if u, err := url.Parse(cover); err != nil || (u.Scheme != "https" && u.Scheme != "http") {
			cover = ""
		}
		job, err := s.queueUpload(ctx, currentUser(r), kind, name, download.Data, input.SummaryMinutes, JobSource{input.ID, title, author, cover})
		if err != nil {
			authFailure(w, err)
			return
		}
		writeJSON(w, 202, job)
	})
}

// Upstream filenames and detail metadata are optional. Determine the format
// from the same PDF/EPUB content checks used for uploads before choosing a name.
func zLibraryInput(id string, download *zlibrary.Download) (string, string) {
	kind := uploadKind("book.pdf", download.Data)
	if kind == "" {
		kind = uploadKind("book.epub", download.Data)
	}
	if kind == "" {
		return "", ""
	}
	name := filepath.Base(strings.ReplaceAll(download.Filename, `\`, "/"))
	if name == "." || name == "/" || name == "" || len(name) > 300 {
		key := strings.Split(id, "/")[0]
		if len(key) > 64 {
			key = key[:64]
		}
		name = fmt.Sprintf("zlibrary-%s.%s", key, kind)
	} else if !strings.EqualFold(filepath.Ext(name), "."+kind) {
		name = strings.TrimSuffix(name, filepath.Ext(name)) + "." + kind
		if len(name) > 300 {
			name = "zlibrary-book." + kind
		}
	}
	return name, kind
}
