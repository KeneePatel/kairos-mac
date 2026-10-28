import Foundation
import KairosKit

/// One posting as a source returns it, before `Normalizer` reads its place and text.
public struct Posting: Sendable, Equatable {
    public var url: URL
    public var company: String
    public var title: String
    /// The main location as written: "Toronto, ON", "Remote - Canada".
    public var location: String
    public var postedAt: Date?
    public var descriptionHTML: String
    /// Further locations the board lists; a US-first posting can still list Toronto.
    public var otherLocations: [String]
    /// The main location's country as the board reports it: a code ("CA") or a name ("Canada").
    public var countryHint: String?
    public var workplace: Workplace?
    public var salary: Salary?
    /// The board listed it but its text wasn't asked for (a job already known, or not at your roles,
    /// on a board that needs a request per job): it counts as seen, and its text is left alone.
    public var textOmitted: Bool
    /// Only part of the posting: Adzuna sends 500 characters. Snippets become leads, never jobs.
    public var isSnippet: Bool
    /// A better page to open than `url`: the employer's own page behind a job board's copy, or
    /// Himalayas's application link.
    public var applyURL: URL?
    /// The site the posting was taken from, when a search says ("Scotiabank", "LinkedIn").
    public var via: String?
    /// Every other link the source gave for it, where boards Kairos reads may hide.
    public var links: [URL]

    public init(
        url: URL, company: String, title: String, location: String, postedAt: Date? = nil, descriptionHTML: String = "",
        otherLocations: [String] = [], countryHint: String? = nil, workplace: Workplace? = nil, salary: Salary? = nil,
        textOmitted: Bool = false, isSnippet: Bool = false, applyURL: URL? = nil, via: String? = nil, links: [URL] = []
    ) {
        self.url = url
        self.company = company
        self.title = title
        self.location = location
        self.postedAt = postedAt
        self.descriptionHTML = descriptionHTML
        self.otherLocations = otherLocations
        self.countryHint = countryHint
        self.workplace = workplace
        self.salary = salary
        self.textOmitted = textOmitted
        self.isSnippet = isSnippet
        self.applyURL = applyURL
        self.via = via
        self.links = links
    }
}

/// What a reader is asked for.
public struct ReadRequest: Sendable {
    /// Your roles. A board that needs a request per job for its text asks only at your roles, and
    /// searches ask for them.
    public var roles: RoleMatcher
    /// Canonical URLs of jobs this source listed before that are still open: a board that needs a
    /// request per job doesn't ask for their text again.
    public var knownURLs: Set<String>
    /// The ETag of the last answer, so an unchanged board answers 304.
    public var etag: String?
    /// Your countries, in your order (Canada first by default).
    public var countries: [Country]
    /// Postings older than this many days aren't wanted.
    public var maxAgeDays: Int?
    /// The last good read of this source: a search asks only for the days since.
    public var since: Date?
    /// Requests this read may make (a search's share of its plan).
    public var budget: Int?
    /// Google Jobs: the searches to make, in order.
    public var turns: [SearchTurn]

    public init(
        roles: RoleMatcher = RoleMatcher(families: []), knownURLs: Set<String> = [], etag: String? = nil,
        countries: [Country] = [.canada, .unitedStates], maxAgeDays: Int? = nil, since: Date? = nil,
        budget: Int? = nil, turns: [SearchTurn] = []
    ) {
        self.roles = roles
        self.knownURLs = knownURLs
        self.etag = etag
        self.countries = countries
        self.maxAgeDays = maxAgeDays
        self.since = since
        self.budget = budget
        self.turns = turns
    }
}

/// What a reader found.
public struct ReadResult: Sendable, Equatable {
    public var postings: [Posting]
    /// For the next read's `If-None-Match`.
    public var etag: String?
    /// The board answered 304: nothing changed since `etag`.
    public var unchanged: Bool
    /// HTTP requests the read took, for search budgets.
    public var requests: Int
    /// The answer lists every open job (a company board), so a job missing from it may have closed.
    /// A search's answer is never complete.
    public var complete: Bool

    public init(postings: [Posting], etag: String? = nil, unchanged: Bool = false, requests: Int = 1, complete: Bool) {
        self.postings = postings
        self.etag = etag
        self.unchanged = unchanged
        self.requests = requests
        self.complete = complete
    }

    public static func notModified(etag: String?) -> ReadResult {
        ReadResult(postings: [], etag: etag, unchanged: true, complete: true)
    }
}

