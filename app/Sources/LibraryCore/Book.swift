import Foundation

public struct Section: Codable, Hashable, Sendable {
    public var title: String
    public var body: String
    public var sourcePage: Int?
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
