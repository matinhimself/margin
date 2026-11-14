# Margin

A local Blinkist-style library with a native SwiftUI reader for **iPhone, iPad, and Mac**, backed by a small **Go + SQLite** service. Upload PDFs or EPUBs to queue automatic text extraction and Codex summaries, or write books manually and import JSON. Admins can generate summary narration.

Logo vectors, icon masters, and palette guidance live in [the Margin identity kit](assets/brand/README.md). The Xcode app uses the included iOS/macOS AppIcon asset catalog.

Includes cross-device progress and bookmarks, notes and text highlights, full-text search, source PDFs and full-book chapters, daily reading goals and streaks, offline reading, and a native publishing editor. Six original sample reads are included; they are demo essays, not summaries of published books.

## Run locally

Requirements: Go 1.25+, Xcode 15+ (with its command-line tools), and a C compiler for the SQLite driver. No Node, Docker, or project generator installation is needed.

```sh
# Start your library API on 127.0.0.1:8787 with a legacy admin credential.
export LIBRARY_TOKEN='choose-a-long-private-token'
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
Enter that URL and a bearer token in the app’s connection settings. Account login
returns a session token; the existing `LIBRARY_TOKEN` remains an admin credential.
The deployment token is
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
rsync -az --exclude /data --exclude /library --exclude '*_test.go' backend/ root@69.12.83.46:/srv/margin/backend/
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

To rebuild, sign, and update Margin on the paired iPhone and iPad from this Mac:

```sh
make update-devices
```

Connect and unlock both devices first. The script uses the HTTP proxy at
`127.0.0.1:10814` for Apple signing, temporarily enables the Wi-Fi HTTP/HTTPS
proxy, and restores the previous settings afterward. It retries unavailable or
locked devices for two minutes, installs in place without deleting app data,
and exits with an error if either installation fails. Xcode must be signed in
to the development account, and Developer Mode and device trust must be enabled.
Run `rtk proxy python3 scripts/update_devices.py --help` to change the proxy,
network service, device UDIDs, or retry duration. This is an on-demand update;
run it again whenever you want to install the current source.

1. Put your Mac and device on the same trusted network.
2. Stop the loopback server, then run from `backend`:

   ```sh
   export LIBRARY_TOKEN='choose-a-long-private-token'
   go run ./cmd/library serve -addr 0.0.0.0:8787
   ```

3. In Xcode, choose your signing team and a unique bundle identifier, select the device, and run.
4. In the app’s connection settings, enter `http://YOUR-MAC-LAN-IP:8787` and the same token. Allow local network access if prompted. Your firewall must allow the Go server’s inbound connection.

All library requests require a bearer token, including on loopback. The app stores it in Keychain. Local HTTP is supported explicitly in `Info.plist`; use HTTPS through a reverse proxy for access beyond your trusted LAN. `LIBRARY_TOKEN` grants admin access; account session tokens grant the account’s role.

In **Connection → Proxy**, choose **HTTP** or **SOCKS5** and enter the proxy host and port. Optional proxy credentials are supported. The proxy applies to all library requests, including sign-in, syncing, uploads, PDF downloads, and narration. Choose **System default** to use the device's normal network settings. The proxy password is stored in Keychain; other proxy settings are saved on the device.

## Accounts and invite codes

Create the first admin locally against the same database used by the server. Read
the password without putting it in shell history (zsh):

```sh
cd backend
read -rs 'LIBRARY_ADMIN_PASSWORD?Admin password: '
export LIBRARY_ADMIN_PASSWORD
go run ./cmd/library admin -email admin@example.com
unset LIBRARY_ADMIN_PASSWORD
```

Use `-db /path/to/library.sqlite` for a custom database. For a Docker deployment,
run `library admin -db /data/library.sqlite -email admin@example.com`
inside the API container with
`LIBRARY_ADMIN_PASSWORD` supplied through the environment. The command succeeds
only when no accounts exist. The first admin inherits the existing reading history.
The existing deployment token continues to work as an unrestricted admin credential
and accesses that same history; unset `LIBRARY_TOKEN` to require account sessions.
Without either credential, the API denies access even on loopback.

