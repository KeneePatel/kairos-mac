import Foundation
import Store

/// A configured source's id: the `source` row's UUIDv7.
public typealias SourceID = UUID

/// A place jobs come from. Sources only fetch and map; they never write to the store.
public protocol JobSource: Sendable {
    var id: SourceID { get }
    func fetch(_ query: SourceQuery) async throws -> [Posting]
}

/// What a fetch asks for. ATS boards list one company's jobs, so they only need its display name;
/// a search source (Adzuna) asks by your job titles, countries and posting age.
public struct SourceQuery: Sendable, Equatable {
    /// The name you gave the company; it wins over the name the board reports.
    public var companyName: String?
    /// Your job titles from Settings, Search, in your order.
    public var titles: [String]
    /// Your countries, in your order (Canada first by default).
    public var countries: [Country]
    /// Postings older than this many days are left out, when set.
    public var maxAgeDays: Int?

    public init(
        companyName: String? = nil, titles: [String] = [], countries: [Country] = [.canada, .unitedStates],
        maxAgeDays: Int? = nil
    ) {
        self.companyName = companyName
        self.titles = titles
        self.countries = countries
        self.maxAgeDays = maxAgeDays
    }
}

/// Where the board says the work happens, when it says.
public enum Workplace: String, Sendable, CaseIterable {
    case onsite, hybrid, remote
}

/// One posting as a source returns it, before normalization turns it into a `Job`.
public struct Posting: Sendable, Equatable {
    public var sourceID: SourceID
    public var url: URL
    public var company: String
    public var title: String
    /// The main location as the board writes it, for example "Toronto, ON" or "Remote - Canada".
    public var location: String
    public var postedAt: Date?
    public var descriptionHTML: String
    /// Further locations the board lists. A US-first posting can still list Toronto.
    public var otherLocations: [String]
    /// The main location's country as the board reports it: a code ("CA") or a name ("Canada").
    public var countryHint: String?
    public var workplace: Workplace?

    public init(
        sourceID: SourceID, url: URL, company: String, title: String, location: String, postedAt: Date?,
        descriptionHTML: String, otherLocations: [String] = [], countryHint: String? = nil, workplace: Workplace? = nil
    ) {
        self.sourceID = sourceID
        self.url = url
        self.company = company
        self.title = title
        self.location = location
        self.postedAt = postedAt
        self.descriptionHTML = descriptionHTML
        self.otherLocations = otherLocations
        self.countryHint = countryHint
        self.workplace = workplace
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
