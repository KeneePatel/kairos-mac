import Foundation
import Store

/// What a company-board source stores in `source.config`.
public struct BoardConfig: Codable, Sendable, Equatable {
    public var slug: String
    /// The display name you gave the company, if any.
    public var company: String?
    /// "eu" for a company on Lever's EU instance.
    public var region: String?
    /// How it came: nil when you added it, `catalog` from Kairos's board catalog, `search` found
    /// behind a search's company (job collection v2).
    public var origin: String?

    public init(slug: String, company: String? = nil, region: String? = nil, origin: String? = nil) {
        self.slug = slug
        self.company = company
        self.region = region
        self.origin = origin
    }

    /// The same board whatever the case of its slug; SmartRecruiters ids keep theirs.
    public static func key(kind: SourceKind, slug: String) -> String {
        "\(kind.rawValue)|\(kind == .smartRecruiters ? slug : slug.lowercased())"
    }

    public var json: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) -> BoardConfig? {
        try? JSONDecoder().decode(BoardConfig.self, from: Data(json.utf8))
    }
}

/// What a search source needs besides its row: your search settings and its key.
public struct SearchContext: Sendable, Equatable {
    /// Titles, countries and posting age from Settings, Search.
    public var query: SourceQuery
    /// Your Adzuna app ID and key, when saved.
    public var adzuna: AdzunaSource.Credentials?
    /// Your Himalayas key (optional: it lifts the limit) and SerpApi key (needed for Google Jobs).
    public var himalayasKey: String?
    public var serpAPIKey: String?

    public init(
        query: SourceQuery = SourceQuery(), adzuna: AdzunaSource.Credentials? = nil, himalayasKey: String? = nil,
        serpAPIKey: String? = nil
    ) {
        self.query = query
        self.adzuna = adzuna
        self.himalayasKey = himalayasKey
        self.serpAPIKey = serpAPIKey
    }
}

/// Builds the fetcher for a configured source.
public enum SourceFactory {
    public static func make(_ source: Source, http: any HTTPClient, search: SearchContext = SearchContext())
        throws(SourceError) -> (any JobSource, SourceQuery)
    {
        switch source.kind {
        case .greenhouse, .lever, .ashby, .smartRecruiters, .workable, .recruitee, .personio, .bambooHR, .teamtailor:
            guard let config = BoardConfig.decode(source.config) else {
                throw .invalidConfiguration("\(source.kind.rawValue) source has no board slug")
            }
            // A board needing a request per job asks only for your roles, with your posting age.
            let query = SourceQuery(
                companyName: config.company, countries: search.query.countries, maxAgeDays: search.query.maxAgeDays,
                roles: search.query.roles)
            let slug = config.slug
            let board: any JobSource =
                switch source.kind {
                case .greenhouse: GreenhouseSource(id: source.id, boardToken: slug, http: http)
                case .lever: LeverSource(id: source.id, slug: slug, region: config.region, http: http)
                case .ashby: AshbySource(id: source.id, organization: slug, http: http)
                case .smartRecruiters: SmartRecruitersSource(id: source.id, company: slug, http: http)
                case .workable: WorkableSource(id: source.id, account: slug, http: http)
                case .recruitee: RecruiteeSource(id: source.id, company: slug, http: http)
                case .personio: PersonioSource(id: source.id, company: slug, http: http)
                case .bambooHR: BambooHRSource(id: source.id, company: slug, http: http)
                default: TeamtailorSource(id: source.id, company: slug, http: http)
                }
            return (board, query)
        case .adzuna:
            guard let credentials = search.adzuna else {
                throw .invalidConfiguration("add your Adzuna app ID and key in Fetch, Adzuna")
            }
            // 2.5 s between requests: Adzuna allows 25 a minute.
            return (
                AdzunaSource(id: source.id, credentials: credentials, http: http, pace: .milliseconds(2_500)),
                search.query
            )
        case .himalayas:
            return (HimalayasSource(id: source.id, key: search.himalayasKey, http: http), search.query)
        case .googleJobs:
            guard let key = search.serpAPIKey, !key.isEmpty else {
                throw .invalidConfiguration("add your SerpApi key in Sources, Google Jobs")
            }
            return (GoogleJobsSource(id: source.id, key: key, http: http), search.query)
        case .linkedIn, .indeedCanada, .indeedUS, .glassdoor, .wellfound, .jobBank:
            throw .invalidConfiguration("\(source.kind.rawValue) isn't available yet")
        }
    }
}

extension SourceError {
    /// A short sentence for the Sources screen and run history.
    public var message: String {
        switch self {
        case .invalidConfiguration(let detail): "Check the settings: \(detail)."
        case .timedOut: "The board took too long to answer."
        case .offline: "You're offline."
        case .network(let detail): "Network error (\(detail))."
        case .notFound: "The board wasn't found. The company may have moved to another job site."
        case .rateLimited(let seconds):
            "The board asked us to slow down" + (seconds.map { "; try again in \($0) s." } ?? ".")
        case .http(let status, _): "The board answered with HTTP \(status)."
        case .decoding(let detail): "The board's response changed shape (\(detail))."
        case .cancelled: "Stopped."
        }
    }
}
