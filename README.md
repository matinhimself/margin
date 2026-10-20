# Margin

A local Blinkist-style library with a native SwiftUI reader for **iPhone, iPad, and Mac**, backed by a small **Go + SQLite** service. Books and summaries are written manually in the app or imported as JSON.

Logo vectors, icon masters, and palette guidance live in [the Margin identity kit](assets/brand/README.md). The Xcode app uses the included iOS/macOS AppIcon asset catalog.

Includes cross-device progress and bookmarks, notes and text highlights, full-text search, source PDFs and full-book chapters, daily reading goals and streaks, offline reading, and a native publishing editor. Six original sample reads are included; they are demo essays, not summaries of published books.

## Run locally

Requirements: Go 1.25+, Xcode 15+ (with its command-line tools), and a C compiler for the SQLite driver. No Node, Docker, or project generator installation is needed.

```sh
# Start your library API on 127.0.0.1:8787.
make server
```

In another terminal:

```sh
make mac
open app/build/mac/Build/Products/Debug/Margin.app
```

Or open `app/Margin.xcodeproj`, select the **Margin** scheme, choose **My Mac**, an iPhone simulator, or an iPad simulator, and run. The default connection is `http://127.0.0.1:8787`. Use the connection button to change it. `cd app && swift run Margin` is also available for Mac development; use the Xcode app bundle for normal use.

`make server` starts without importing examples. For an optional demonstration library, `make demo` imports the sample essays and starts the server; `make seed` imports them separately. Reimporting upserts the same IDs and overwrites edits to those sample books, so use `make server` after initial setup. The database is `backend/data/library.sqlite` when launched by Make.

## Hosted backend

The production API is **https://books.0xff.shop:8443** on `69.12.83.46`.
Enter that URL and the bearer token in the app’s connection settings. The token is
stored locally in the ignored `deploy/.env`, and on the server in
`/srv/margin/deploy/.env` (mode 640, readable by the deployment group). Do not commit or share it.

The deployment uses Docker Compose in `/srv/margin/deploy`. Caddy provides HTTPS
on Cloudflare-supported port **8443**, with port **80** reserved for ACME certificate
renewal and HTTPS redirects. Port 443 is used by another service. Keep Cloudflare
SSL/TLS encryption set to **Full (strict)** for this hostname. The API is only
reachable through the proxy; its port 8787 is private to the Docker network.
Responses set `Cache-Control: no-store` because the library is private.

The SQLite database is persisted at `/srv/margin/deploy/data/library.sqlite`.
The initial deployment copied the local library with SQLite’s online backup API.
Local and hosted servers are independent after that snapshot; select the hosted
URL on each device to use the hosted library and sync reading data there.

To update backend code without replacing the hosted database or token:

```sh
rsync -az --exclude data --exclude library --exclude '*_test.go' backend/ root@69.12.83.46:/srv/margin/backend/
rsync -az deploy/compose.yaml deploy/Caddyfile root@69.12.83.46:/srv/margin/deploy/
ssh root@69.12.83.46 'cd /srv/margin/deploy && docker compose up -d --build'
```

Do not sync the entire local `deploy/` folder over an existing deployment: it
contains the initial local database snapshot. Services restart automatically after
server reboots. Inspect status and logs with `docker compose ps` and
`docker compose logs --tail=100` from the deployment directory. For a consistent
backup while running:

```sh
ssh root@69.12.83.46 'cd /srv/margin/deploy && docker compose exec -T api sqlite3 /data/library.sqlite ".backup /data/library-backup.sqlite"'
scp root@69.12.83.46:/srv/margin/deploy/data/library-backup.sqlite ./library-backup.sqlite
```

## Automatic deployment

GitHub Actions runs `.github/workflows/deploy.yml` when backend, deployment, or
workflow files change on `main`, and supports manual runs from the Actions tab.
It runs Go race tests and vet, transfers only backend source and deployment
configuration, builds on the server, backs up the live database to
`/srv/margin/deploy/data/library-pre-deploy.sqlite`, and verifies HTTPS health.
Deployments are serialized. A build failure leaves the running service untouched;
a failed post-deployment health check fails the workflow and requires inspection.

The workflow connects as the dedicated `margin-deploy` user. Repository Actions
secrets `DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS` provide its SSH key and the
verified server host key. The application token stays on the server. The local
copy of the deployment SSH key is `~/.ssh/margin_actions_ed25519`; it is separate
from your normal SSH identity. Do not commit it.

