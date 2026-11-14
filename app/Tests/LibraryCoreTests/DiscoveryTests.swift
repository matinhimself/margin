import XCTest
@testable import LibraryCore

final class DiscoveryTests: XCTestCase {
    func testGroupsEditionsWithoutMergingAuthorsOrDuplicatingPages() {
        let first = ZLibraryBook(id: "one", title: "Thinking, Fast and Slow", authors: ["Daniel Kahneman"], extension: "PDF")
        let second = ZLibraryBook(id: "two", title: "THINKING FAST AND SLOW", authors: ["Kahneman, Daniel"], extension: "EPUB")
        let other = ZLibraryBook(id: "three", title: "Thinking Fast and Slow", authors: ["Another Author"])
        let groups = DiscoveryBook.grouped([first, second, other, first])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].editions.map(\.id), ["one", "two"])
        XCTAssertEqual(groups[1].book.authors, ["Another Author"])
    }
    func testOldSearchResponseWithoutCoversStillDecodes() throws {
        let json = #"{"books":[{"id":"one","title":"Book","authors":["Author"],"year":"2020","language":"english","extension":"PDF","size":"1 MB"}],"page":1,"totalPages":1}"#
        let result = try JSONDecoder().decode(ZLibrarySearchResult.self, from: Data(json.utf8))
        XCTAssertNil(result.books[0].cover)
    }
}
