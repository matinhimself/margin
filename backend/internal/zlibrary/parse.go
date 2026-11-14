package zlibrary

import (
	"html"
	"net/url"
	"strconv"
	"strings"
)

// parseSearchPage extracts book items and total page count from a Z-Library search results page.
// Uses string-based parsing to avoid external dependencies.
func parseSearchPage(body []byte, mirror string) ([]BookSummary, int) {
	page := string(body)
	var books []BookSummary
	totalPages := 1

	// Extract total pages from "pagesTotal: N" in inline script.
	if idx := strings.Index(page, "pagesTotal:"); idx >= 0 {
		rest := strings.TrimSpace(page[idx+len("pagesTotal:"):])
		if comma := strings.IndexAny(rest, ",}"); comma > 0 {
			if v, err := strconv.Atoi(strings.TrimSpace(rest[:comma])); err == nil {
				totalPages = v
			}
		}
	}

	// Walk through z-bookcard elements.
	remainder := page
	for {
		start := strings.Index(remainder, "<z-bookcard")
		if start < 0 {
			break
		}
		remainder = remainder[start:]
		end := strings.Index(remainder, "</z-bookcard>")
		if end < 0 {
			break
		}
		card := remainder[:end+len("</z-bookcard>")]
		remainder = remainder[end+len("</z-bookcard>"):]

		b := parseBookcardString(card, mirror)
		if b.ID != "" || b.Name != "" {
			books = append(books, b)
		}
	}

	return books, totalPages
}

func parseBookcardString(card, mirror string) BookSummary {
	b := BookSummary{}

	// Parse attributes from the opening <z-bookcard ...> tag.
	tagEnd := strings.IndexByte(card, '>')
	if tagEnd < 0 {
		return b
	}
	tag := card[:tagEnd]

	b.ID = extractAttr(tag, "id")
	b.ISBN = extractAttr(tag, "isbn")
	if href := extractAttr(tag, "href"); href != "" {
		b.URL = resolveURL(mirror, href)
	}
	b.Publisher = extractAttr(tag, "publisher")
	b.Year = extractAttr(tag, "year")
	b.Language = extractAttr(tag, "language")
	b.Extension = extractAttr(tag, "extension")
	b.Size = extractAttr(tag, "filesize")
	b.Rating = extractAttr(tag, "rating")
	b.Quality = extractAttr(tag, "quality")

	// Title: <div slot="title">...</div>
	b.Name = extractSlotText(card, "title")

	// Authors: <div slot="author">name1; name2</div>
	raw := extractSlotText(card, "author")
	if raw != "" {
		for _, a := range strings.Split(raw, ";") {
			a = strings.TrimSpace(a)
			if a != "" {
				b.Authors = append(b.Authors, a)
			}
		}
	}

	// Cover: first <img with data-src
	if dsrc := extractImgSrc(card); dsrc != "" {
		b.Cover = dsrc
	}

	return b
}

