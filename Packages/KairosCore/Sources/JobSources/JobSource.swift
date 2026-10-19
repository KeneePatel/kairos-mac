import Foundation

/// A configured source's id: the `source` row's UUIDv7.
public typealias SourceID = UUID

/// A place jobs come from. Sources only fetch and map; they never write to the store.
public protocol JobSource: Sendable {
    var id: SourceID { get }
    func fetch(_ query: SourceQuery) async throws -> [Posting]
}

/// What a fetch asks for. ATS boards list one company's jobs, so they only need its display name.
public struct SourceQuery: Sendable, Equatable {
    /// The name you gave the company; it wins over the name the board reports.
    public var companyName: String?

    public init(companyName: String? = nil) {
        self.companyName = companyName
    }
}

/// One posting as a source returns it, before normalization turns it into a `Job`.
public struct Posting: Sendable, Equatable {
    public var sourceID: SourceID
    public var url: URL
    public var company: String
    public var title: String
    /// As the board writes it, for example "Toronto, ON" or "Remote - Canada".
    public var location: String
    public var postedAt: Date?
    public var descriptionHTML: String

    public init(
        sourceID: SourceID, url: URL, company: String, title: String, location: String, postedAt: Date?,
        descriptionHTML: String
    ) {
        self.sourceID = sourceID
        self.url = url
        self.company = company
        self.title = title
        self.location = location
        self.postedAt = postedAt
        self.descriptionHTML = descriptionHTML
    }
}

/// Why a fetch failed. Endpoints are host and path only: query strings can carry API keys (Adzuna).
public enum SourceError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case timedOut(endpoint: String)
    case offline
    case network(String)
    /// HTTP 404 or 410, usually a wrong board token or a company that left that ATS.
    case notFound(endpoint: String)
    case rateLimited(retryAfterSeconds: Int?)
    case http(status: Int, endpoint: String)
    /// The response didn't have the shape the source expects.
    case decoding(String)
    case cancelled

    /// `host/path`, without the scheme or query.
    public static func endpoint(of url: URL?) -> String {
        guard let url else { return "?" }
        return (url.host() ?? "?") + url.path()
    }
}
