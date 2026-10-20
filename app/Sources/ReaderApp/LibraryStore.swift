import SwiftUI
import LibraryCore
import CryptoKit
import Security

@MainActor @Observable final class LibraryStore {
    var cache = LibraryCache()
    var isLoading = false
    var isSyncing = false
    var error: String?
    var syncError: String?
    var notice: String?
    var server: String
    private(set) var token: String
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let deviceID: String

    var books: [Book] { cache.books }
    var records: [ReaderRecord] { Array(cache.records.values) }
    var annotations: [ReaderRecord] { records.filter { $0.kind == "annotation" && !$0.deleted }.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt } }
    var sessions: [ReaderRecord] { records.filter { $0.kind == "session" && !$0.deleted }.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt } }
    var goalSeconds: Int { cache.records["goal"].flatMap { $0.deleted ? nil : $0.seconds } ?? 600 }
    private var serverKey: String { SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined() }
    private var cacheURL: URL { URL.applicationSupportDirectory.appending(path: "Margin/\(serverKey).json") }

    init() {
        let initial = UserDefaults.standard.string(forKey: "server") ?? "http://127.0.0.1:8787"
        server = initial; token = Keychain.read(account: initial)
        let device = UserDefaults.standard.string(forKey: "deviceID") ?? UUID().uuidString.lowercased()
        deviceID = device; UserDefaults.standard.set(device, forKey: "deviceID")
        loadCache()
    }

    func state(_ book: Book, location: ReadingLocation = .summary) -> ReadingState {
        var state = ReadingState()
        if let progress = cache.records["progress:\(book.id):\(location.rawValue)"], !progress.deleted {
            state.section = progress.section; state.completed = progress.completed
            if progress.updatedAt > 1 { state.lastReadAt = progress.date }
        }
        if let saved = cache.records["saved:\(book.id)"], !saved.deleted { state.saved = saved.value }
        state.bookmarks = Set(records.filter { $0.kind == "bookmark" && $0.bookID == book.id && $0.location == location.rawValue && !$0.deleted }.map(\.section))
        return state
    }
    func update(_ book: Book, location: ReadingLocation = .summary, _ edit: (inout ReadingState) -> Void) {
        let old = state(book, location: location); var new = old; edit(&new)
        if old.section != new.section || old.completed != new.completed || old.lastReadAt != new.lastReadAt {
            var record = ReaderRecord(id: "progress:\(book.id):\(location.rawValue)", kind: "progress", bookID: book.id, bookTitle: book.title)
            record.location = location.rawValue; record.section = new.section; record.completed = new.completed; put(record)
        }
        if old.saved != new.saved {
            var record = ReaderRecord(id: "saved:\(book.id)", kind: "saved", bookID: book.id, bookTitle: book.title)
            record.value = new.saved; put(record)
        }
        for index in old.bookmarks.symmetricDifference(new.bookmarks) {
            var record = ReaderRecord(id: "bookmark:\(book.id):\(location.rawValue):\(index)", kind: "bookmark", bookID: book.id, bookTitle: book.title)
            record.location = location.rawValue; record.section = index; record.deleted = !new.bookmarks.contains(index); put(record)
        }
    }
    func put(_ input: ReaderRecord) {
        var record = input
        let previous = cache.records.values.map(\.updatedAt).max() ?? 0
        record.updatedAt = max(Int64(Date().timeIntervalSince1970 * 1000), previous + 1)
        record.deviceID = deviceID
        cache.records[record.id] = record; cache.pending.insert(record.id); persist(); scheduleSync()
    }
    func remove(_ record: ReaderRecord) { var record = record; record.deleted = true; put(record) }
    func setGoal(minutes: Int) {
        var record = ReaderRecord(id: "goal", kind: "goal"); record.seconds = min(max(minutes, 1), 240) * 60; put(record)
    }
    func recordSession(book: Book, location: ReadingLocation, seconds: Int, day: Date) {
        guard seconds > 0 else { return }
        var record = ReaderRecord(id: "session:" + UUID().uuidString.lowercased(), kind: "session", bookID: book.id, bookTitle: book.title)
        record.location = location.rawValue; record.seconds = min(seconds, 3600); record.day = Habits.dayKey(day); put(record)
    }
    func annotations(bookID: String, location: ReadingLocation? = nil, section: Int? = nil) -> [ReaderRecord] {
        annotations.filter { $0.bookID == bookID && (location == nil || $0.location == location?.rawValue) && (section == nil || $0.section == section) }
    }
    private func migrate() {
        guard !cache.migrated else { return }
        for book in cache.books {
            guard let old = cache.reading[book.id] else { continue }
            var progress = ReaderRecord(id: "progress:\(book.id):summary", kind: "progress", bookID: book.id, bookTitle: book.title)
            progress.section = old.section; progress.completed = old.completed
            progress.updatedAt = max(1, Int64((old.lastReadAt?.timeIntervalSince1970 ?? 0)*1000)); progress.deviceID = deviceID
            var migrated = [progress]
            if old.saved { var saved = ReaderRecord(id: "saved:\(book.id)", kind: "saved", bookID: book.id, bookTitle: book.title); saved.value = true; saved.deviceID = deviceID; migrated.append(saved) }
            for section in old.bookmarks { var record = ReaderRecord(id: "bookmark:\(book.id):summary:\(section)", kind: "bookmark", bookID: book.id, bookTitle: book.title); record.section = section; record.deviceID = deviceID; migrated.append(record) }
            for record in migrated where cache.records[record.id] == nil { cache.records[record.id] = record; cache.pending.insert(record.id) }
        }
        cache.reading = [:]; cache.migrated = true; persist()
    }
    private func loadCache() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { cache = LibraryCache(); cache.migrated = true; return }
        do { cache = try LibraryCache.load(from: cacheURL); migrate() }
        catch { cache = LibraryCache(); notice = "The offline library could not be loaded: \(error.localizedDescription)" }
    }
    private func persist() {
        do { try cache.save(to: cacheURL) }
        catch { notice = "Could not save your offline library: \(error.localizedDescription)" }
    }
    private func scheduleSync() {
        // Cancel a waiting debounce, not an in-flight network exchange.
        if isSyncing { return }
        syncTask?.cancel()
        syncTask = Task {
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            await sync()
        }
    }
    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true; let origin = server
        defer { isSyncing = false; if !cache.pending.isEmpty && syncError == nil { scheduleSync() } }
        do {
            let api = try LibraryAPI(server: server, token: token)
            var sent: [ReaderRecord] = []; var bytes = 32
            for id in cache.pending.sorted() {
                guard let record = cache.records[id] else { continue }
                let size = try JSONEncoder().encode(record).count + 1
                if sent.count >= 100 || bytes + size > 4 * 1024 * 1024 { break }
                sent.append(record); bytes += size
            }
            let remote = try await api.sync(sent)
            guard server == origin else { return }
            cache.merge(remote, sent: sent); syncError = nil; persist()
        } catch { if server == origin { syncError = error.localizedDescription } }
    }
    func refresh() async {
        guard !isLoading else { return }; isLoading = true; error = nil
        let origin = server
        defer { isLoading = false }
        do {
            let books = try await LibraryAPI(server: server, token: token).books()
            guard origin == server else { return }
            cache.books = books; cache.refreshedAt = Date(); persist(); await sync()
        } catch { if origin == server { self.error = error.localizedDescription } }
    }
    func connect(server: String, token: String) async throws {
        guard !isLoading && !isSyncing else { throw APIError.response(409, "Wait for the current refresh or sync to finish, then connect again.") }
        let api = try LibraryAPI(server: server, token: token)
        isLoading = true; defer { isLoading = false }
        let books = try await api.books()
        let normalized = api.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try Keychain.write(token, account: normalized)
        syncTask?.cancel(); self.server = normalized; self.token = token
        UserDefaults.standard.set(normalized, forKey: "server")
        loadCache(); cache.books = books; cache.refreshedAt = Date(); error = nil; syncError = nil; persist(); await sync()
    }
    func save(_ book: Book) async throws {
        let origin = server
        let saved = try await LibraryAPI(server: server, token: token).save(book)
        guard origin == server else { return }
        cache.books.removeAll { $0.id == saved.id }; cache.books.insert(saved, at: 0); persist()
    }
    func delete(_ book: Book) async throws {
        let origin = server
        try await LibraryAPI(server: server, token: token).delete(book.id)
        guard origin == server else { return }
        cache.books.removeAll { $0.id == book.id }; persist()
    }
    func uploadPDF(book: Book, url: URL) async throws {
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50 * 1024 * 1024 else { throw APIError.response(413, "Source PDF must be at most 50 MiB") }
        let data = try Data(contentsOf: url)
        let origin = server
        let source = try await LibraryAPI(server: server, token: token).uploadPDF(book.id, filename: url.lastPathComponent, data: data)
        guard origin == server else { return }
        if let index = cache.books.firstIndex(where: { $0.id == book.id }) { cache.books[index].source = source }
        try savePDF(data: data, bookID: book.id, hash: source.sha256); persist()
    }
    private func pdfURL(bookID: String, hash: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "Margin/PDFs/\(serverKey)/\(bookID)-\(hash).pdf")
    }
    private func savePDF(data: Data, bookID: String, hash: String) throws {
        let url = pdfURL(bookID: bookID, hash: hash)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    func sourceURL(book: Book) async throws -> URL {
        guard let source = book.source else { throw APIError.response(404, "No source PDF attached") }
        let url = pdfURL(bookID: book.id, hash: source.sha256)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let origin = server
        let data = try await LibraryAPI(server: server, token: token).pdf(book.id)
        guard origin == server else { throw CancellationError() }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == source.sha256 else { throw APIError.response(409, "Source changed on the server. Refresh the library and try again.") }
        try savePDF(data: data, bookID: book.id, hash: hash); return url
    }
}

private enum Keychain {
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.margin.reader", kSecAttrAccount as String: account]
    }
    static func read(account: String) -> String {
        var q = query(account); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ token: String, account: String) throws {
        let q = query(account)
        if token.isEmpty { SecItemDelete(q as CFDictionary); return }
        let value = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(q as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(value) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not securely store the server token (\(status))."])
        }
    }
}
