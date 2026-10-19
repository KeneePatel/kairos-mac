import Foundation

/// The network, as sources see it. Tests swap in a scripted `URLProtocol` so nothing reaches the
/// internet in the default run (SPEC §11).
public protocol HTTPClient: Sendable {
    /// Sends `request` and returns whatever came back, any status. Only transport failures throw.
    func data(for request: URLRequest) async throws(SourceError) -> (Data, HTTPURLResponse)
}

extension HTTPClient {
    /// GETs `url` and decodes a 2xx JSON body. Keys are snake_case on the wire and dates ISO 8601.
    public func getJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws(SourceError) -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await data(for: request)
        try Self.check(response)
        do {
            return try JSONDecoder.sources.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw .decoding(Self.describe(error))
        } catch {
            throw .decoding(error.localizedDescription)
        }
    }

    static func check(_ response: HTTPURLResponse) throws(SourceError) {
        let endpoint = SourceError.endpoint(of: response.url)
        switch response.statusCode {
        case 200..<300:
            return
        case 404, 410:
            throw .notFound(endpoint: endpoint)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
            throw .rateLimited(retryAfterSeconds: retryAfter)
        default:
            throw .http(status: response.statusCode, endpoint: endpoint)
        }
    }

    /// "jobs[2].title: missing" rather than DecodingError's full dump.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context, _ last: CodingKey? = nil) -> String {
            let keys = context.codingPath + (last.map { [$0] } ?? [])
            return keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
                .trimmingPrefix(".").description
        }
        func at(_ path: String, _ problem: String) -> String { path.isEmpty ? problem : "\(path): \(problem)" }
        switch error {
        case .keyNotFound(let key, let context): return at(path(context, key), "missing")
        case .valueNotFound(_, let context): return at(path(context), "null")
        case .typeMismatch(_, let context): return at(path(context), "wrong type")
        case .dataCorrupted(let context): return at(path(context), context.debugDescription)
        @unknown default: return "undecodable response"
        }
    }
}

extension JSONDecoder {
    static var sources: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Accepts offsets ("-04:00", "Z") and fractional seconds, which boards mix.
            guard let date = try? Date.ISO8601FormatStyle().parse(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }
}

/// `HTTPClient` over URLSession: ephemeral (no cookies or cache on disk), JSON only, with timeouts.
public final class URLSessionHTTPClient: HTTPClient {
    public static let defaultUserAgent = "Kairos (+https://github.com/KeneePatel/kairos-mac)"

    private let session: URLSession
    private let userAgent: String

    public init(
        configuration: URLSessionConfiguration = URLSessionHTTPClient.defaultConfiguration(),
        userAgent: String = URLSessionHTTPClient.defaultUserAgent
    ) {
        session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    deinit { session.finishTasksAndInvalidate() }

    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return configuration
    }

    public func data(for request: URLRequest) async throws(SourceError) -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.map(error, url: request.url)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network(error.localizedDescription)
        }
        guard let response = result.1 as? HTTPURLResponse else { throw .network("not an HTTP response") }
        return (result.0, response)
    }

    static func map(_ error: URLError, url: URL?) -> SourceError {
        switch error.code {
        case .timedOut: .timedOut(endpoint: SourceError.endpoint(of: url))
        case .cancelled: .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: .offline
        default: .network("\(SourceError.endpoint(of: url)): URL error \(error.code.rawValue)")
        }
    }
}
