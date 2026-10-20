import XCTest
@testable import LibraryCore

final class ReaderDataTests: XCTestCase {
    func record(_ id: String, stamp: Int64, device: String = "mac") -> ReaderRecord {
        var r = ReaderRecord(id: id, kind: "annotation", bookID: "book", bookTitle: "Book")
        r.updatedAt = stamp; r.deviceID = device; r.text = "A thought"; return r
    }
    func testSyncMergeKeepsConcurrentLocalEditsAndSeparateAnnotations() {
        let sent = record("annotation:one", stamp: 100)
        let editedDuringRequest = record("annotation:one", stamp: 102)
        let remoteOther = record("annotation:two", stamp: 101, device: "phone")
        var cache = LibraryCache(); cache.records[sent.id] = editedDuringRequest; cache.pending.insert(sent.id)
        cache.merge([sent, remoteOther], sent: [sent])
        XCTAssertEqual(cache.records[sent.id]?.updatedAt, 102)
        XCTAssertTrue(cache.pending.contains(sent.id))
        XCTAssertEqual(cache.records.count, 2)
        cache.merge([editedDuringRequest, remoteOther], sent: [editedDuringRequest])
        XCTAssertTrue(cache.pending.isEmpty)
    }
    func testTombstonesAndTimestampTieBreak() {
        let local = record("annotation:one", stamp: 100)
        var deleted = record(local.id, stamp: 101); deleted.deleted = true
        var cache = LibraryCache(); cache.records[local.id] = local
        cache.merge([deleted], sent: []); cache.merge([local], sent: [])
        XCTAssertTrue(cache.records[local.id]!.deleted)
        var winner = deleted; winner.deviceID = "zzz"; winner.text = "Winner"
        cache.merge([winner], sent: []); cache.merge([deleted], sent: [])
        XCTAssertEqual(cache.records[local.id]?.text, "Winner")
    }
    func testOldCacheDecodesWithoutLosingReadingState() throws {
        let json = #"{"books":[],"reading":{"old":{"section":2,"completed":false,"saved":true,"bookmarks":[1]}}}"#
        let cache = try JSONDecoder().decode(LibraryCache.self, from: Data(json.utf8))
        XCTAssertEqual(cache.reading["old"]?.section, 2); XCTAssertEqual(cache.reading["old"]?.bookmarks, [1])
        XCTAssertFalse(cache.migrated); XCTAssertTrue(cache.records.isEmpty)
    }
    func testPendingRecordsSurviveDiskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cache.json")
        var cache = LibraryCache(); let note = record("annotation:offline", stamp: 100)
        cache.records[note.id] = note; cache.pending.insert(note.id)
        try cache.save(to: url)
        let loaded = try LibraryCache.load(from: url)
        XCTAssertEqual(loaded.records[note.id], note); XCTAssertEqual(loaded.pending, [note.id])
    }
    func testFullTextAndNotebookSearch() {
        var book = Book(id: "book", title: "A book", author: "Writer", sections: [Section(title: "Idea", body: "A telescope reveals new possibilities.")])
        book.chapters = [Section(title: "Chapter", body: "A submarine explores below.", sourcePage: 7)]
        var note = record("annotation:one", stamp: 1); note.text = "My personal observatory"
        var deleted = note; deleted.id = "annotation:deleted"; deleted.deleted = true
        XCTAssertEqual(BookSearch.matches(books: [book], records: [], query: "TELESCOPE").first?.location, .summary)
        XCTAssertEqual(BookSearch.matches(books: [book], records: [], query: "submarine").first?.location, .chapter)
        XCTAssertEqual(BookSearch.matches(books: [book], records: [note, deleted], query: "observatory").count, 1)
        XCTAssertTrue(book.matches("submarine"))
    }
    func testHabitAggregationAndStreakIncludingMissedDay() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12))!
        var sessions: [ReaderRecord] = []
        for (i, day) in ["2026-10-18", "2026-10-19", "2026-10-19"].enumerated() {
            var r = record("session:\(i)", stamp: Int64(i+1)); r.kind = "session"; r.day = day; r.seconds = i == 0 ? 600 : 300; sessions.append(r)
        }
        let days = Habits.days(records: sessions, now: now, count: 4, calendar: calendar)
        XCTAssertEqual(days.last?.seconds, 0)
        XCTAssertEqual(days[2].seconds, 600)
        XCTAssertEqual(Habits.streak(days: days, goal: 600), 2)
        sessions[1].deleted = true
        XCTAssertEqual(Habits.streak(days: Habits.days(records: sessions, now: now, count: 4, calendar: calendar), goal: 600), 0)
    }
}