// parseBookPage extracts full book details from a book detail page.
func parseBookPage(body []byte, mirror string) (*BookDetail, error) {
	page := string(body)
	d := &BookDetail{}

	// Title from z-cover element
	if idx := strings.Index(page, "<z-cover"); idx >= 0 {
		tagEnd := strings.IndexByte(page[idx:], '>')
		if tagEnd > 0 {
			tag := page[idx : idx+tagEnd]
			d.Name = extractAttr(tag, "title")
		}
		// Cover image within z-cover
		zcEnd := strings.Index(page[idx:], "</z-cover>")
		if zcEnd > 0 {
			zcBlock := page[idx : idx+zcEnd]
			if imgIdx := strings.Index(zcBlock, `class="image"`); imgIdx >= 0 {
				// find surrounding <img tag
				imgStart := strings.LastIndex(zcBlock[:imgIdx], "<img")
				if imgStart >= 0 {
					imgEnd := strings.IndexByte(zcBlock[imgStart:], '>')
					if imgEnd < 0 {
						imgEnd = len(zcBlock) - imgStart
					}
					imgTag := zcBlock[imgStart : imgStart+imgEnd]
					d.Cover = extractAttr(imgTag, "src")
				}
			}
		}
	}

	// Description
	d.Description = extractDivContent(page, `id="bookDescriptionBox"`)

	// Authors from col-sm-9 section (anchors)
	if idx := strings.Index(page, `class="col-sm-9"`); idx >= 0 {
		// Find the containing div
		divStart := strings.LastIndex(page[:idx], "<div")
		if divStart >= 0 {
			depth := 0
			divEnd := -1
			for i := divStart; i < len(page); i++ {
				if strings.HasPrefix(page[i:], "<div") {
					depth++
				}
				if strings.HasPrefix(page[i:], "</div>") {
					depth--
					if depth == 0 {
						divEnd = i + len("</div>")
						break
					}
				}
			}
			if divEnd > 0 {
				block := page[divStart:divEnd]
				d.Authors = extractAnchors(block, mirror)
			}
		}
	}

	// Detail properties from bookDetailsBox
	if idx := strings.Index(page, `class="bookDetailsBox"`); idx >= 0 {
		boxStart := strings.LastIndex(page[:idx], "<div")
		if boxStart >= 0 {
			// Grab a generous chunk
			boxEnd := boxStart + 5000
			if boxEnd > len(page) {
				boxEnd = len(page)
			}
			box := page[boxStart:boxEnd]

			d.Year = extractProperty(box, "property_year")
			d.Edition = extractProperty(box, "property_edition")
			d.Publisher = extractProperty(box, "property_publisher")
			d.Language = extractProperty(box, "property_language")

			// ISBNs
			parseISBNs(box, d)

			// Categories
			if catIdx := strings.Index(box, "property_categories"); catIdx >= 0 {
				val := extractProperty(box, "property_categories")
				d.Categories = val
				// Find category link
				catBlock := box[catIdx:]
				if aIdx := strings.Index(catBlock, "<a"); aIdx >= 0 {
					aTag := catBlock[aIdx:]
					if end := strings.IndexByte(aTag, '>'); end > 0 {
						href := extractAttr(aTag[:end], "href")
						if href != "" {
							d.CategoriesURL = mirror + href
						}
					}
				}
			}

			// File extension and size from property__file
			if fIdx := strings.Index(box, "property__file"); fIdx >= 0 {
				fBlock := box[fIdx:]
				fEnd := strings.Index(fBlock, "</div>")
				if fEnd > 0 {
					raw := stripTags(fBlock[:fEnd])
					parts := strings.SplitN(raw, ",", 2)
					if len(parts) >= 1 {
						fields := strings.Fields(parts[0])
						if len(fields) > 0 {
							d.Extension = fields[len(fields)-1]
						}
					}
					if len(parts) >= 2 {
						d.Size = strings.TrimSpace(parts[1])
					}
				}
			}
		}
	}

	// Rating
	if idx := strings.Index(page, `class="book-rating"`); idx >= 0 {
		divStart := strings.LastIndex(page[:idx], "<div")
		if divStart >= 0 {
			divEnd := strings.Index(page[idx:], "</div>")
			if divEnd > 0 {
				raw := stripTags(page[divStart : idx+divEnd])
				d.Rating = strings.Join(strings.Fields(raw), "")
			}
		}
	}

	// Download URL
	if idx := strings.Index(page, "addDownloadedBook"); idx >= 0 {
		aStart := strings.LastIndex(page[:idx], "<a")
		if aStart >= 0 {
			aEnd := strings.Index(page[idx:], "</a>")
			if aEnd > 0 {
				aBlock := page[aStart : idx+aEnd]
				txt := strings.ToLower(stripTags(aBlock))
				if strings.Contains(txt, "unavailable") {
					d.DownloadURL = ""
				} else {
					tagEnd := strings.IndexByte(aBlock, '>')
					if tagEnd > 0 {
						href := extractAttr(aBlock[:tagEnd], "href")
						if href != "" {
							d.DownloadURL = resolveURL(mirror, href)
						}
					}
				}
			}
		}
	}

	return d, nil
}

// ---- string-based HTML helpers ----

// extractAttr pulls a named attribute value from an HTML tag string.
func extractAttr(tag, name string) string {
	search := name + `="`
	idx := strings.Index(tag, search)
	if idx < 0 {
		search = name + `='`
		idx = strings.Index(tag, search)
	}
	if idx < 0 {
		return ""
	}
	start := idx + len(search)
	quote := tag[idx+len(name)+1]
	end := strings.IndexByte(tag[start:], quote)
	if end < 0 {
		return ""
	}
	return html.UnescapeString(strings.TrimSpace(tag[start : start+end]))
}