Admins generate invite codes, list users, promote/demote accounts, and disable or
re-enable users. Signup always creates a regular user. Codes are single-use, default
to seven days, and can be revoked. Only the creation response contains the code;
listing invites returns status and IDs. All timestamps below are Unix seconds.

```sh
# Sign in; save the returned token as ADMIN_TOKEN.
curl -sS "$API/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"your admin password"}'

# Create an invite; share only the returned code with the intended user.
curl -sS "$API/v1/admin/invites" -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' -d '{"expiresInHours":168}'

# Signup returns {user, token, expiresAt} and consumes the invite atomically.
curl -sS "$API/v1/auth/signup" -H 'Content-Type: application/json' \
  -d '{"email":"reader@example.com","password":"a strong unique password","inviteCode":"CODE"}'
```

Set `API` to your server URL. Passwords require at least 12 characters and at most
1024 UTF-8 bytes. Emails are trimmed and case-insensitive. Passwords use salted
PBKDF2-HMAC-SHA256 with 600,000 iterations; session tokens and invite codes are
random 256-bit values stored as SHA-256 hashes. Sessions last 30 days. Login and
signup share a limit of ten attempts per minute per remote IP, with bounded hashing
concurrency; behind a proxy, clients sharing its address share the limit.

- `POST /v1/auth/login`: `{email,password}` → `{user,token,expiresAt}`.
- `POST /v1/auth/signup`: `{email,password,inviteCode}` → the same response (201).
- `GET /v1/auth/me`: current identity.
- `POST /v1/auth/logout`: revoke the current account session (204).
- `PUT /v1/auth/password`: `{currentPassword,password}`; revokes all account sessions (204), then sign in again.
- `POST /v1/admin/invites`: `{}` or `{expiresInHours:1..720}` → invite including its code (201).
- `GET /v1/admin/invites`: invite status without codes.
- `DELETE /v1/admin/invites/{id}`: revoke an invite (204).
- `GET /v1/admin/users`: list account metadata without credentials.
- `PATCH /v1/admin/users/{id}`: `{role:"admin"|"user",disabled:true|false}` (either field optional); revokes the account’s sessions.

The last active admin cannot be demoted or disabled. Disabled users cannot sign in
or use existing sessions. Regular users can read books/PDFs and sync their own
reading data; book writes and all `/v1/admin/*` routes require admin access.

Connection settings support account sign-in, invite signup, legacy access tokens, public display names, and admin invite creation. Offline caches are keyed by server and account. Admin narration controls appear on book pages; user management and invite listing remain available through the JSON API.

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

Book content is shared across accounts, and only admins can publish or remove it. Each account has private progress, saved books, completion, bookmarks, notes, highlights, reading sessions, and daily goal. Devices signed into the same account sync those records. The app syncs after edits, on refresh, when activated, and every 30 seconds while active.

The library and an outbox are cached per server and account in Application Support. Offline annotations and reading changes save immediately, survive restart, and upload after reconnection. Independent notes and bookmarks merge separately. Conflicts on the same record use the latest edit timestamp, with device ID breaking ties; device clocks should be accurate. Deletions use retained tombstones so an old offline device cannot resurrect an older edit. Book content editing remains last-write-wins and requires the server. Existing device-local progress/bookmarks migrate automatically.

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

All `/v1` requests except login and signup require `Authorization: Bearer TOKEN`. Errors are JSON objects with an `error` field. Browser-origin writes are rejected. Book JSON PUT accepts at most 2 MiB and requires a body ID matching the URL. Sync accepts up to 500 records and 5 MiB per request; the app batches its outbox within those limits. PDF attachment PUT accepts up to 50 MiB. Account and admin management use the JSON API; there is no web admin dependency.

## Narration

Open a summary or chapter and select **Listen**. Sections with attached generated audio use that narrator; other sections use Apple’s installed English voice. The reader highlights the spoken word and follows it automatically. Manual scrolling releases **Follow**; select it again to return to the narration. Playback temporarily uses a single page for tracking, supports 0.75–2× speed, seeking and 15-second skips, and continues in a library mini-player after closing the reader. iOS enables background audio and media controls. Apple’s timeline and time-based seeking are estimates; its word cursor comes from speech callbacks.

