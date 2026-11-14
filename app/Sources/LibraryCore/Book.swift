import Foundation

public struct NarrationWord: Codable, Hashable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var offset: Int
    public var length: Int
    public var range: NSRange { NSRange(location: offset, length: length) }
}
public struct Narration: Codable, Hashable, Sendable {
    public var provider: String
    public var model: String
    public var voice: String
    public var sha256: String?
    public var bodySHA256: String?
    public var words: [NarrationWord]
    public func word(at time: Double) -> NarrationWord? {
        // Binary search keeps cursor updates cheap for full chapters.
        var low = 0; var high = words.count
        while low < high { let mid = (low + high) / 2; if words[mid].start <= time { low = mid + 1 } else { high = mid } }
        guard low > 0, time < words[low - 1].end else { return nil }
        return words[low - 1]
    }
}

public struct Section: Codable, Hashable, Sendable {
    public var title: String
    public var body: String
    public var sourcePage: Int?
    public var narration: Narration?
    public init(title: String = "", body: String = "", sourcePage: Int? = nil) { self.title = title; self.body = body; self.sourcePage = sourcePage }
}

public struct BookSource: Codable, Hashable, Sendable {
    public var filename: String
    public var sha256: String
    public init(filename: String, sha256: String) { self.filename = filename; self.sha256 = sha256 }
}

public struct Book: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var subtitle: String
    public var category: String
    public var color: String
    public var minutes: Int
    public var synopsis: String
    public var sections: [Section]
    public var updatedAt: String
    public var chapters: [Section]?
    public var source: BookSource?
    public var uploadedBy: BookUploader?
    public var language: String?
    public var coverURL: String?

    public init(id: String = UUID().uuidString.lowercased(), title: String = "", author: String = "", subtitle: String = "", category: String = "General", color: String = "#DCE9C9", minutes: Int = 10, synopsis: String = "", sections: [Section] = [Section()], updatedAt: String = "") {
        self.id = id; self.title = title; self.author = author; self.subtitle = subtitle
        self.category = category; self.color = color; self.minutes = minutes
        self.synopsis = synopsis; self.sections = sections; self.updatedAt = updatedAt
    }

    public func matches(_ query: String) -> Bool {
        query.isEmpty || ([title, author, subtitle, category, synopsis] + (sections + (chapters ?? [])).flatMap { [$0.title, $0.body] }).joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    public var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !sections.isEmpty && (sections + (chapters ?? [])).allSatisfy {
            !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public struct ReadingState: Codable, Equatable, Sendable {
    public var section: Int = 0
    public var completed: Bool = false
    public var saved: Bool = false
    public var bookmarks: Set<Int> = []
    public var lastReadAt: Date?
    public init() {}
    public func progress(sectionCount: Int) -> Double {
        guard sectionCount > 0 else { return 0 }
        return completed ? 1 : Double(min(max(section, 0), sectionCount - 1)) / Double(sectionCount)
    }
}
