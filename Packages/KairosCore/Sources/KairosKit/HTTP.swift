import Foundation

/// One HTTP request, as a value: what job boards and AI providers send.
public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var url: URL
    public var method: Method
    public var headers: [String: String]
    public var body: Data?
    /// Seconds to wait for the answer to start and to finish.
    public var timeout: TimeInterval

    public init(
        url: URL, method: Method = .get, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 30
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    /// A GET that asks for JSON, and for nothing new since `etag` when one is given.
    public static func json(_ url: URL, etag: String? = nil, timeout: TimeInterval = 30) -> HTTPRequest {
        var headers = ["Accept": "application/json"]
        if let etag { headers["If-None-Match"] = etag }
        return HTTPRequest(url: url, headers: headers, timeout: timeout)
    }
}

/// Whatever came back, any status. Header names are lowercased.
public struct HTTPResponse: Sendable, Equatable {
    public let url: URL
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.url = url
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public var isSuccess: Bool { (200..<300).contains(status) }

    /// `Retry-After` in seconds, when the server sent a number.
    public var retryAfterSeconds: Int? { header("Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
}

/// The request never got an answer. A status code isn't an error at this level: callers decide what
/// a 404 or a 429 means.
public enum HTTPError: Error, Equatable, Sendable {
    case offline
    case timedOut(endpoint: String)
    case cancelled
    case network(String)
}

/// The network. Tests pass a scripted client, so the default test run never reaches the internet.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse
}

/// "api.example.com/v1/jobs": a URL without its scheme or query, which may hold a key. Errors and
/// logs name endpoints this way.
public func endpoint(of url: URL?) -> String {
    guard let url, let host = url.host() else { return "unknown endpoint" }
    let path = url.path()
    return path.isEmpty || path == "/" ? host : host + path
}

/// `HTTPClient` over an ephemeral URLSession: no cookies, no cache on disk.
public final class URLSessionHTTPClient: HTTPClient {
    public static let userAgent = "Kairos/2.0 (+https://github.com/KeneePatel/kairos-mac)"

    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String = URLSessionHTTPClient.userAgent, maxConnectionsPerHost: Int = 6) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        configuration.timeoutIntervalForResource = 300
        session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: HTTPRequest) async throws(HTTPError) -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw Self.map(error, url: request.url)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network("\(endpoint(of: request.url)): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw .network("\(endpoint(of: request.url)): not an HTTP response")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return HTTPResponse(url: http.url ?? request.url, status: http.statusCode, headers: headers, body: data)
    }

    static func map(_ error: URLError, url: URL) -> HTTPError {
        switch error.code {
        case .timedOut: .timedOut(endpoint: endpoint(of: url))
        case .cancelled: .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: .offline
        default: .network("\(endpoint(of: url)): URL error \(error.code.rawValue)")
        }
    }
}

// MARK: - JSON

extension JSONDecoder {
    /// snake_case keys and ISO 8601 dates with or without fractional seconds and offsets, which job
    /// boards mix.
    public static func snakeCase() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISODate.parse(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }
}

/// Lenient ISO 8601: "2026-10-02T11:31:50-04:00", "…Z", "…50.250Z", and a bare "2026-10-02".
public enum ISODate {
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date.ISO8601FormatStyle().parse(trimmed) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) { return date }
        // "2026-10-20 11:28:23 UTC" (Recruitee) and "2026-10-20" (dates without a time).
        let formats = ["yyyy-MM-dd HH:mm:ss 'UTC'", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

/// "jobs[2].title: missing" rather than DecodingError's full dump.
public func describe(_ error: DecodingError) -> String {
    func path(_ context: DecodingError.Context, _ last: (any CodingKey)? = nil) -> String {
        let keys = context.codingPath + (last.map { [$0] } ?? [])
        return keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            .trimmingPrefix(".").description
    }
    func at(_ path: String, _ problem: String) -> String { path.isEmpty ? problem : "\(path): \(problem)" }
    switch error {
    case .keyNotFound(let key, let context): return at(path(context, key), "missing")
    case .valueNotFound(_, let context): return at(path(context), "null")
    case .typeMismatch(_, let context): return at(path(context), "wrong type")
    case .dataCorrupted(let context):
        let underlying = (context.underlyingError as? NSError)?.localizedDescription
        let detail = context.codingPath.isEmpty && underlying != nil ? "not valid JSON" : context.debugDescription
        return at(path(context), detail)
    @unknown default: return "undecodable response"
    }
}
