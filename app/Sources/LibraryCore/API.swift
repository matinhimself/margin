import Foundation

public enum APIError: LocalizedError {
    case invalidURL
    case invalidProxy
    case response(Int, String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter an http or https server URL with a host and no path, query, or fragment."
        case .invalidProxy: return "Enter a proxy host and port from 1 to 65535, without a URL scheme. A proxy password also needs a username."
        case let .response(code, message): return "\(message) (\(code))"
        }
    }
}

public struct LibraryAPI: Sendable {
    public let baseURL: URL
    public let token: String
    private let session: URLSession
    public init(server: String, token: String, proxy: LibraryProxy = .system) throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { throw APIError.invalidURL }
        baseURL = url; self.token = token
        let proxy = try proxy.validated()
        if proxy.kind == .system { session = .shared }
        else {
            let configuration = URLSessionConfiguration.default
            proxy.configure(configuration)
            session = URLSession(configuration: configuration)
        }
    }

    public func books() async throws -> [Book] { try JSONDecoder().decode([Book].self, from: await request("v1/books")) }
    public func save(_ book: Book) async throws -> Book {
        try JSONDecoder().decode(Book.self, from: await request("v1/books/\(book.id)", method: "PUT", body: JSONEncoder().encode(book)))
    }
    public func delete(_ id: String) async throws { _ = try await request("v1/books/\(id)", method: "DELETE") }
    public func sync(_ records: [ReaderRecord]) async throws -> [ReaderRecord] {
        try JSONDecoder().decode(SyncEnvelope.self, from: await request("v1/sync", method: "POST", body: JSONEncoder().encode(SyncEnvelope(records: records)))).records
    }
    public func narration(_ id: String, section: Int) async throws -> Data { try await request("v1/books/\(id)/narration/\(section)") }
    public func pdf(_ id: String) async throws -> Data { try await request("v1/books/\(id)/source") }
    public func uploadPDF(_ id: String, filename: String, data: Data) async throws -> BookSource {
        try JSONDecoder().decode(BookSource.self, from: await request("v1/books/\(id)/source", method: "PUT", body: data, contentType: "application/pdf", filename: filename))
    }

    public func logout() async throws { _ = try await request("v1/auth/logout", method: "POST") }
    public func me() async throws -> LibraryUser { try JSONDecoder().decode(LibraryUser.self, from: await request("v1/auth/me")) }
    public func searchZLibrary(query: String, page: Int = 1, language: String = "") async throws -> ZLibrarySearchResult {
        try JSONDecoder().decode(ZLibrarySearchResult.self, from: await request("v1/zlibrary/search", queryItems: [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "language", value: language)]))
    }
    public func summarizeZLibrary(id: String, summaryMinutes: Int, title: String = "", author: String = "", cover: String = "") async throws -> ProcessingJob {
        struct Selection: Encodable { let id: String; let summaryMinutes: Int; let title: String; let author: String; let cover: String }
        return try JSONDecoder().decode(ProcessingJob.self, from: await request("v1/zlibrary/summarize", method: "POST", body: JSONEncoder().encode(Selection(id: id, summaryMinutes: summaryMinutes, title: title, author: author, cover: cover))))
    }
    public func jobs() async throws -> [ProcessingJob] { try JSONDecoder().decode([ProcessingJob].self, from: await request("v1/jobs")) }
    public func uploadForProcessing(filename: String, data: Data, summaryMinutes: Int) async throws -> ProcessingJob {
        let contentType = filename.lowercased().hasSuffix(".epub") ? "application/epub+zip" : "application/pdf"
        return try JSONDecoder().decode(ProcessingJob.self, from: await request("v1/uploads", method: "POST", body: data, contentType: contentType, filename: filename, summaryMinutes: summaryMinutes))
    }
    public func retryJob(_ id: String) async throws -> ProcessingJob {
        try JSONDecoder().decode(ProcessingJob.self, from: await request("v1/jobs/\(id)/retry", method: "POST"))
    }
    public func generateNarration(_ id: String, provider: String) async throws -> ProcessingJob {
        try JSONDecoder().decode(ProcessingJob.self, from: await request("v1/admin/books/\(id)/narration", method: "POST", body: JSONEncoder().encode(["provider": provider])))
    }
    public func createInvite() async throws -> LibraryInvite {
        try JSONDecoder().decode(LibraryInvite.self, from: await request("v1/admin/invites", method: "POST", body: Data("{}".utf8)))
    }
    public func login(email: String, password: String, inviteCode: String? = nil) async throws -> LibraryLogin {
        var fields = ["email": email, "password": password]
        if let inviteCode { fields["inviteCode"] = inviteCode }
        return try JSONDecoder().decode(LibraryLogin.self, from: await request(inviteCode == nil ? "v1/auth/login" : "v1/auth/signup", method: "POST", body: JSONEncoder().encode(fields)))
    }
    public func updateProfile(name: String) async throws -> LibraryUser {
        try JSONDecoder().decode(LibraryUser.self, from: await request("v1/auth/profile", method: "PUT", body: JSONEncoder().encode(["displayName": name])))
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", filename: String? = nil, summaryMinutes: Int? = nil, queryItems: [URLQueryItem] = []) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        var query: [URLQueryItem] = queryItems
        if let filename { query.append(URLQueryItem(name: "filename", value: filename)) }
        if let summaryMinutes { query.append(URLQueryItem(name: "summaryMinutes", value: String(summaryMinutes))) }
        if !query.isEmpty { var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!; c.queryItems = query; url = c.url! }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = (path.hasSuffix("/source") || path == "v1/uploads" || path.hasPrefix("v1/zlibrary/") || path.contains("/narration/")) ? 120 : 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.response(0, "Invalid server response") }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data)["error"]) ?? "Server request failed"
            throw APIError.response(response.statusCode, message)
        }
        return data
    }
}
