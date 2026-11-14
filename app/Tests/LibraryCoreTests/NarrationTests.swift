import XCTest
@testable import LibraryCore

final class NarrationTests: XCTestCase {
    func testCursorBoundariesPausesAndUTF16Ranges() throws {
        let json = #"{"provider":"test","model":"model","voice":"voice","words":[{"text":"👋","start":0,"end":0.4,"offset":0,"length":2},{"text":"Hello","start":0.7,"end":1.4,"offset":3,"length":5}]}"#
        let narration = try JSONDecoder().decode(Narration.self, from: Data(json.utf8))
        XCTAssertNil(narration.word(at: -1))
        XCTAssertEqual(narration.word(at: 0)?.range, NSRange(location: 0, length: 2))
        XCTAssertNil(narration.word(at: 0.4))
        XCTAssertNil(narration.word(at: 0.6))
        XCTAssertEqual(narration.word(at: 0.7)?.text, "Hello")
        XCTAssertEqual(narration.word(at: 1.2)?.range, NSRange(location: 3, length: 5))
        XCTAssertNil(narration.word(at: 1.4))
        XCTAssertNil(narration.word(at: 100))
        XCTAssertEqual(try JSONDecoder().decode(Narration.self, from: JSONEncoder().encode(narration)), narration)
    }
}
