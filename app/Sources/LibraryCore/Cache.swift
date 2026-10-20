import Foundation

public struct LibraryCache: Codable, Sendable {
    public var books: [Book]
    public var reading: [String: ReadingState]
    public var refreshedAt: Date?
    public var records: [String: ReaderRecord] = [:]
    public var pending: Set<String> = []
    public var migrated = false
    public var syncedAt: Date?
    public init(books: [Book] = [], reading: [String: ReadingState] = [:], refreshedAt: Date? = nil) {
        self.books = books; self.reading = reading; self.refreshedAt = refreshedAt
    }
    public static func load(from url: URL) throws -> LibraryCache {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    private enum CodingKeys: String, CodingKey { case books, reading, refreshedAt, records, pending, migrated, syncedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = try c.decode([Book].self, forKey: .books)
        reading = try c.decodeIfPresent([String: ReadingState].self, forKey: .reading) ?? [:]
        refreshedAt = try c.decodeIfPresent(Date.self, forKey: .refreshedAt)
        records = try c.decodeIfPresent([String: ReaderRecord].self, forKey: .records) ?? [:]
        pending = try c.decodeIfPresent(Set<String>.self, forKey: .pending) ?? []
        migrated = try c.decodeIfPresent(Bool.self, forKey: .migrated) ?? false
        syncedAt = try c.decodeIfPresent(Date.self, forKey: .syncedAt)
    }
    public mutating func merge(_ remote: [ReaderRecord], sent: [ReaderRecord]) {
        let received = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for record in remote {
            if let local = records[record.id], !record.isNewer(than: local) { continue }
            records[record.id] = record
        }
        for record in sent {
            if let current = records[record.id], let acknowledged = received[record.id],
               !record.isNewer(than: acknowledged), !current.isNewer(than: acknowledged) { pending.remove(record.id) }
        }
        syncedAt = Date()
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
