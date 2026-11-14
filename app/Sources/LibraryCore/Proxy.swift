import Foundation
import Network

public struct LibraryProxy: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case system, http, socks5
    }

    public let kind: Kind
    public let host: String
    public let port: Int
    public let username: String
    public let password: String

    public static let system = LibraryProxy(kind: .system, host: "", port: 0, username: "", password: "")

    public init(kind: Kind, host: String, port: Int, username: String = "", password: String = "") {
        self.kind = kind
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.username = username
        self.password = password
    }

    public func validated() throws -> LibraryProxy {
        guard kind == .system || (!host.isEmpty && !host.contains(where: { $0.isWhitespace || "/@?#".contains($0) })
                                  && (1...65535).contains(port) && (password.isEmpty || !username.isEmpty)) else {
            throw APIError.invalidProxy
        }
        return self
    }

    func configure(_ configuration: URLSessionConfiguration) {
        guard kind != .system else { return }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: UInt16(port))!)
        var proxy = kind == .http ? ProxyConfiguration(httpCONNECTProxy: endpoint) : ProxyConfiguration(socksv5Proxy: endpoint)
        proxy.allowFailover = false
        if !username.isEmpty { proxy.applyCredential(username: username, password: password) }
        configuration.proxyConfigurations = [proxy]
    }
}
