import Foundation
import Store

/// A configured source's id: the `source` row's UUIDv7.
public typealias SourceID = UUID

/// A place jobs come from. Sources only fetch and map; they never write to the store.
public protocol JobSource: Sendable {
    var id: SourceID { get }
    func fetch(_ query: SourceQuery) async throws -> [Posting]
    /// Every job the source has open (a company board), not a search's matches: a job it leaves
    /// out may have closed.
    var listsEverything: Bool { get }
    /// Like `fetch(_:)`, but asks "only if it changed since `memo`" where the source can.
    func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer
}

extension JobSource {
    public var listsEverything: Bool { false }

    public func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        .postings(try await fetch(query), memo: nil)
    }
}

/// What a source said last time, so the next fetch can ask "only if it changed".
public struct FetchMemo: Sendable, Equatable, Codable {
    public var etag: String?

    public init(etag: String?) {
        self.etag = etag
    }
}

/// A source's answer: its postings, or that nothing changed since the memo.
public enum FetchAnswer: Sendable, Equatable {
    case postings([Posting], memo: FetchMemo?)
    case unchanged
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
    /// Your roles: a board that needs a request per job for its text (SmartRecruiters, BambooHR)
    /// asks only for jobs at your roles. Nil asks for all.
    public var roles: RoleMatcher?
    /// Canonical URLs of the jobs this source listed before and Kairos still has open: such a
    /// board doesn't ask for their text again, it says they're still there.
    public var knownURLs: Set<String>

    public init(
        companyName: String? = nil, titles: [String] = [], countries: [Country] = [.canada, .unitedStates],
        maxAgeDays: Int? = nil, roles: RoleMatcher? = nil, knownURLs: Set<String> = []
    ) {
        self.companyName = companyName
        self.titles = titles
        self.countries = countries
        self.maxAgeDays = maxAgeDays
        self.roles = roles
        self.knownURLs = knownURLs
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
    /// The board listed it, but its text wasn't asked for (a job already known, or not at your
    /// roles, on a board that needs a request per job): it counts as seen, and nothing about its
    /// text changes.
    public var textOmitted: Bool

    public init(
        sourceID: SourceID, url: URL, company: String, title: String, location: String, postedAt: Date?,
        descriptionHTML: String, otherLocations: [String] = [], countryHint: String? = nil, workplace: Workplace? = nil,
        textOmitted: Bool = false
    ) {
        self.textOmitted = textOmitted
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