Generated narration is private library content and downloads once into a hash-verified local audio cache. Administrators first PUT a book with optional section `narration` metadata (`provider`, `model`, `voice`, and `words`), then PUT MP3 bytes to `/v1/books/{id}/narration/{zeroBasedSection}` (25 MiB maximum). Each word contains `text`, `start`, `end` in seconds, and `offset`, `length` in UTF-16 code units into the unchanged section body. Titles are not spoken. The upload returns audio and body hashes; normal book edits preserve the metadata, while body changes invalidate it. GET on the same route returns authenticated audio with range support. Generated audio currently attaches to summary sections; full-book chapters use Apple voices.

Narration generation is an offline/admin workflow; the app contains no provider keys. Provider or ASR timestamps determine generated-cursor accuracy. This first comparison does not include a listening queue, sleep timer, automatic next-section playback, or playback-position syncing.

## Development and verification

```sh
make test      # Go race tests + vet, then Swift model/cache/contract tests
make mac       # Native macOS build
make ios       # Universal iPhone/iPad Simulator build
```

The Xcode project is checked in. After adding/removing app Swift files, regenerate it with `python3 scripts/generate_project.py`; it uses only Python’s standard library. Shared model files are picked up automatically by the local Swift package.

The Go module has one external dependency, `mattn/go-sqlite3`, pinned in `go.mod`/`go.sum`. Linux builds need CGO and a C toolchain. Stop the server before making a simple file copy of the SQLite database; WAL files can contain recent writes while it is running.

See [the implementation plan and architecture](docs/PLAN.md) for the data ownership, delivery sequence, and first-version limits.

## Automatic PDF and EPUB processing

Open **Uploads**, choose a **10-minute** or **30-minute** summary, then upload a PDF or EPUB (up to 50 MiB, 1,000 pages or EPUB chapters, and 2 million extracted characters). The server extracts text, runs OCR on sparse PDF pages, reads all extracted sections in bounded Codex stages, and publishes a source-grounded summary with readable full text. The same file can be uploaded once for each summary length. PDF uploads retain the original PDF and page links. EPUB uploads preserve chapter reading order and titles in the full-text reader. Actual reading time is calculated from the generated text and can be shorter for short sources. Unreadable or excessively sparse files fail with an actionable error.

Users see their own jobs; admins see the whole queue. Jobs survive restarts, use leases and checkpoints, and expose extraction, summarization, narration, completion and failure states. Failed jobs can be retried. A user can have three active uploads at a time. Change your **display name** in Connection settings before uploading; the finished book shows **Uploaded by …**. Attribution is assigned by the server, survives edits, and never exposes the uploader's email address.

Admins open a book and choose **Generate narration**. **OpenRouter Kokoro** is the default; **ElevenLabs** is also offered. Narration is generated per idea, downloaded privately by readers and cached offline. Kokoro timing comes from local speech recognition and is approximate; ElevenLabs supplies original-text timing. Retry resumes completed sections. A changed summary invalidates stale audio. The app also supports device Apple narration without generation charges.

The worker uses FFmpeg to losslessly finalize MP3 headers before alignment and publication, including reused checkpoints. Provider audio can contain concatenated short MP3 streams whose first header makes Apple's playback clock stop at about five seconds even while the rest keeps playing. Existing audio can be repaired without synthesis charges or changing word timings: run `python3 backend/processing/repair_narrations.py /path/to/library.sqlite` to preview, then add `--apply`. This creates a private SQLite backup and atomically updates audio checksums and book timestamps so a library refresh downloads the corrected files. Use repeated `--book BOOK_ID` arguments to limit the repair. FFmpeg must be installed where the script runs.

The Compose deployment includes a separate worker with Poppler, Tesseract (English OCR by default), Codex CLI and CPU word alignment. Account data and the queue remain in SQLite; private extraction/checkpoint files are in `deploy/data/processing`. Treat these files and database backups as private. The worker waits for its server Codex login before consuming jobs:

```sh
cd /srv/margin/deploy
docker compose run --rm --no-deps worker codex login --device-auth
```

