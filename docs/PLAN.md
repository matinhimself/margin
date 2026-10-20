# Margin implementation plan

## Product scope

A personal, manually curated short-book library for iPhone, iPad, and Mac. Each book has metadata, a synopsis, and ordered plain-text ideas. Original sample essays are included to make the app usable immediately. Content creation and summarization are entirely manual.

## Architecture

- Go 1.25 HTTP service with the standard router and `database/sql`. SQLite uses `github.com/mattn/go-sqlite3` and requires CGO/a C compiler. One connection, WAL mode, a busy timeout, parameterized queries, and atomic imports keep the service small and predictable.
- One `books` table stores a stable ID, the versioned JSON document, and its modification timestamp. Section order is represented by the document array. Schema creation runs on startup. Future incompatible changes will need numbered migrations.
- Shared SwiftUI app, iOS/iPadOS 17+ and macOS 14+. A navigation split view adapts from phone navigation to tablet/desktop sidebars. `LibraryCore` contains the Codable contract, HTTP client, reading state, and atomic disk cache.
- The server owns book content and synced reader records. Devices maintain a persistent offline cache/outbox per server URL. Saved status, section/page bookmarks, completion, progress, notes, highlights, sessions, and daily goals sync. Every annotation, bookmark, and session has its own record; deterministic timestamp/device ordering resolves same-record conflicts and retained tombstones carry deletions. Existing caches migrate without dropping their original reading state.
- Source PDFs are stored as SQLite BLOBs with filename/SHA-256 metadata, capped at 50 MiB. PDFKit provides native viewing/search/selection on all platforms; content-hashed downloads support offline reading. Books can also carry optional full-text chapters, independently navigable from their summary, and section-to-PDF page links.
- Text selection creates range/quotation-anchored highlights and optional notes. The searchable notebook preserves notes/quotes after book deletion and supports restoring deleted annotations. Library search covers metadata, summary/full-chapter passages, and annotations; PDF search stays inside the native source reader.
- The habit tracker records foreground reading sessions, pauses after two idle minutes, and flushes each minute/on reader exit. Additive session records support cross-device daily totals, goals, streaks, and a 30-day calendar. Session dates retain the device's local reading day.
- A native editor creates, reorders, edits, and publishes sections. JSON CLI import provides bulk entry and upserts by stable ID. Deletion requires confirmation. The first version uses last-write-wins editing; simultaneous editors can overwrite one another.
- Loopback HTTP is the default. Listening on the LAN requires a bearer token, used for both reads and writes and stored by the app in Keychain. It is a single trusted-user service, with no accounts or permissions. HTTP is intended for a trusted LAN; use HTTPS behind a reverse proxy for remote use.

## Delivery sequence

1. Define the book contract and implement validated CRUD, search, atomic import, persistent storage, and graceful shutdown.
2. Build topic shelves, search, details, saved/finished shelves, and the adaptive navigation.
3. Add the focused reader, section navigation/bookmarks, text size, light/dark appearance, completion, and offline persistence.
4. Add the manual editor and server connection flow, including failed-request and empty states.
5. Verify Go lifecycle/auth/import tests, Swift model/cache tests, macOS and iOS Simulator builds, and a running native app against the real API.

## Deliberate first-version limits

No in-app generated summaries, audio, EPUB ingestion, rich text, cover-image hosting, or cloud account system. The PDF-to-Margin skill remains an agent-assisted content workflow. Content publishing requires a connection; personal reading edits have an offline queue. Bookmarks identify section positions, and annotations preserve both the location and quote/range; reordering/removing sections can change what an old location points to. Same-record concurrent edits use last-write-wins rather than collaborative text merging. PDF search/highlighting requires selectable text; OCR is not embedded in the app. Source attachments and personal data all belong to one trusted library, rather than separate per-user accounts.