/// Why a read failed. Endpoints are host and path only: query strings can carry API keys.
public enum SourceError: Error, Equatable, Sendable {
    /// Something you can fix in Settings: a bad slug, a missing or rejected key.
    case invalidConfiguration(String)
    /// HTTP 404 or 410, or a redirect to the vendor's home page: usually a company that left that
    /// system or closed its board.
    case notFound(endpoint: String)
    case rateLimited(retryAfterSeconds: Int?)
    case http(status: Int, endpoint: String)
    /// The answer didn't have the shape the reader expects.
    case decoding(String)
    case timedOut(endpoint: String)
    case offline
    case network(String)
    case cancelled

    /// One line for the Sources screen.
    public var message: String {
        switch self {
        case .invalidConfiguration(let detail): detail
        case .notFound: "The board wasn't found. The company may have moved to another system."
        case .rateLimited(let seconds):
            seconds.map { "Too many requests; it asked to wait \($0) seconds." } ?? "Too many requests for now."
        case .http(let status, _): "The board answered with an error (HTTP \(status))."
        case .decoding(let detail): "The board's answer has changed shape (\(detail))."
        case .timedOut: "The board took too long to answer."
        case .offline: "This Mac is offline."
        case .network(let detail): "The request failed: \(detail)"
        case .cancelled: "Stopped."
        }
    }

    init(_ error: HTTPError) {
        switch error {
        case .offline: self = .offline
        case .timedOut(let endpoint): self = .timedOut(endpoint: endpoint)
        case .cancelled: self = .cancelled
        case .network(let detail): self = .network(detail)
        }
    }

    /// The error a non-2xx status means, nil for a success.
    static func check(_ response: HTTPResponse) -> SourceError? {
        let place = endpoint(of: response.url)
        switch response.status {
        case 200..<300: return nil
        case 404, 410: return .notFound(endpoint: place)
        case 429: return .rateLimited(retryAfterSeconds: response.retryAfterSeconds)
        default: return .http(status: response.status, endpoint: place)
        }
    }
}

/// Reads one source: a company's board or a search. Readers only fetch and map; they never store.
public protocol JobReader: Sendable {
    func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult
}

// MARK: - HTTP for readers

extension HTTPClient {
    /// Sends `request`; a transport failure or a non-2xx status (304 excepted) is a `SourceError`.
    func fetch(_ request: HTTPRequest) async throws(SourceError) -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await send(request)
        } catch {
            throw SourceError(error)
        }
        if response.status == 304 { return response }
        if let error = SourceError.check(response) { throw error }
        return response
    }

    /// GETs JSON and decodes it with snake_case keys; nil when the server answered 304 to `etag`.
    func getJSON<T: Decodable>(
        _ url: URL, as type: T.Type, etag: String? = nil, headers: [String: String] = [:],
        decoder: JSONDecoder = .snakeCase()
    ) async throws(SourceError) -> (value: T?, etag: String?) {
        var request = HTTPRequest.json(url, etag: etag)
        for (name, value) in headers { request.headers[name] = value }
        let response = try await fetch(request)
        if response.status == 304 { return (nil, etag) }
        do {
            return (try decoder.decode(T.self, from: response.body), response.header("ETag"))
        } catch let error as DecodingError {
            throw .decoding(describe(error))
        } catch {
            throw .decoding(error.localizedDescription)
        }
    }

    /// GETs JSON that must be there (no ETag).
    func getJSON<T: Decodable>(
        _ url: URL, as type: T.Type, headers: [String: String] = [:], decoder: JSONDecoder = .snakeCase()
    ) async throws(SourceError) -> T {
        guard let value = try await getJSON(url, as: type, etag: nil, headers: headers, decoder: decoder).value else {
            throw .decoding("an empty answer")
        }
        return value
    }
}

/// Runs `transform` over `items` with at most `limit` at once, keeping the input order: a board's
/// per-job requests go a few at a time.
func concurrentMap<T: Sendable, U: Sendable>(
    _ items: [T], limit: Int, _ transform: @escaping @Sendable (T) async -> U
) async -> [U] {
    guard !items.isEmpty else { return [] }
    var results = [U?](repeating: nil, count: items.count)
    await withTaskGroup(of: (Int, U).self) { group in
        var next = 0
        for _ in 0..<min(limit, items.count) {
            let index = next
            group.addTask { (index, await transform(items[index])) }
            next += 1
        }
        while let (index, value) = await group.next() {
            results[index] = value
            if next < items.count {
                let index = next
                group.addTask { (index, await transform(items[index])) }
                next += 1
            }
        }
    }
    return results.compactMap { $0 }
}

/// A number a feed may send as a number, a numeric string or anything else (then nil), so one odd
/// field can't fail a whole board.
struct LenientNumber: Decodable, Sendable {
    let value: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Double(text.filter { $0.isNumber || $0 == "." })
        } else {
            value = nil
        }
    }
}
