import XCTest
@testable import LibraryCore

final class LibraryCoreTests: XCTestCase {
    func testReadingProgressClampsAfterBookEdits() {
        var state = ReadingState()
        state.section = 12
        XCTAssertEqual(state.progress(sectionCount: 3), 2.0/3.0)
        state.section = -1
        XCTAssertEqual(state.progress(sectionCount: 3), 0)
        state.completed = true
        XCTAssertEqual(state.progress(sectionCount: 3), 1)
        XCTAssertEqual(state.progress(sectionCount: 0), 0)
    }
    func testOfflineRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache.json")
        let book = Book(title: "Focus", author: "Margin", sections: [Section(title: "Start", body: "Start small.")])
        var state = ReadingState(); state.bookmarks.insert(0); state.saved = true
        let cache = LibraryCache(books: [book], reading: [book.id: state])
        try cache.save(to: url)
        let loaded = try LibraryCache.load(from: url)
        XCTAssertEqual(loaded.books, [book]); XCTAssertEqual(loaded.reading[book.id], state)
    }
    func testSearchAndValidation() {
        var book = Book(title: "Small steps", author: "A Writer", category: "Habits", sections: [Section(title: "Begin", body: "Take a step.")])
        XCTAssertTrue(book.matches("HABITS")); XCTAssertTrue(book.matches("writer")); XCTAssertFalse(book.matches("finance"))
        XCTAssertTrue(book.isValid)
        book.sections[0].body = "  \n"
        XCTAssertFalse(book.isValid)
    }
    func testServerURLValidation() throws {
        for url in ["", "file:///tmp/books", "http://", "http://host/path", "https://host?q=x", "https://host/#x", "https://user:pass@host"] {
            XCTAssertThrowsError(try LibraryAPI(server: url, token: ""), url)
        }
        XCTAssertEqual(try LibraryAPI(server: "http://127.0.0.1:8080/", token: "").baseURL.host, "127.0.0.1")
    }
    func testProxyConfiguration() throws {
        for kind in [LibraryProxy.Kind.http, .socks5] {
            let proxy = LibraryProxy(kind: kind, host: " 127.0.0.1 ", port: 1080, username: "reader", password: "secret")
            XCTAssertEqual(try proxy.validated().host, "127.0.0.1")
            let configuration = URLSessionConfiguration.default
            proxy.configure(configuration)
            XCTAssertEqual(configuration.proxyConfigurations.count, 1)
            XCTAssertEqual(configuration.proxyConfigurations.first?.allowFailover, false)
            XCTAssertNoThrow(try LibraryAPI(server: "https://example.com", token: "", proxy: proxy))
        }
        XCTAssertThrowsError(try LibraryProxy(kind: .http, host: "", port: 8080).validated())
        XCTAssertThrowsError(try LibraryProxy(kind: .socks5, host: "localhost", port: 0).validated())
        XCTAssertThrowsError(try LibraryProxy(kind: .http, host: "http://proxy", port: 8080).validated())
        XCTAssertThrowsError(try LibraryProxy(kind: .http, host: "proxy", port: 8080, password: "secret").validated())
    }
    func testGoJSONCompatibility() throws {
        let json = ##"{"id":"one","title":"Focus","author":"Margin","subtitle":"An idea","category":"Focus","color":"#DCE9C9","minutes":5,"synopsis":"A read","sections":[{"title":"Begin","body":"Choose one thing."}],"updatedAt":"2026-10-20T00:00:00Z"}"##
        let book = try JSONDecoder().decode(Book.self, from: Data(json.utf8))
        XCTAssertEqual(book.sections.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book)), book)
    }
}
