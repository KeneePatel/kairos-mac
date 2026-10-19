import Foundation

/// The network, as LLM adapters see it. Tests swap in a scripted `URLProtocol`.
public protocol LLMTransport: Sendable {
    /// Sends `request` and returns whatever came back, any status. Only transport failures throw.
    func send(_ request: URLRequest) async throws(LLMError) -> (Data, HTTPURLResponse)
}

/// `LLMTransport` over an ephemeral URLSession: no cookies or cache on disk. Cancelling the calling
/// task cancels the request (SPEC §5.5, Reliability).
public final class URLSessionTransport: LLMTransport {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: URLRequest) async throws(LLMError) -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.map(error, host: request.url?.host() ?? "?")
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let response = result.1 as? HTTPURLResponse else { throw .network("not an HTTP response") }
        return (result.0, response)
    }

    static func map(_ error: URLError, host: String) -> LLMError {
        switch error.code {
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .cannotConnectToHost, .cannotFindHost: .network("can't reach \(host)")
        case .notConnectedToInternet, .networkConnectionLost: .network("offline")
        default: .network("\(host): URL error \(error.code.rawValue)")
        }
    }
}
