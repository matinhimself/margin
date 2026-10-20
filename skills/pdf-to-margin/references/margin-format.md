# Margin content contract

The live contract is in `backend/internal/library/model.go`. If it changes, follow that code and update this reference/helper accordingly. The checked-in examples are `backend/examples/books.json`.

CLI import accepts a JSON **array**; `PUT /v1/books/{id}` accepts one book object. Do not add provenance, ISBN, summary attribution, or page references as new top-level fields: HTTP decoding rejects unknown fields. Put an attribution sentence in the synopsis and detailed provenance in a sidecar file.

```json
[
  {
    "id": "book-title-author",
    "title": "The actual book title",
    "author": "The actual author",
    "subtitle": "A clear editorial description of the central idea",
    "category": "Personal growth",
    "color": "#DCE9C9",
    "minutes": 10,
    "synopsis": "An independently written summary of the supplied edition. Explain the thesis and intended learning here.",
    "sections": [
      {
        "title": "A distinct, source-supported idea",
        "body": "Explain the argument in original prose.\n\nDevelop it with a supported example or implication."
      }
    ]
  }
]
```

This is a schema example, not content to publish. Derive all book-specific fields from the PDF.

| Field | Server constraint / editorial convention |
| --- | --- |
| `id` | 1–80 ASCII letters, digits, `_`, `-`; use a stable lowercase title/author slug. For non-Latin titles, a `book-` prefix plus a short source-hash suffix is a safe fallback. Check collisions before importing. |
| `title`, `author` | Nonempty after trimming; each at most 300 UTF-8 bytes. |
| `subtitle` | String, at most 500 UTF-8 bytes. |
| `category` | String, at most 100 UTF-8 bytes; prefer an existing suitable topic. Empty defaults to `General`. |
| `color` | `#RRGGBB`; app palette: `#DCE9C9`, `#F0D5B8`, `#CBDCE8`, `#E7CFD4`, `#E8DFB8`, `#CDCDE5`. |
| `minutes` | Integer 1–999. Estimate actual synopsis/section reading time, not the full source-book length. |
| `synopsis` | String, at most 20,000 UTF-8 bytes. Prefer about 80–120 words. |
| `sections` | 1–100 objects, each containing exactly `title` and `body`; each nonempty after trimming. Title at most 300 UTF-8 bytes; body at most 100,000 UTF-8 bytes. |
| `updatedAt` | Omit in generated content. Server assigns it; imports may include it but overwrite its value. |
| `sections[].sourcePage` | Optional one-based source PDF page (1–100000); omit when unmapped. Use the first supporting PDF page from the source map. |
| `chapters` | Optional full-book text, up to 1000 objects in the same shape as sections. Leave out when creating only a summary; do not invent or reconstruct unprovided full-book text. |
| `source` | Read-only source attachment metadata (`filename`, `sha256`). Do not author it: attach the actual PDF instead. |

The HTTP request limit is 2 MiB per book object. The bundled validator applies this limit even for CLI artifacts so both publishing paths remain usable.

## Local import

Resolve absolute paths and the intended database before running. Make launches the app's default database at `<checkout>/backend/data/library.sqlite`. A relative `-db` path is resolved against the shell's current directory; avoid unintentionally creating a second library.

From the checkout's `backend` directory:

```sh
go run ./cmd/library import -db /absolute/path/library.sqlite -file /absolute/path/book.json
```

Use `rtk proxy` in this repository, as its `RTK.md` requires. Import is atomic and **upserts by ID**, overwriting a prior book with the same ID. Reading state is device-local and section-position based; reordering an existing book can change what an old bookmark points to.

The local API normally runs at `http://127.0.0.1:8787`; a user may have configured a different server/database. For the default server, `GET /v1/books/{id}` verifies the stored document. If `LIBRARY_TOKEN` is configured, requests require its bearer token. Do not print credentials or commit them. Direct CLI import does not need a token because it operates on the selected local SQLite database.

If the user requests the original PDF alongside the summary, attach it after importing the book (maximum 50 MiB):

```sh
go run ./cmd/library attach -db /absolute/path/library.sqlite -book book-title-author -file /absolute/path/book.pdf
```

The app then offers a native source-PDF reader, offline download, and links from summary sections to `sourcePage`. Refresh after attaching. Notes, highlights, bookmarks, and reading habits sync through the same personal library server.

## Source-map shape

Keep page indices **one-based PDF pages**, not unverified printed numbering. Record printed page labels separately when useful. An example sidecar shape:

```json
{
  "book_id": "book-title-author",
  "source": {
    "filename": "book.pdf",
    "sha256": "actual SHA-256 from extraction manifest",
    "pdf_pages": 240,
    "edition": "Verified edition text",
    "language": "en"
  },
  "scope": "whole book",
  "coverage": [{"part": "Introduction", "pdf_pages": [[8, 15]], "status": "read"}],
  "exclusions": [{"pdf_pages": [[225, 240]], "reason": "Index and bibliography; checked for context"}],
  "limitations": [],
  "sections": [{"title": "Exact output section title", "pdf_pages": [[16, 28], [80, 85]], "support": "How these pages support the condensed idea"}]
}
```

Replace every illustrative value. Do not claim to have read excluded pages. Record partial coverage explicitly and avoid whole-book labeling if substantive chapters are missing.