// extractSlotText extracts text from <div slot="name">text</div>.
func extractSlotText(html, slot string) string {
	search := `slot="` + slot + `"`
	idx := strings.Index(html, search)
	if idx < 0 {
		return ""
	}
	gt := strings.IndexByte(html[idx:], '>')
	if gt < 0 {
		return ""
	}
	contentStart := idx + gt + 1
	endTag := strings.Index(html[contentStart:], "</div>")
	if endTag < 0 {
		return ""
	}
	return strings.TrimSpace(stripTags(html[contentStart : contentStart+endTag]))
}

func extractImgSrc(html string) string {
	idx := strings.Index(html, "<img")
	for idx >= 0 {
		tagEnd := strings.IndexByte(html[idx:], '>')
		if tagEnd < 0 {
			break
		}
		tag := html[idx : idx+tagEnd]
		if src := extractAttr(tag, "data-src"); src != "" {
			return src
		}
		if src := extractAttr(tag, "src"); src != "" {
			return src
		}
		html = html[idx+tagEnd:]
		idx = strings.Index(html, "<img")
	}
	return ""
}

func extractDivContent(page, marker string) string {
	idx := strings.Index(page, marker)
	if idx < 0 {
		return ""
	}
	divStart := strings.LastIndex(page[:idx], "<div")
	if divStart < 0 {
		return ""
	}
	gt := strings.IndexByte(page[idx:], '>')
	if gt < 0 {
		return ""
	}
	contentStart := idx + gt + 1
	endTag := strings.Index(page[contentStart:], "</div>")
	if endTag < 0 {
		return ""
	}
	return strings.TrimSpace(stripTags(page[contentStart : contentStart+endTag]))
}

func extractProperty(box, className string) string {
	idx := strings.Index(box, className)
	if idx < 0 {
		return ""
	}
	block := box[idx:]
	valIdx := strings.Index(block, "property_value")
	if valIdx < 0 {
		return ""
	}
	gt := strings.IndexByte(block[valIdx:], '>')
	if gt < 0 {
		return ""
	}
	contentStart := valIdx + gt + 1
	endTag := strings.Index(block[contentStart:], "</div>")
	if endTag < 0 {
		return ""
	}
	return strings.TrimSpace(stripTags(block[contentStart : contentStart+endTag]))
}

func parseISBNs(box string, d *BookDetail) {
	rest := box
	for {
		idx := strings.Index(rest, "property_isbn")
		if idx < 0 {
			break
		}
		block := rest[idx:]
		rest = rest[idx+len("property_isbn"):]

		label := extractProperty(block, "property_label")
		val := extractProperty(block, "property_value")
		label = strings.TrimRight(strings.TrimSpace(label), ":")
		val = strings.TrimSpace(val)
		if strings.Contains(label, "13") {
			d.ISBN13 = val
		} else if val != "" {
			d.ISBN = val
		}
	}
}

func extractAnchors(block, mirror string) []Author {
	var authors []Author
	rest := block
	for {
		aIdx := strings.Index(rest, "<a")
		if aIdx < 0 {
			break
		}
		rest = rest[aIdx:]
		tagEnd := strings.IndexByte(rest, '>')
		if tagEnd < 0 {
			break
		}
		aEnd := strings.Index(rest, "</a>")
		if aEnd < 0 {
			break
		}
		tag := rest[:tagEnd]
		text := strings.TrimSpace(stripTags(rest[tagEnd+1 : aEnd]))
		href := extractAttr(tag, "href")
		if text != "" {
			aURL := ""
			if href != "" {
				aURL = mirror + href
			}
			authors = append(authors, Author{Name: text, URL: aURL})
		}
		rest = rest[aEnd+len("</a>"):]
	}
	return authors
}

func stripTags(s string) string {
	var out strings.Builder
	inTag := false
	for _, r := range s {
		switch {
		case r == '<':
			inTag = true
		case r == '>':
			inTag = false
		case !inTag:
			out.WriteRune(r)
		}
	}
	return html.UnescapeString(out.String())
}

func resolveURL(base, ref string) string {
	b, err := url.Parse(base)
	if err != nil {
		return ""
	}
	u, err := url.Parse(ref)
	if err != nil {
		return ""
	}
	return b.ResolveReference(u).String()
}
