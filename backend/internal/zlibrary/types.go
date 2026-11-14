package zlibrary

// SearchOptions controls a title/author search.
type SearchOptions struct {
	Query      string
	Exact      bool
	FromYear   int
	ToYear     int
	Languages  []string // e.g. "english", "russian"
	Extensions []string // e.g. "PDF", "EPUB"
	Count      int      // results per page, max 50
	Page       int      // 1-based page number
}

// FullTextSearchOptions extends SearchOptions for full-text queries.
type FullTextSearchOptions struct {
	SearchOptions
	Phrase bool // true = match phrase; false = match individual words
}

// SearchResult holds one page of search results.
type SearchResult struct {
	Books      []BookSummary
	TotalPages int
	Page       int
	Query      string
}

// BookSummary is the abbreviated info shown in search results.
type BookSummary struct {
	ID        string
	ISBN      string
	URL       string
	Cover     string
	Name      string
	Publisher string
	Authors   []string
	Year      string
	Language  string
	Extension string
	Size      string
	Rating    string
	Quality   string
}

// BookDetail is the full metadata from a book's detail page.
type BookDetail struct {
	URL           string
	Name          string
	Cover         string
	Description   string
	Authors       []Author
	Year          string
	Edition       string
	Publisher     string
	Language      string
	ISBN          string
	ISBN13        string
	Categories    string
	CategoriesURL string
	Extension     string
	Size          string
	Rating        string
	DownloadURL   string
}

// Author pairs a name with a profile URL.
type Author struct {
	Name string
	URL  string
}

// Download is a downloaded book file.
type Download struct {
	Data        []byte
	ContentType string
	Filename    string
}
