# Local verification

Verified on the development Mac with Go 1.25.5, Swift 6.3.3, and Xcode's macOS/iOS 26.5 SDKs. App deployment targets remain macOS 14 and iOS/iPadOS 17.

- Go race tests and `go vet`: passed. Coverage includes authenticated CRUD, search/topic filters, invalid input, browser-origin write rejection, all-or-nothing imports, duplicate IDs, and persistence across database reopen.
- Swift package: five tests passed. Checks cover JSON compatibility, atomic offline cache round trips, bookmarks/saved state, clamped reading progress after content edits, input validation, and server URL validation.
- Native macOS Xcode build: passed for arm64.
- Universal iOS Simulator Xcode build: passed. Launched on iPhone 17 Pro and iPad Pro 11-inch (M5), and verified both loaded all six books from the real Go API.
- Native Mac UI: checked library/details, reader navigation, a section bookmark surviving navigation away and back, and manual editor publishing. Confirmed the resulting timestamp through the live API.
- Offline behavior: stopped the real server, refreshed the Mac app, and confirmed that six cached books remained available with an offline status. Restarted the service and verified refresh cleared that status.
- JSON, property-list/project syntax, and whitespace checks passed.

Physical-device signing/install, App Store distribution, and execution on the minimum supported OS versions were not tested. The demo books were subsequently removed from the personal library.

## Synced notebook, source books, search, and habits

- Go race tests and vet pass with the new reader-record and PDF storage endpoints. Additional tests cover independent edits from two devices, stale edits, deletion tombstones, deterministic ties, session retry idempotency, atomic invalid-batch rejection, source metadata surviving edits, full-chapter search, and notes surviving book deletion.
- Eleven Swift tests pass, including offline outbox disk round trips, migration decoding of old caches, in-flight sync edits, tombstone handling, chapter/annotation search, habit totals, and streaks around missed days.
- Current macOS and iOS Simulator builds pass. iPhone/iPad share the same SwiftUI target and PDFKit integration.
- A separate `local.margin.qa` app and SQLite database on port 8879 were used for UI checks; no test books were inserted into the personal library.
- In the Mac app, selected text through the native context menu, saved a highlight with a note, and visually verified its colored overlay. Confirmed that the annotation reached SQLite through the real sync API.
- Opened a linked PDF page from the summary, created a page note while the server was stopped, quit/reopened the app offline, and verified that both the note and pending changes survived. Restarted the service, refreshed, and verified the offline note reached the server without replacing a separate simulated-device note.
- Verified that the notebook showed both local and remote notes, the habit dashboard displayed the recorded reading sessions, and passage search found full-book text and opened its original chapter.
- Installed an isolated build on the iPhone simulator. It pulled the Mac-created highlight and notes from the same server, rendered the highlight correctly, and exposed source links and native reader controls.
- Verified CLI PDF attachment and the PDF-to-Margin validator against exported content containing full chapters and source metadata.

The personal library remains empty, with its updated server at `http://127.0.0.1:8787`. Sync shares one personal library through this server; it is not an iCloud or multi-account service. Source search and highlight creation require selectable PDF text. Device clocks affect same-record conflict ordering. Text section references remain positional across content reordering.

## Integrated discovery (2026-10-30)

- Native iPhone navigation now has Discover, Library, Notebook, and Activity tabs. Discovery supports topic browsing, live search, language selection, grouped editions, high-resolution covers, ready-book links, and a 10/30-minute selection sheet.
- Inspected Discover, the edition/length sheet, and Activity on the iPhone 17 simulator against the live backend. Verified the length selection updates its action and topic changes load new results.
- Twenty Swift tests pass, including edition grouping, repeated-page deduplication, author-name order, and decoding older catalog responses. Go race tests and vet pass; integration tests verify processing metadata and language filtering.
- Deployed API and worker support for catalog IDs, titles, authors, and covers, including migration of existing jobs. Live production discovery returned 51 English editions and 50 cover URLs.
- Signed release build 3 was installed wirelessly on the paired iPhone. Installation succeeded; subsequent remote launch/inspection encountered intermittent device connection timeouts.
