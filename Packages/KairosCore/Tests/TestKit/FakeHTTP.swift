import Foundation
import KairosKit

/// An `HTTPClient` that answers only what a test scripted and fails everything else, so the default
/// test run never reaches the network. Replies are keyed by absolute URL; a handler can answer
/// anything else (an AI provider's POSTs, for instance).
public final class FakeHTTP: HTTPClient, @unchecked Sendable {
    public enum Reply: Sendable {
        case status(Int, body: Data = Data(), headers: [String: String] = [:])
        case failure(HTTPError)
        /// A redirect URLSession followed: a 200 from another address.
        case moved(to: String)

        public static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            .status(status, body: Data(text.utf8), headers: headers)
        }

        public static func fixture(_ name: String, status: Int = 200, headers: [String: String] = [:]) throws -> Reply {
            .status(status, body: try Fixtures.data(name), headers: headers)
        }
    }

    private let lock = NSLock()
    private var replies: [String: Reply]
    private var handler: (@Sendable (HTTPRequest) -> Reply?)?
    private var seen: [HTTPRequest] = []

    public init(_ replies: [String: Reply] = [:], handler: (@Sendable (HTTPRequest) -> Reply?)? = nil) {
        self.replies = replies
        self.handler = handler
    }

    /// Every request made, scripted or not, oldest first.
    public var requests: [HTTPRequest] { lock.withLock { seen } }

    public var requestedURLs: [String] { requests.map(\.url.absoluteString) }

    public func on(_ url: String, _ reply: Reply) {
        lock.withLock { replies[url] = reply }
    }

    public func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        let reply: Reply? = lock.withLock {
            seen.append(request)
            return replies[request.url.absoluteString] ?? handler?(request)
        }
        switch reply {
        case .status(let status, let body, let headers):
            return HTTPResponse(url: request.url, status: status, headers: headers, body: body)
        case .failure(let error):
            throw error
        case .moved(let target):
            return HTTPResponse(url: URL(string: target) ?? request.url, status: 200, body: Data("<html></html>".utf8))
        case nil:
            throw .network("unscripted request: \(request.method.rawValue) \(request.url.absoluteString)")
        }
    }
}

/// Files in `Tests/Fixtures/`.
public enum Fixtures {
    public static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures")

    public static func data(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appending(path: name))
    }

    public static func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    public static func url(_ name: String) -> URL {
        folder.appending(path: name)
    }
}

/// A date from ISO 8601 text, for expectations.
public func isoDate(_ text: String) -> Date {
    ISODate.parse(text) ?? Date(timeIntervalSince1970: 0)
}
