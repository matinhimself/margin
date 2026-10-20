import Foundation

public enum APIError: LocalizedError {
    case invalidURL
    case response(Int, String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter an http or https server URL with a host and no path, query, or fragment."
        case let .response(code, message): return "\(message) (\(code))"
        }
    }
}

public struct LibraryAPI: Sendable {
    public let baseURL: URL
    public let token: String
    public init(server: String, token: String) throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil else { throw APIError.invalidURL }
        baseURL = url; self.token = token
    }

    public func books() async throws -> [Book] { try JSONDecoder().decode([Book].self, from: await request("v1/books")) }
    public func save(_ book: Book) async throws -> Book {
        try JSONDecoder().decode(Book.self, from: await request("v1/books/\(book.id)", method: "PUT", body: JSONEncoder().encode(book)))
    }
    public func delete(_ id: String) async throws { _ = try await request("v1/books/\(id)", method: "DELETE") }
    public func sync(_ records: [ReaderRecord]) async throws -> [ReaderRecord] {
        try JSONDecoder().decode(SyncEnvelope.self, from: await request("v1/sync", method: "POST", body: JSONEncoder().encode(SyncEnvelope(records: records)))).records
    }
    public func pdf(_ id: String) async throws -> Data { try await request("v1/books/\(id)/source") }
    public func uploadPDF(_ id: String, filename: String, data: Data) async throws -> BookSource {
        try JSONDecoder().decode(BookSource.self, from: await request("v1/books/\(id)/source", method: "PUT", body: data, contentType: "application/pdf", filename: filename))
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String = "application/json", filename: String? = nil) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        if let filename { var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!; c.queryItems = [URLQueryItem(name: "filename", value: filename)]; url = c.url! }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = path.hasSuffix("/source") ? 120 : 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.response(0, "Invalid server response") }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data)["error"]) ?? "Server request failed"
            throw APIError.response(response.statusCode, message)
        }
        return data
    }
}