Complete that device login using the displayed URL and code. Codex authentication stays in the `codex_auth` Docker volume. It is not copied from a developer machine. Noninteractive stages use `codex exec` with structured output, read-only sandboxing, shell tools disabled, isolated configuration, and no narration/library API credentials in the Codex subprocess environment. This follows [OpenAI's noninteractive Codex guidance](https://learn.chatgpt.com/docs/non-interactive-mode).

Configure `OPENROUTER_API_KEY` and `ELEVENLABS_API_KEY` in the ignored server `deploy/.env`, then recreate the worker. Optional settings: `CODEX_MODEL`, `OCR_LANGUAGES` (matching installed Tesseract data), `KOKORO_VOICE`, `ELEVENLABS_VOICE`, `ELEVENLABS_MODEL`, and `ALIGNMENT_MODEL`. Voice defaults are Kokoro `af_heart` and ElevenLabs George. Choose a compatible voice for the summary language. Provider credits and Codex account limits apply. No narration runs until an admin requests it.

Local worker: install Python 3, Poppler, Tesseract, FFmpeg, Codex CLI, and `faster-whisper`, sign in to Codex, then run `cd backend && go run ./cmd/library worker`. The API and worker must use the same `-db` path. Server updates preserve the authentication volume and queued jobs.

Additional API routes:

- `POST /v1/uploads?filename=book.pdf&summaryMinutes=30` or `book.epub` — raw PDF or EPUB body, returns a queued job (202). `summaryMinutes` accepts `10` or `30` and defaults to `10`.
- `GET /v1/jobs` — latest 100 jobs visible to the current account.
- `POST /v1/jobs/{id}/retry` — retry a failed upload owned by the caller, or any failed job as admin.
- `POST /v1/admin/books/{id}/narration` — `{ "provider": "openrouter" }` or `elevenlabs`; queues narration (202).
- `PUT /v1/auth/profile` — `{ "displayName": "Your name" }`; applies to future upload attribution.

### Find books on Z-Library

Open **Discover** to browse topics or search by title, author, or idea. Search results show book covers and group editions under one title; use the language menu to narrow the catalog. Books already in your library open directly. Choose a book, select its edition and a 10- or 30-minute read, then tap **Create my read**. Follow preparation in **Activity**, where titles and covers stay attached to their jobs. Finished reads appear in **Library** with the same cover. Use **Activity → Bring your own book** for PDF/EPUB files. Duplicate files and queue limits also apply. On iPhone, Discover, Library, Notebook, and Activity have separate tabs; Mac uses the sidebar.

Configure the API service environment (or `deploy/.env` for Compose):

```dotenv
ZLIBRARY_EMAIL=your-account-email
ZLIBRARY_PASSWORD=your-account-password
# Optional HTTP CONNECT or SOCKS5 proxy reachable from the API process.
ZLIBRARY_PROXY=http://127.0.0.1:10814
# Optional: override the client’s default mirror with your working mirror.
ZLIBRARY_MIRROR=https://your-working-mirror.example
```

Restart/recreate the API service after changing these values. Credentials and upstream cookies stay on the server. Without credentials, search returns an actionable configuration message; local uploads continue to work. Downloads require a working account/mirror, are limited to 50 MiB, and must validate as PDF or EPUB. Downloading happens while the app request is open; summary processing continues in the worker after the request succeeds. The endpoints are authenticated `GET /v1/zlibrary/search?q=...&page=1` and `POST /v1/zlibrary/summarize` with JSON `{"id":"<id/path from search>","summaryMinutes":10}`.

The Z-Library client uses a uTLS-backed Chrome TLS/HTTP2 profile with matching request headers, a session cookie jar, and bounded handling of the mirror’s recognized cookie verification flow. It does not execute remote JavaScript. `ZLIBRARY_PROXY` applies to verification, login, search, and file downloads; when unset, standard `HTTP_PROXY`/`HTTPS_PROXY` environment settings apply. In Docker, `127.0.0.1` refers to the API container: configure a proxy address reachable from that container rather than copying a developer machine’s loopback address.

For an opt-in live smoke test, supply the `ZLIBRARY_*` environment variables and run `ZLIBRARY_LIVE_TEST=1 go test ./internal/zlibrary -run '^TestLiveMirror$' -v -count=1` from `backend`. This logs in, searches, and downloads one public-domain title into memory; it does not publish a summary. Ordinary tests use local mock servers and require no credentials.
