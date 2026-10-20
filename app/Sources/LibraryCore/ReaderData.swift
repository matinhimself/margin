import Foundation

public enum ReadingLocation: String, Codable, CaseIterable, Sendable {
    case summary, chapter, pdf
    public var label: String { switch self { case .summary: "Summary"; case .chapter: "Full book"; case .pdf: "Source PDF" } }
}

public struct ReaderRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var bookID = ""
    public var bookTitle = ""
    public var updatedAt: Int64 = 1
    public var deviceID = ""
    public var deleted = false
    public var location = "summary"
    public var section = 0
    public var completed = false
    public var value = false
    public var text = ""
    public var quote = ""
    public var color = "yellow"
    public var seconds = 0
    public var day = ""
    public var offset = 0
    public var length = 0
    public var sourceHash = ""
    public init(id: String, kind: String, bookID: String = "", bookTitle: String = "") {
        self.id = id; self.kind = kind; self.bookID = bookID; self.bookTitle = bookTitle
    }
    public func isNewer(than other: Self) -> Bool {
        updatedAt > other.updatedAt || (updatedAt == other.updatedAt && deviceID > other.deviceID)
    }
    public var date: Date { Date(timeIntervalSince1970: Double(updatedAt)/1000) }
}

public struct SyncEnvelope: Codable, Sendable {
    public var records: [ReaderRecord]
    public init(records: [ReaderRecord]) { self.records = records }
}

public struct HabitDay: Identifiable, Sendable {
    public var id: String
    public var seconds: Int
    public var date: Date
}

public enum Habits {
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    public static func days(records: [ReaderRecord], now: Date = Date(), count: Int = 30, calendar: Calendar = .current) -> [HabitDay] {
        let sums = records.filter { $0.kind == "session" && !$0.deleted }.reduce(into: [String: Int]()) { $0[$1.day, default: 0] += $1.seconds }
        return (0..<max(0,count)).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = dayKey(date, calendar: calendar)
            return HabitDay(id: key, seconds: sums[key, default: 0], date: date)
        }
    }
    public static func streak(days: [HabitDay], goal: Int) -> Int {
        var days = days
        if let today = days.last, today.seconds < goal { days.removeLast() }
        return days.reversed().prefix { $0.seconds >= goal }.count
    }
}

public struct BookMatch: Identifiable, Sendable {
    public var id: String { "\(bookID):\(location.rawValue):\(section):\(annotationID ?? "")" }
    public var bookID: String
    public var bookTitle: String
    public var location: ReadingLocation
    public var section: Int
    public var heading: String
    public var excerpt: String
    public var annotationID: String?
    public init(bookID: String, bookTitle: String, location: ReadingLocation, section: Int, heading: String, excerpt: String, annotationID: String? = nil) {
        self.bookID = bookID; self.bookTitle = bookTitle; self.location = location; self.section = section; self.heading = heading; self.excerpt = excerpt; self.annotationID = annotationID
    }
}

public enum BookSearch {
    public static func matches(books: [Book], records: [ReaderRecord], query: String, bookID: String? = nil) -> [BookMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var results: [BookMatch] = []
        for book in books where bookID == nil || book.id == bookID {
            if [book.title, book.author, book.subtitle, book.category, book.synopsis].joined(separator: " ").localizedCaseInsensitiveContains(q) {
                results.append(BookMatch(bookID: book.id, bookTitle: book.title, location: .summary, section: 0, heading: "Book overview", excerpt: excerpt(book.synopsis, query: q)))
            }
            for location in [ReadingLocation.summary, .chapter] {
                let sections = location == .summary ? book.sections : book.chapters ?? []
                for (index, section) in sections.enumerated() where (section.title + " " + section.body).localizedCaseInsensitiveContains(q) {
                    results.append(BookMatch(bookID: book.id, bookTitle: book.title, location: location, section: index, heading: section.title, excerpt: excerpt(section.body, query: q)))
                }
            }
        }
        for record in records where record.kind == "annotation" && !record.deleted && (bookID == nil || record.bookID == bookID) {
            if (record.text + " " + record.quote).localizedCaseInsensitiveContains(q) {
                results.append(BookMatch(bookID: record.bookID, bookTitle: record.bookTitle, location: ReadingLocation(rawValue: record.location) ?? .summary, section: record.section, heading: record.quote.isEmpty ? "Note" : "Highlight & note", excerpt: excerpt(record.quote + " " + record.text, query: q), annotationID: record.id))
            }
        }
        return results
    }
    private static func excerpt(_ text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(180)) }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        return (start > text.startIndex ? "…" : "") + text[start...].prefix(200) + (text.distance(from: start, to: text.endIndex) > 200 ? "…" : "")
    }
}
