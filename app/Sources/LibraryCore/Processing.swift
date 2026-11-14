import Foundation

public struct BookUploader: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
}
public struct LibraryUser: Codable, Sendable {
    public var id: String
    public var email: String
    public var role: String
    public var displayName: String?
    public var isAdmin: Bool { role == "admin" }
}
public struct LibraryLogin: Codable, Sendable {
    public var user: LibraryUser
    public var token: String
    public var expiresAt: Int64
}
public struct LibraryInvite: Codable, Sendable {
    public var code: String
    public var expiresAt: Int64
}
public struct ProcessingJob: Codable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var status: String
    public var filename: String
    public var bookID: String
    public var provider: String
    public var uploadedBy: BookUploader
    public var progress: String
    public var error: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var attempts: Int
    public var catalogID: String?
    public var title: String?
    public var author: String?
    public var cover: String?
    public var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? filename }
    public var summaryMinutes: Int?
    public var isActive: Bool { status != "complete" && status != "failed" }
    public var statusLabel: String {
        switch status {
        case "queued": "Queued"
        case "extracting": "Extracting text"
        case "summarizing": "Writing summary"
        case "narrating": "Generating narration"
        case "complete": "Ready"
        case "failed": "Needs attention"
        default: status.capitalized
        }
    }
}

public struct ZLibraryBook: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var authors: [String]
    public var year: String
    public var language: String
    public var `extension`: String
    public var size: String
    public var cover: String?
    public init(id: String, title: String, authors: [String], year: String = "", language: String = "", extension format: String = "", size: String = "", cover: String? = nil) {
        self.id=id; self.title=title; self.authors=authors; self.year=year; self.language=language; self.extension=format; self.size=size; self.cover=cover
    }
}
public struct ZLibrarySearchResult: Codable, Sendable {
    public var books: [ZLibraryBook]
    public var page: Int
    public var totalPages: Int
}

public struct DiscoveryBook: Identifiable, Sendable {
    public let id: String
    public let editions: [ZLibraryBook]
    public var book: ZLibraryBook { editions[0] }
    public static func key(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func authorKey(_ author: String) -> String { key(author).split(separator: " ").sorted().joined(separator: " ") }
    public static func grouped(_ books: [ZLibraryBook]) -> [DiscoveryBook] {
        var order: [String] = []; var groups: [String: [ZLibraryBook]] = [:]; var seen = Set<String>()
        for book in books where seen.insert(book.id).inserted {
            let key = key(book.title) + "|" + authorKey(book.authors.first ?? "")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(book)
        }
        return order.map { DiscoveryBook(id: $0, editions: groups[$0]!) }
    }
}
