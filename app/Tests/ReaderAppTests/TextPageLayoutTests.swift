import XCTest
@testable import ReaderApp

@MainActor
final class TextPageLayoutTests: XCTestCase {
    #if os(macOS)
    func testSinglePageMeasurementExceedsViewportAndSurvivesWidthProbes() {
        let paragraph = String(repeating: "A long chapter must remain scrollable in a full-screen reader. ", count: 8)
        let text = String(repeating: paragraph + "\n\n", count: 30)
        let first = ReaderTextLayout.size(text: text, fontSize: 23, width: 634)
        _ = ReaderTextLayout.size(text: text, fontSize: 23, width: 1920)
        _ = ReaderTextLayout.size(text: text, fontSize: 23, width: 1)
        let repeated = ReaderTextLayout.size(text: text, fontSize: 23, width: 634)
        XCTAssertGreaterThan(first.height, 1000)
        XCTAssertEqual(first, repeated)
        XCTAssertGreaterThan(first.height, ReaderTextLayout.size(text: text, fontSize: 23, width: 900).height)
    }
    #endif

    func testPagesCoverEntireUnicodeChapterWithoutGapsOrDuplicates() {
        let text = String(repeating: "A thoughtful reader 👩🏽‍💻 explores café, فارسی, and 日本語.\n\n", count: 80)
        let source = text as NSString
        let pages = TextPageLayout.ranges(text: text, fontSize: 21, size: CGSize(width: 320, height: 400))
        XCTAssertGreaterThan(pages.count, 2)
        var end = 0
        for range in pages {
            XCTAssertEqual(range.location, end)
            XCTAssertGreaterThan(range.length, 0)
            end = NSMaxRange(range)
        }
        XCTAssertEqual(end, source.length)
        XCTAssertEqual(pages.map { source.substring(with: $0) }.joined(), text)
    }

    func testLargerFontAndSmallerPagesReflowText() {
        let text = String(repeating: "Reading should flow naturally from the left page to the right page. ", count: 100)
        let normal = TextPageLayout.ranges(text: text, fontSize: 21, size: CGSize(width: 400, height: 600))
        let largeFont = TextPageLayout.ranges(text: text, fontSize: 32, size: CGSize(width: 400, height: 600))
        let narrow = TextPageLayout.ranges(text: text, fontSize: 21, size: CGSize(width: 280, height: 400))
        XCTAssertGreaterThan(largeFont.count, normal.count)
        XCTAssertGreaterThan(narrow.count, normal.count)
        XCTAssertEqual(TextPageLayout.ranges(text: "", fontSize: 21, size: CGSize(width: 400, height: 600)), [])
    }
}
