package library

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

type Section struct {
	Title      string `json:"title"`
	Body       string `json:"body"`
	SourcePage int    `json:"sourcePage,omitempty"`
}

type Source struct {
	Filename string `json:"filename"`
	SHA256   string `json:"sha256"`
}

type Book struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Author    string    `json:"author"`
	Subtitle  string    `json:"subtitle"`
	Category  string    `json:"category"`
	Color     string    `json:"color"`
	Minutes   int       `json:"minutes"`
	Synopsis  string    `json:"synopsis"`
	Sections  []Section `json:"sections"`
	UpdatedAt string    `json:"updatedAt"`
	Chapters  []Section `json:"chapters,omitempty"`
	Source    *Source   `json:"source,omitempty"`
}

func (b *Book) Validate() error {
	b.ID = strings.TrimSpace(b.ID)
	if len(b.ID) == 0 || len(b.ID) > 80 {
		return errors.New("id must contain 1–80 letters, digits, hyphens or underscores")
	}
	for _, c := range b.ID {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return errors.New("invalid book id")
		}
	}
	b.Title = strings.TrimSpace(b.Title)
	b.Author = strings.TrimSpace(b.Author)
	b.Category = strings.TrimSpace(b.Category)
	if b.Title == "" || b.Author == "" {
		return errors.New("title and author are required")
	}
	if len(b.Title) > 300 || len(b.Author) > 300 || len(b.Subtitle) > 500 || len(b.Category) > 100 || len(b.Synopsis) > 20000 {
		return errors.New("book metadata is too long")
	}
	if b.Category == "" {
		b.Category = "General"
	}
	if b.Color == "" {
		b.Color = "#DCE9C9"
	}
	if len(b.Color) != 7 || b.Color[0] != '#' {
		return errors.New("color must be a #RRGGBB value")
	}
	for _, c := range b.Color[1:] {
		if !strings.ContainsRune("0123456789abcdefABCDEF", c) {
			return errors.New("invalid color")
		}
	}
	if b.Minutes < 1 || b.Minutes > 999 {
		return errors.New("minutes must be between 1 and 999")
	}
	if len(b.Sections) < 1 || len(b.Sections) > 100 {
		return errors.New("a book needs 1–100 sections")
	}
	if len(b.Chapters) > 1000 {
		return errors.New("at most 1000 full-book chapters are supported")
	}
	for i, s := range append(append([]Section{}, b.Sections...), b.Chapters...) {
		s.Title = strings.TrimSpace(s.Title)
		s.Body = strings.TrimSpace(s.Body)
		if s.Title == "" || s.Body == "" || len(s.Title) > 300 || len(s.Body) > 100000 {
			return fmt.Errorf("section %d needs a title (up to 300 bytes) and body (up to 100000 bytes)", i+1)
		}
		if s.SourcePage < 0 || s.SourcePage > 100000 {
			return errors.New("sourcePage must be a one-based PDF page, or zero when unset")
		}
	}
	// Source metadata is managed by the PDF attachment endpoint, never by book edits.
	b.Source = nil
	b.UpdatedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return nil
}
