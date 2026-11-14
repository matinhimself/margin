package zlibrary

import (
	"bytes"
	"context"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Opt-in smoke test; credentials are supplied only through the environment.
// Downloads a public-domain edition into memory, without publishing a summary.
func TestLiveMirror(t *testing.T) {
	if os.Getenv("ZLIBRARY_LIVE_TEST") != "1" {
		t.Skip("set ZLIBRARY_LIVE_TEST=1 to test a configured mirror")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	c := New(WithMirror(os.Getenv("ZLIBRARY_MIRROR")), WithProxyURL(os.Getenv("ZLIBRARY_PROXY")))
	defer c.http.CloseIdleConnections()
	fail := func(err error) {
		t.Helper()
		msg := err.Error()
		for _, key := range []string{"ZLIBRARY_EMAIL", "ZLIBRARY_PASSWORD"} {
			if secret := os.Getenv(key); secret != "" {
				msg = strings.ReplaceAll(msg, secret, "[redacted]")
			}
		}
		t.Fatal(msg)
	}
	if err := c.Login(ctx, os.Getenv("ZLIBRARY_EMAIL"), os.Getenv("ZLIBRARY_PASSWORD")); err != nil {
		fail(err)
	}
	t.Log("Login succeeded")
	result, err := c.Search(ctx, SearchOptions{Query: "Pride and Prejudice Jane Austen", Extensions: []string{"PDF", "EPUB"}, Page: 1})
	if err != nil {
		fail(err)
	}
	t.Logf("Search returned %d books", len(result.Books))
	for _, b := range result.Books {
		if !strings.Contains(strings.ToLower(strings.Join(b.Authors, " ")), "austen") || strings.ToLower(strings.TrimSpace(b.Name)) != "pride and prejudice" {
			continue
		}
		if !strings.EqualFold(b.Extension, "pdf") && !strings.EqualFold(b.Extension, "epub") {
			continue
		}
		path := strings.SplitN(b.URL, "/book/", 2)
		if len(path) != 2 {
			continue
		}
		parts := strings.Split(path[1], "/")
		if len(parts) > 1 {
			if _, err := strconv.ParseUint(parts[0], 10, 64); err == nil {
				parts = parts[:2]
			} else {
				parts = parts[:1]
			}
		}
		book, err := c.GetBook(ctx, strings.Join(parts, "/"))
		if err != nil {
			fail(err)
		}
		if book.DownloadURL == "" {
			continue
		}
		download, err := c.DownloadBook(ctx, book.DownloadURL)
		if err != nil {
			fail(err)
		}
		t.Logf("Download metadata: filename=%q; detail extension=%q; content-type=%q", download.Filename, book.Extension, download.ContentType)
		data := download.Data
		if !bytes.HasPrefix(data, []byte("PK")) && !bytes.Contains(data[:min(1024, len(data))], []byte("%PDF-")) {
			t.Fatal("download returned neither a PDF nor an EPUB")
		}
		t.Logf("Downloaded public-domain edition: %s (%d bytes)", b.Name, len(data))
		return
	}
	t.Fatal("no downloadable public-domain edition found")
}
