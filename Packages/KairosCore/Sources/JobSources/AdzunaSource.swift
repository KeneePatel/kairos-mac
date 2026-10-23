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

    /// Requests a run makes when nothing says otherwise (`SourceQuery.callBudget`).
    public static let maxCallsPerRun = 20
    /// Requests sent back to back before `pace` spaces the rest: Adzuna allows 25 a minute.
    static let burst = 20
    static let resultsPerPage = 50

    /// What Kairos spends of the free plan (25 a minute, 250 a day, 1,000 a week, 2,500 a month;
    /// Adzuna's terms): your choice of 2026-10-23, most of it, with the weekly limit respected.
    public struct Budget: Sendable, Equatable {
        public let day: Int
        public let week: Int
        public let month: Int
        /// One fetch's share, so several fetches a day all find jobs.
        public let run: Int

        public static let standard = Budget(day: 200, week: 950, month: 2_400, run: 80)

        /// Requests left now, given what was used today (UTC), in the last 7 days and this month.
        public func remaining(today: Int, week: Int, month: Int) -> Int {
            max(0, min(day - today, self.week - week, self.month - month, run))
        }
    }

    public let id: SourceID
    let credentials: Credentials
    let http: any HTTPClient
    /// The gap between requests: Adzuna allows 25 a minute.
    let pace: Duration
    let now: @Sendable () -> Date

    public init(
        id: SourceID, credentials: Credentials, http: any HTTPClient, pace: Duration = .zero,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.id = id
        self.credentials = credentials
        self.http = http
        self.pace = pace
        self.now = now
    }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard case .postings(let postings, _) = try await fetch(query, since: nil) else { return [] }
        return postings
    }

    /// Each search newest first, page after page, until a page has nothing new at your roles, the
    /// results end, or the run's requests are spent. A request that fails after the first keeps
    /// what came before: a search's answer is partial anyway. Only the days since the last good fetch are
    /// asked for (`SourceQuery.since`), within your "Posted" limit. The memo says how many
    /// requests it took, for the budget.
    public func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        let titles = query.titles.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !titles.isEmpty else {
            throw SourceError.invalidConfiguration("Adzuna searches by your job titles; add some in Settings, Search")
        }
        let budget = query.callBudget ?? Self.maxCallsPerRun
        let days = days(since: query.since, limit: query.maxAgeDays)
        var calls = 0
        var seen: Set<String> = []
        var postings: [Posting] = []
        searches: for (country, title) in query.countries.flatMap({ country in titles.map { (country, $0) } }) {
            var pageNumber = 1
            while calls < budget {
                if calls >= Self.burst, pace > .zero { try await Task.sleep(for: pace) }
                // A failed request may still count against the plan.
                calls += 1
                let page: AdzunaPage
                do {
                    page = try await search(title, in: country, maxAgeDays: days, page: pageNumber)
                } catch {
                    guard calls > 1, error != .cancelled else { throw error }
                    break searches
                }
                var fresh = 0
                for result in page.results where seen.insert(result.id).inserted {
                    let posting = posting(result, country: country)
                    // New to Kairos and at your roles: a job at another role is never stored, so it
                    // would look new on every page.
                    if !query.knownURLs.contains(URLCanonicalizer.canonical(posting.url)),
                        query.roles?.matches(posting.title) ?? true
                    {
                        fresh += 1
                    }
                    postings.append(posting)
                }
                // Newest first: a page of jobs already known means the rest are known too.
                guard page.results.count == Self.resultsPerPage, fresh > 0 else { break }
                pageNumber += 1
            }
            if calls >= budget { break searches }
        }
        return .postings(postings, memo: FetchMemo(etag: nil, requests: calls))
    }

    /// `max_days_old`: the days since `since`, rounded up and one more for overlap, within `limit`.
    func days(since: Date?, limit: Int?) -> Int? {
        guard let since else { return limit }
        let elapsed = Int((now().timeIntervalSince(since) / 86_400).rounded(.up)) + 1
        return limit.map { min($0, max(1, elapsed)) } ?? max(1, elapsed)
    }

    private func search(_ title: String, in country: Country, maxAgeDays: Int?, page: Int) async throws(SourceError)
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
                string: "https://api.adzuna.com/v1/api/jobs/\(code)/search/\(page)?" + encoded.joined(separator: "&"))
        else { throw .invalidConfiguration("Adzuna search for \(title)") }
        do {
            return try await http.getJSON(url, as: AdzunaPage.self)
        } catch .http(let status, _) where status == 401 || status == 403 {
            throw .invalidConfiguration("Adzuna didn't accept the app ID or key; check them in Fetch, Adzuna")
        }
    }

    private func posting(_ result: AdzunaPage.Result, country: Country) -> Posting {
        let title = Self.plain(result.title)
        let location = result.location.map(Self.place) ?? ""
        let remote = "\(title) \(location)".localizedCaseInsensitiveContains("remote")
        return Posting(
            sourceID: id, url: result.redirectUrl,
            company: result.company?.displayName.map(Self.plain).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Company not listed",
            title: title, location: location, postedAt: result.created,
            descriptionHTML: "<p>\(Self.escaped(Self.plain(result.description ?? "")))</p>",
            countryHint: country.rawValue, workplace: remote ? .remote : nil)
    }

    /// City and province from Adzuna's place list (country, province, city, neighbourhood), not its
    /// display name, which can be a neighbourhood or a landmark ("Regent Park, City of Toronto").
    static func place(_ location: AdzunaPage.Result.Location) -> String {
        let area = location.area ?? []
        if area.count >= 3 { return "\(area[2]), \(area[1])" }
        if area.count == 2 { return area[1] }
        return location.displayName ?? ""
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
        struct Location: Decodable {
            let displayName: String?
            let area: [String]?
        }
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