App-only commits do not redeploy the backend. To run a deployment manually:

```sh
gh workflow run deploy.yml --ref main
```

## Use a physical iPhone or iPad

1. Put your Mac and device on the same trusted network.
2. Stop the loopback server, then run from `backend`:

   ```sh
   export LIBRARY_TOKEN='choose-a-long-private-token'
   go run ./cmd/library serve -addr 0.0.0.0:8787
   ```

3. In Xcode, choose your signing team and a unique bundle identifier, select the device, and run.
4. In the app’s connection settings, enter `http://YOUR-MAC-LAN-IP:8787` and the same token. Allow local network access if prompted. Your firewall must allow the Go server’s inbound connection.

The server requires a token for non-loopback binds. The app stores it in Keychain. Local HTTP is supported explicitly in `Info.plist`; use HTTPS through a reverse proxy for access beyond your trusted LAN. This is a single-user service: the same token can read and publish content.

## Add and edit books

Use **+** to create a book. Enter its metadata and synopsis, then add titled plain-text ideas. The editor supports reordering and removing ideas. **Publish** writes to the server. Open an existing book and use **Edit** to update it. Refresh other devices to fetch edits.

For bulk imports, follow [the example JSON](backend/examples/books.json):

```sh
cd backend
go run ./cmd/library import -file /absolute/path/books.json
# Optional custom database:
go run ./cmd/library import -db /absolute/path/library.sqlite -file /absolute/path/books.json
```

Imports are atomic and upsert by ID. IDs contain 1–80 ASCII letters, digits, underscores, or hyphens. Every book requires a title, author, 1–999 reading minutes, a `#RRGGBB` cover color, and 1–100 sections with nonempty titles and bodies. Omit `updatedAt` on import; the server sets it. Use the same database path for import and serve.

Book content and personal reading data are shared through the **same single-user server**. Devices using that server sync progress, saved books, completion, bookmarks, notes, highlights, reading sessions, and the daily goal. The app syncs after edits, on refresh, when activated, and every 30 seconds while active. There are no separate user accounts; use a separate server/database for a different person's private library.

The library and an outbox are cached per server URL in Application Support. Offline annotations and reading changes save immediately, survive restart, and upload after reconnection. Independent notes and bookmarks merge separately. Conflicts on the same record use the latest edit timestamp, with device ID breaking ties; device clocks should be accurate. Deletions use retained tombstones so an old offline device cannot resurrect an older edit. Book content editing remains last-write-wins and requires the server. Existing device-local progress/bookmarks migrate automatically.

Bookmarks and annotations retain their reading mode and section/page position. Highlights also retain the original quote and text range, and the reader finds the quotation again if its position changes. Reordering/removing sections can change the location; notes and their original quotes remain in the notebook even after deleting the book. PDF annotations record the source hash, and older-source notes remain visible when the PDF is replaced.

## Reading, notes, search, and habits

- **Highlights:** select text in a summary or full-text chapter. On Mac, right-click and choose **Highlight** or **Highlight & add note**; on iPhone/iPad, use the text-selection menu. The reader displays saved highlights in yellow, green, or pink.
- **Notes:** use **Add note** in the reader for a section/page note, or annotate a selected passage. Browse, search, edit, and restore deleted annotations in **Notes & highlights**. Notes survive book deletion; deletions and restores sync.
- **Search library:** searches book metadata, synopsis, summary text, full-text chapters, and your notes/highlights. Results jump to the matching section or source page. The reader's contents menu searches the current text. In a source PDF, its native search searches that document; image-only scans need OCR to supply searchable/selectable text.
- **Reading habits:** set a daily goal from 1–240 minutes, see today's reading time, the current goal streak, a 30-day calendar, and recent sessions. Reader time counts only in the foreground and pauses after two minutes without interaction. Scroll, tap, navigate, or choose Resume to continue. Sessions save every minute and when leaving the reader; an unexpected app termination can lose the unfinished minute. Concurrent reading sessions on two devices both count. History keeps the local calendar day at the time of reading; the current goal determines streak calculations.

