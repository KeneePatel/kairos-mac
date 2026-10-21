import Foundation
import Store

/// Adzuna's job search API (SPEC §5.4, tier B), with your own free app ID and key. Canada first,
/// then the US (your country order), one search per job title in Settings, Search, newest first.
///
/// Adzuna returns a snippet of each posting, not the whole text. Kairos never follows an advert's
/// link to fetch the rest: Adzuna's advertisers pay for those clicks. Screening treats a snippet
/// as a snippet, and the link is for you to open (polish T40).
public struct AdzunaSource: JobSource {
    public struct Credentials: Sendable, Equatable {
        public var appID: String
        public var appKey: String

        public init(appID: String, appKey: String) {
            self.appID = appID
            self.appKey = appKey
        }
    }

    /// Searches per run. The free plan allows about 25 a minute and 250 a day.
    public static let maxCallsPerRun = 20
    static let resultsPerPage = 50

    public let id: SourceID
    let credentials: Credentials
    let http: any HTTPClient

    public init(id: SourceID, credentials: Credentials, http: any HTTPClient) {
        self.id = id
        self.credentials = credentials
        self.http = http
    }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        let titles = query.titles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !titles.isEmpty else {
            throw SourceError.invalidConfiguration("Adzuna searches by your job titles; add some in Settings, Search")
        }
        let searches = query.countries.flatMap { country in titles.map { (country, $0) } }
            .prefix(Self.maxCallsPerRun)
        var seen: Set<String> = []
        var postings: [Posting] = []
        for (country, title) in searches {
            let page = try await search(title, in: country, maxAgeDays: query.maxAgeDays)
            for result in page.results where seen.insert(result.id).inserted {
                postings.append(posting(result, country: country))
            }
        }
        return postings
    }

    private func search(_ title: String, in country: Country, maxAgeDays: Int?) async throws(SourceError)
        -> AdzunaPage
    {
        let code = country == .canada ? "ca" : "us"
        var items = [
            ("app_id", credentials.appID), ("app_key", credentials.appKey),
            ("results_per_page", String(Self.resultsPerPage)), ("title_only", title), ("sort_by", "date"),
        ]
        if let maxAgeDays { items.append(("max_days_old", String(maxAgeDays))) }
        items.append(("content-type", "application/json"))
        // Unreserved characters and "/", which a query value may hold as is.
        let unreserved = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        let encoded = items.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")"
        }
        guard
            let url = URL(
                string: "https://api.adzuna.com/v1/api/jobs/\(code)/search/1?" + encoded.joined(separator: "&"))
        else { throw .invalidConfiguration("Adzuna search for \(title)") }
        do {
            return try await http.getJSON(url, as: AdzunaPage.self)
        } catch .http(let status, _) where status == 401 || status == 403 {
            throw .invalidConfiguration("Adzuna didn't accept the app ID or key; check them in Fetch, Adzuna")
        }
    }

    private func posting(_ result: AdzunaPage.Result, country: Country) -> Posting {
        let title = Self.plain(result.title)
        let location = result.location?.displayName ?? ""
        let remote = "\(title) \(location)".localizedCaseInsensitiveContains("remote")
        return Posting(
            sourceID: id, url: result.redirectUrl,
            company: result.company?.displayName.map(Self.plain).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Company not listed",
            title: title, location: location, postedAt: result.created,
            descriptionHTML: "<p>\(Self.escaped(Self.plain(result.description ?? "")))</p>",
            countryHint: country.rawValue, workplace: remote ? .remote : nil)
    }

    /// Adzuna's text without its highlighting tags or entities.
    static func plain(_ text: String) -> String {
        HTMLEntities.decode(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct AdzunaPage: Decodable {
    struct Result: Decodable {
        struct Company: Decodable { let displayName: String? }
        struct Location: Decodable { let displayName: String? }
        let id: String
        let title: String
        let description: String?
        let created: Date?
        let redirectUrl: URL
        let company: Company?
        let location: Location?
    }
    let results: [Result]
}
