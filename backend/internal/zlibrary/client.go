// Package zlibrary provides a Go client for Z-Library's web interface.
// It handles login, search, book detail fetching, and file downloads.
package zlibrary

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultDomain = "https://z-library.sk"
	LoginPath     = "/rpc.php"
	SearchPath    = "/s/"
	FullTextPath  = "/fulltext/"
	BookPath      = "/book/"
)

var ErrAccessChallenge = errors.New("zlibrary: mirror verification did not complete")

var ErrNotLoggedIn = errors.New("zlibrary: not logged in — call Login first")

type Client struct {
	http     *http.Client
	mirror   string
	logger   *slog.Logger
	loggedIn bool
	proxyURL string
}

type Option func(*Client)

func WithMirror(mirror string) Option {
	return func(c *Client) {
		if !strings.HasPrefix(mirror, "http") {
			mirror = "https://" + mirror
		}
		c.mirror = strings.TrimRight(mirror, "/")
	}
}

func WithHTTPClient(hc *http.Client) Option {
	return func(c *Client) { c.http = hc }
}

// WithProxyURL routes the mirror session, login, and downloads through one proxy.
// Supported forms include http://host:port and socks5://host:port.
func WithProxyURL(proxyURL string) Option {
	return func(c *Client) { c.proxyURL = proxyURL }
}

func WithLogger(l *slog.Logger) Option {
	return func(c *Client) { c.logger = l }
}

func New(opts ...Option) *Client {
	jar, _ := cookiejar.New(nil)
	c := &Client{
		mirror: DefaultDomain,
		logger: slog.Default(),
	}
	for _, o := range opts {
		o(c)
	}
	if c.http == nil {
		proxyURL := c.proxyURL
		if proxyURL == "" {
			if u, err := url.Parse(c.mirror); err == nil {
				if proxy, err := http.ProxyFromEnvironment(&http.Request{URL: u}); err == nil && proxy != nil {
					proxyURL = proxy.String()
				}
			}
		}
		c.http = &http.Client{Transport: newBrowserTransport(proxyURL), Jar: jar, Timeout: 60 * time.Second}
	}
	if c.http.Jar == nil {
		c.http.Jar = jar
	}
	return c
}

