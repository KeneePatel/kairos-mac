import Foundation
import Synchronization

@testable import JobSources

/// A `URLProtocol` that answers only the requests a test scripted, and fails every other one, so
/// the default test run can never reach the network. Each session gets its own script, found by
/// a header, so tests can run in parallel.
final class ScriptedURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(status: Int, headers: [String: String] = [:], body: Data = Data())
        case failure(URLError.Code)
    }

    final class Script: Sendable {
        let replies: [String: Reply]
        let seen = Mutex<[URLRequest]>([])
        init(_ replies: [String: Reply]) { self.replies = replies }
        var requests: [URLRequest] { seen.withLock { $0 } }
    }

    private static let header = "X-Kairos-Test-Script"
    private static let scripts = Mutex<[String: Script]>([:])

    /// A client whose requests only this script can answer, keyed by absolute URL.
    static func client(_ replies: [String: Reply], userAgent: String = "Kairos-tests") -> (URLSessionHTTPClient, Script)
    {
        let id = UUID().uuidString
        let script = Script(replies)
        scripts.withLock { $0[id] = script }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedURLProtocol.self]
        configuration.httpAdditionalHeaders = [header: id]
        return (URLSessionHTTPClient(configuration: configuration, userAgent: userAgent), script)
    }

    static func fixture(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appending(path: "Fixtures/\(name)"))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let script = request.value(forHTTPHeaderField: Self.header).flatMap { id in Self.scripts.withLock { $0[id] } }
        script?.seen.withLock { $0.append(request) }
        guard let url = request.url, let reply = script?.replies[url.absoluteString] else {
            // Unscripted: fail rather than let anything through.
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        switch reply {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .http(let status, let headers, let body):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
