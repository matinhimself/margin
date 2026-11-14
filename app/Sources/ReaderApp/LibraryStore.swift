import SwiftUI
import LibraryCore
import CryptoKit
import Security

@MainActor @Observable final class LibraryStore {
    let narration = NarrationPlayer()
    var user: LibraryUser?
    var jobs: [ProcessingJob] = []
    var processingError: String?
    var isAdmin: Bool { user?.isAdmin == true }
    var cache = LibraryCache()
    var isLoading = false
    var isSyncing = false
    var error: String?
    var syncError: String?
    var notice: String?
    var server: String
    var proxy: LibraryProxy
    private(set) var token: String
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private var cacheAccountID: String

    var books: [Book] { cache.books }
    var records: [ReaderRecord] { Array(cache.records.values) }
    var annotations: [ReaderRecord] { records.filter { $0.kind == "annotation" && !$0.deleted }.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt } }
    var sessions: [ReaderRecord] { records.filter { $0.kind == "session" && !$0.deleted }.sorted { $0.updatedAt == $1.updatedAt ? $0.id > $1.id : $0.updatedAt > $1.updatedAt } }
    var goalSeconds: Int { cache.records["goal"].flatMap { $0.deleted ? nil : $0.seconds } ?? 600 }
    private var serverKey: String { SHA256.hash(data: Data((server + (cacheAccountID == "legacy" ? "" : "\n" + cacheAccountID)).utf8)).map { String(format: "%02x", $0) }.joined() }
    private var cacheURL: URL { URL.applicationSupportDirectory.appending(path: "Margin/\(serverKey).json") }

    init() {
        #if DEBUG
        let defaultServer = "http://127.0.0.1:8787"
        #else
        let defaultServer = "https://books.0xff.shop:8443"
        #endif
        #if DEBUG
        let testEnvironment = ProcessInfo.processInfo.environment
        let testServer = testEnvironment["MARGIN_TEST_TOKEN"] == nil ? nil : testEnvironment["MARGIN_TEST_SERVER"]
        let testToken = testServer == nil ? nil : testEnvironment["MARGIN_TEST_TOKEN"]
        #else
        let testServer: String? = nil
        let testToken: String? = nil
        #endif
        let initial = testServer ?? UserDefaults.standard.string(forKey: "server") ?? defaultServer
        server = initial; token = testToken ?? Keychain.read(account: initial)
        if let data = UserDefaults.standard.data(forKey: "libraryProxy"),
           let saved = try? JSONDecoder().decode(LibraryProxy.self, from: data) {
            let restored = LibraryProxy(kind: saved.kind, host: saved.host, port: saved.port,
                                        username: saved.username, password: Keychain.read(account: "libraryProxyPassword"))
            proxy = (try? restored.validated()) ?? .system
        } else { proxy = .system }
        cacheAccountID = UserDefaults.standard.string(forKey: "accountID:" + initial) ?? "legacy"
        let device = UserDefaults.standard.string(forKey: "deviceID") ?? UUID().uuidString.lowercased()
        deviceID = device; UserDefaults.standard.set(device, forKey: "deviceID")
        if !token.isEmpty { loadCache() } else { cache.migrated = true }
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
        isSyncing = true; let origin = server; let credential = token
        defer { isSyncing = false; if !cache.pending.isEmpty && syncError == nil { scheduleSync() } }
        do {
            let api = try LibraryAPI(server: server, token: token, proxy: proxy)
            var sent: [ReaderRecord] = []; var bytes = 32
            for id in cache.pending.sorted() {
                guard let record = cache.records[id] else { continue }
                let size = try JSONEncoder().encode(record).count + 1
                if sent.count >= 100 || bytes + size > 4 * 1024 * 1024 { break }
                sent.append(record); bytes += size
            }
            let remote = try await api.sync(sent)
            guard server == origin && token == credential else { return }
            cache.merge(remote, sent: sent); syncError = nil; persist()
        } catch { if server == origin { syncError = error.localizedDescription } }
    }
    func refresh() async {
        guard !isLoading else { return }; isLoading = true; error = nil
        let origin = server; let credential = token
        defer { isLoading = false }
        do {
            let api = try LibraryAPI(server: server, token: token, proxy: proxy)
            let identity = try await api.me()
            guard origin == server && credential == token else { return }
            user = identity
            let books = try await api.books()
            guard origin == server && credential == token else { return }
            cache.books = books; cache.refreshedAt = Date(); persist(); await refreshProcessing(); await sync()
        } catch { if origin == server && credential == token { self.error = error.localizedDescription } }
    }
    func connect(server: String, token: String, proxy: LibraryProxy) async throws {
        guard !isLoading && !isSyncing else { throw APIError.response(409, "Wait for the current refresh or sync to finish, then connect again.") }
        let proxy = try proxy.validated()
        let api = try LibraryAPI(server: server, token: token, proxy: proxy)
        isLoading = true; defer { isLoading = false }
        let identity = try await api.me()
        let books = try await api.books()
        let normalized = api.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try Keychain.write(token, account: normalized)
        try Keychain.write(proxy.password, account: "libraryProxyPassword")
        let savedProxy = LibraryProxy(kind: proxy.kind, host: proxy.host, port: proxy.port, username: proxy.username)
        UserDefaults.standard.set(try JSONEncoder().encode(savedProxy), forKey: "libraryProxy")
        narration.stop(); narration.key = ""
        syncTask?.cancel(); self.server = normalized; self.token = token; self.proxy = proxy
        UserDefaults.standard.set(normalized, forKey: "server")
        cacheAccountID = identity.id
        UserDefaults.standard.set(identity.id, forKey: "accountID:" + normalized)
        user = identity; jobs = []; processingError = nil
        loadCache(); cache.books = books; cache.refreshedAt = Date(); error = nil; syncError = nil; persist(); await refreshProcessing(); await sync()
    }
    func signOut() async {
        let oldServer = server; let oldToken = token
        narration.stop(); narration.key = ""; syncTask?.cancel()
        try? Keychain.write("", account: server)
        token = ""; user = nil; jobs = []; cache = LibraryCache(); cache.migrated = true
        error = nil; syncError = nil; processingError = nil
        try? await LibraryAPI(server: oldServer, token: oldToken, proxy: proxy).logout()
    }
    func save(_ book: Book) async throws {
        let origin = server; let credential = token
        let saved = try await LibraryAPI(server: server, token: token, proxy: proxy).save(book)
        guard origin == server && credential == token else { return }
        cache.books.removeAll { $0.id == saved.id }; cache.books.insert(saved, at: 0); persist()
    }
    func delete(_ book: Book) async throws {
        let origin = server; let credential = token
        try await LibraryAPI(server: server, token: token, proxy: proxy).delete(book.id)
        guard origin == server && credential == token else { return }
        cache.books.removeAll { $0.id == book.id }; persist()
    }
    func refreshProcessing() async {
        let origin = server; let credential = token
        do {
            let api = try LibraryAPI(server: server, token: token, proxy: proxy)
            let identity = try await api.me()
            guard origin == server && credential == token else { return }
            user = identity
            let incoming = try await api.jobs()
            guard origin == server && credential == token else { return }
            jobs = incoming; processingError = nil
        } catch { if origin == server && credential == token { processingError = error.localizedDescription } }
    }
    @discardableResult func submitZLibrary(book: ZLibraryBook, summaryMinutes: Int) async throws -> ProcessingJob {
        let origin = server; let credential = token
        let job = try await LibraryAPI(server: server, token: token, proxy: proxy).summarizeZLibrary(id: book.id, summaryMinutes: summaryMinutes, title: book.title, author: book.authors.joined(separator: ", "), cover: book.cover ?? "")
        guard origin == server && credential == token else { throw CancellationError() }
        jobs.insert(job, at: 0); return job
    }
    func submitUpload(url: URL, summaryMinutes: Int) async throws {
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 50 * 1024 * 1024 else { throw APIError.response(413, "PDF or EPUB must be at most 50 MiB") }
        let data = try Data(contentsOf: url)
        let origin = server; let credential = token
        let job = try await LibraryAPI(server: server, token: token, proxy: proxy).uploadForProcessing(filename: url.lastPathComponent, data: data, summaryMinutes: summaryMinutes)
        guard origin == server && credential == token else { return }; jobs.insert(job, at: 0)
    }
    func generateNarration(book: Book, provider: String) async throws {
        let origin = server; let credential = token
        let job = try await LibraryAPI(server: server, token: token, proxy: proxy).generateNarration(book.id, provider: provider)
        guard origin == server && credential == token else { return }; jobs.insert(job, at: 0)
    }
    func retryJob(_ job: ProcessingJob) async throws {
        _ = try await LibraryAPI(server: server, token: token, proxy: proxy).retryJob(job.id)
        await refreshProcessing()
    }
    func uploadPDF(book: Book, url: URL) async throws {
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 50 * 1024 * 1024 else { throw APIError.response(413, "Source PDF must be at most 50 MiB") }
        let data = try Data(contentsOf: url)
        let origin = server; let credential = token
        let source = try await LibraryAPI(server: server, token: token, proxy: proxy).uploadPDF(book.id, filename: url.lastPathComponent, data: data)
        guard origin == server && credential == token else { return }
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
    func narrationURL(book: Book, section: Int) async throws -> URL {
        guard book.sections.indices.contains(section), let hash = book.sections[section].narration?.sha256,
              hash.count == 64, hash.allSatisfy({ $0.isHexDigit }),
              book.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw APIError.response(404, "No generated narration attached") }
        let url = URL.applicationSupportDirectory.appending(path: "Margin/Audio/\(serverKey)/\(book.id)-\(section)-\(hash).mp3")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let origin = server; let credential = token
        let data = try await LibraryAPI(server: server, token: token, proxy: proxy).narration(book.id, section: section)
        guard origin == server && credential == token else { throw CancellationError() }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == hash else { throw APIError.response(409, "Narration changed. Refresh your library and try again.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }
    func sourceURL(book: Book) async throws -> URL {
        guard let source = book.source else { throw APIError.response(404, "No source PDF attached") }
        let url = pdfURL(bookID: book.id, hash: source.sha256)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let origin = server; let credential = token
        let data = try await LibraryAPI(server: server, token: token, proxy: proxy).pdf(book.id)
        guard origin == server && credential == token else { throw CancellationError() }
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
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not securely store the credential (\(status))."])
        }
    }
}