// Login authenticates with a Z-Library singlelogin account.
// Cookies are stored in the client's jar for subsequent requests.
func (c *Client) Login(ctx context.Context, email, password string) error {
	c.loggedIn = false
	// Establish the mirror session and gateway cookies before posting credentials.
	if _, err := c.get(ctx, c.mirror+"/"); err != nil {
		return fmt.Errorf("zlibrary session: %w", err)
	}
	data := url.Values{
		"isModal":       {"true"},
		"email":         {email},
		"password":      {password},
		"site_mode":     {"books"},
		"action":        {"login"},
		"isSingleLogin": {"1"},
		"redirectUrl":   {""},
		"gg_json_mode":  {"1"},
	}
	req, err := http.NewRequestWithContext(ctx, "POST", c.mirror+LoginPath, strings.NewReader(data.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Origin", c.mirror)
	req.Header.Set("Referer", c.mirror+"/")
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	req.Header.Set("Accept", "application/json, text/javascript, */*; q=0.01")
	setBrowserHeaders(req)

	resp, err := c.do(req)
	if err != nil {
		return fmt.Errorf("zlibrary login request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("zlibrary login read: %w", err)
	}

	var result struct {
		Response *struct {
			ValidationError json.RawMessage `json:"validationError"`
			UserID          int64           `json:"user_id"`
			UserKey         string          `json:"user_key"`
		} `json:"response"`
		Errors json.RawMessage `json:"errors"`
	}
	if resp.StatusCode == 513 || resp.StatusCode == 517 {
		return ErrAccessChallenge
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("zlibrary login: HTTP %d", resp.StatusCode)
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return fmt.Errorf("zlibrary login parse: %w", err)
	}
	if result.Response == nil {
		return errors.New("zlibrary login: missing authentication response")
	}
	if raw := strings.TrimSpace(string(result.Errors)); raw != "" && raw != "null" && raw != "[]" && raw != "{}" {
		return errors.New("zlibrary login: authentication failed")
	}
	validation := strings.TrimSpace(string(result.Response.ValidationError))
	if validation != "" && validation != "false" && validation != "null" {
		return errors.New("zlibrary login: authentication failed")
	}
	// Current mirrors return account keys on success, rather than validationError.
	if validation != "false" && (result.Response.UserID <= 0 || result.Response.UserKey == "") {
		return errors.New("zlibrary login: missing authentication confirmation")
	}

	c.loggedIn = true
	c.logger.Info("zlibrary: logged in", "mirror", c.mirror)
	return nil
}

func (c *Client) LoggedIn() bool { return c.loggedIn }

func (c *Client) get(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}
	setBrowserHeaders(req)
	c.logger.Debug("zlibrary GET", "url", url)
	resp, err := c.do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 513 || resp.StatusCode == 517 {
		return nil, ErrAccessChallenge
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("zlibrary: HTTP %d for %s", resp.StatusCode, url)
	}
	return io.ReadAll(resp.Body)
}

// Search queries Z-Library and returns the first page of results.
func (c *Client) Search(ctx context.Context, opts SearchOptions) (*SearchResult, error) {
	if !c.loggedIn {
		return nil, ErrNotLoggedIn
	}
	if opts.Query == "" {
		return nil, errors.New("zlibrary: empty search query")
	}
	if opts.Count <= 0 {
		opts.Count = 10
	}
	if opts.Count > 50 {
		opts.Count = 50
	}

	u := c.mirror + SearchPath + url.PathEscape(opts.Query) + "?"
	u += buildSearchParams(opts)

	if opts.Page > 0 {
		u += "&page=" + strconv.Itoa(opts.Page)
	}

	body, err := c.get(ctx, u)
	if err != nil {
		return nil, err
	}
	books, total := parseSearchPage(body, c.mirror)
	return &SearchResult{
		Books:      books,
		TotalPages: total,
		Page:       max(opts.Page, 1),
		Query:      opts.Query,
	}, nil
}

// FullTextSearch searches the full text of books on Z-Library.
func (c *Client) FullTextSearch(ctx context.Context, opts FullTextSearchOptions) (*SearchResult, error) {
	if !c.loggedIn {
		return nil, ErrNotLoggedIn
	}
	if opts.Query == "" {
		return nil, errors.New("zlibrary: empty search query")
	}

	u := c.mirror + FullTextPath + url.PathEscape(opts.Query) + "?"
	if opts.Phrase {
		u += "&type=phrase"
	} else {
		u += "&type=words"
	}
	u += buildSearchParams(opts.SearchOptions)

	if opts.Page > 0 {
		u += "&page=" + strconv.Itoa(opts.Page)
	}

	body, err := c.get(ctx, u)
	if err != nil {
		return nil, err
	}
	books, total := parseSearchPage(body, c.mirror)
	return &SearchResult{
		Books:      books,
		TotalPages: total,
		Page:       max(opts.Page, 1),
		Query:      opts.Query,
	}, nil
}

// GetBook fetches full details for a single book by its Z-Library ID.
func (c *Client) GetBook(ctx context.Context, id string) (*BookDetail, error) {
	if !c.loggedIn {
		return nil, ErrNotLoggedIn
	}
	if id == "" {
		return nil, errors.New("zlibrary: empty book ID")
	}
	parts := strings.Split(id, "/")
	for i, part := range parts {
		if part == "" || part == "." || part == ".." {
			return nil, errors.New("zlibrary: invalid book ID")
		}
		parts[i] = url.PathEscape(part)
	}
	u := c.mirror + BookPath + strings.Join(parts, "/")
	body, err := c.get(ctx, u)
	if err != nil {
		return nil, err
	}
	return parseBookPage(body, c.mirror)
}

// DownloadBook downloads a book file and returns the raw bytes plus the
// Content-Type and filename from the response.
func (c *Client) DownloadBook(ctx context.Context, downloadURL string) (*Download, error) {
	if !c.loggedIn {
		return nil, ErrNotLoggedIn
	}
	if downloadURL == "" {
		return nil, errors.New("zlibrary: empty download URL")
	}
	if !strings.HasPrefix(downloadURL, "http") {
		downloadURL = c.mirror + downloadURL
	}

	req, err := http.NewRequestWithContext(ctx, "GET", downloadURL, nil)
	if err != nil {
		return nil, err
	}
	setBrowserHeaders(req)

	resp, err := c.do(req)
	if err != nil {
		return nil, fmt.Errorf("zlibrary download: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == 513 || resp.StatusCode == 517 {
		return nil, ErrAccessChallenge
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("zlibrary download: HTTP %d", resp.StatusCode)
	}

	data, err := io.ReadAll(io.LimitReader(resp.Body, (50<<20)+1))
	if err != nil {
		return nil, fmt.Errorf("zlibrary download read: %w", err)
	}

	if len(data) > 50<<20 {
		return nil, errors.New("zlibrary: book must be at most 50 MiB")
	}
	filename := ""
	if _, params, err := mime.ParseMediaType(resp.Header.Get("Content-Disposition")); err == nil {
		filename = params["filename"]
	}

	return &Download{
		Data:        data,
		ContentType: resp.Header.Get("Content-Type"),
		Filename:    filename,
	}, nil
}

const userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

func buildSearchParams(opts SearchOptions) string {
	var parts []string
	if opts.Exact {
		parts = append(parts, "e=1")
	}
	if opts.FromYear > 0 {
		parts = append(parts, "yearFrom="+strconv.Itoa(opts.FromYear))
	}
	if opts.ToYear > 0 {
		parts = append(parts, "yearTo="+strconv.Itoa(opts.ToYear))
	}
	for _, lang := range opts.Languages {
		parts = append(parts, "languages%5B%5D="+url.QueryEscape(lang))
	}
	for _, ext := range opts.Extensions {
		parts = append(parts, "extensions%5B%5D="+url.QueryEscape(ext))
	}
	return strings.Join(parts, "&")
}

func setBrowserHeaders(req *http.Request) {
	req.Header.Set("User-Agent", userAgent)
	if req.Header.Get("Accept") == "" {
		req.Header.Set("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
	}
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	req.Header.Set("Sec-CH-UA", `"Google Chrome";v="131", "Chromium";v="131", "Not_A Brand";v="24"`)
	req.Header.Set("Sec-CH-UA-Mobile", "?0")
	req.Header.Set("Sec-CH-UA-Platform", `"macOS"`)
	if req.Header.Get("X-Requested-With") != "" {
		req.Header.Set("Sec-Fetch-Site", "same-origin")
		req.Header.Set("Sec-Fetch-Mode", "cors")
		req.Header.Set("Sec-Fetch-Dest", "empty")
	} else {
		req.Header.Set("Sec-Fetch-Site", "none")
		req.Header.Set("Sec-Fetch-Mode", "navigate")
		req.Header.Set("Sec-Fetch-User", "?1")
		req.Header.Set("Sec-Fetch-Dest", "document")
		req.Header.Set("Upgrade-Insecure-Requests", "1")
	}
	req.Header.Set("Accept-Encoding", "gzip, deflate, br, zstd")
}