Readers open full screen on iPhone and iPad and in a dedicated, resizable reader window on Mac. On Mac, use the full-screen toolbar button (or Control-Command-F) to fill the display. Use the eye button to hide or restore reading controls. Text readers offer System, Light, Sepia, and Dark themes, text size, and a wider page in Appearance. Choose **Two pages** in the text reader’s Appearance menu for a facing-page spread, with page turns within each chapter. Text reflows when the window or font size changes, and narrow screens fall back to a single column. Source PDFs open one page at a time; the Page layout menu offers single or facing pages and optional continuous scrolling. These reader presentations also apply when opening passages from search or the notebook.

## Full books and source PDFs

A book can contain summary `sections`, optional full-text `chapters`, and an attached source PDF. The editor switches between summary ideas and full-book chapters. Book details offer **Read full book** and **Attach source PDF**. Attach or replace a PDF up to **50 MiB**; the source is stored in SQLite. PDFKit displays it natively on all three platforms.

Set a section's optional **Source PDF page** to a one-based page number. The reader then links that idea to the original page. Source PDFs have independent synced page progress and bookmarks. Select PDF text, then use the reader's Highlight/Add note buttons. Password-protected or unreadable PDFs are rejected by the reader. A source downloads on first open and stays available offline; download it on each device before disconnecting.

You can also attach a local PDF through the CLI:

```sh
cd backend
go run ./cmd/library attach -db /absolute/path/library.sqlite -book BOOK-ID -file /absolute/path/book.pdf
```

The book must already exist. Source metadata (`source.filename`, `source.sha256`) is assigned by the attachment workflow and survives later book edits. `sections[].sourcePage` and `chapters[].sourcePage` are optional. Source page links and bookmarks use PDF page indices, which can differ from printed page labels.

## Create a summary from a PDF

The reusable [PDF to Margin skill](skills/pdf-to-margin/SKILL.md) is installed locally as `$pdf-to-margin`. For example:

> Use $pdf-to-margin with `/path/to/book.pdf` to create a 10-minute summary and add it to my local Margin library.

It reads the actual PDF, checks chapter coverage, writes original summary sections, retains supporting page references in `source-map.json`, and validates `book.json` against the backend contract. An explicit request to add the book to Margin also imports and verifies it. A draft-only request produces files without importing. This is an agent-assisted workflow; the application itself has no automatic summarization service.

The extraction helper requires Poppler (`brew install poppler` on macOS). Source PDFs and full extracted text belong outside Git or under the ignored `content/private/` directory. Skill source is versioned in `skills/pdf-to-margin`; the local skill installation links to that directory.

## API

| Method | Path | Result |
| --- | --- | --- |
| GET | `/healthz` | Public health check |
| GET | `/v1/books` | Full library, including sections |
| GET | `/v1/books?q=focus&category=Productivity` | Metadata search and exact topic filter |
| GET | `/v1/books/{id}` | One book |
| PUT | `/v1/books/{id}` | Create or replace a validated book |
| DELETE | `/v1/books/{id}` | Delete book content and source; keep personal notes/history |
| POST | `/v1/sync` | Exchange reader records and deletion tombstones |
| PUT | `/v1/books/{id}/source?filename=book.pdf` | Attach/replace PDF bytes, up to 50 MiB |
| GET | `/v1/books/{id}/source` | Download the attached PDF |

When `LIBRARY_TOKEN` is set, all `/v1` requests require `Authorization: Bearer TOKEN`. Errors are JSON objects with an `error` field. Browser-origin writes are rejected. Book JSON PUT accepts at most 2 MiB and requires a body ID matching the URL. Sync accepts up to 500 records and 5 MiB per request; the app batches its outbox within those limits. PDF attachment PUT accepts up to 50 MiB. There is no user/account system or web admin dependency.

## Development and verification

```sh
make test      # Go race tests + vet, then Swift model/cache/contract tests
make mac       # Native macOS build
make ios       # Universal iPhone/iPad Simulator build
```

The Xcode project is checked in. After adding/removing app Swift files, regenerate it with `python3 scripts/generate_project.py`; it uses only Python’s standard library. Shared model files are picked up automatically by the local Swift package.

The Go module has one dependency, `mattn/go-sqlite3`, pinned in `go.mod`/`go.sum`. Linux builds need CGO and a C toolchain. Stop the server before making a simple file copy of the SQLite database; WAL files can contain recent writes while it is running.

See [the implementation plan and architecture](docs/PLAN.md) for the data ownership, delivery sequence, and first-version limits.
