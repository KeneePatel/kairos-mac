import Foundation
import KairosKit

/// Himalayas, a board of remote jobs, through its public search API. Each of your roles' searches
/// in each of your countries, newest first, 20 jobs a page with full text. A free key lifts the
/// limit; without one, requests share a public allowance. Its terms: name Himalayas as the source,
/// use its application link unchanged, show its jobs only in your own app, drop them once expired.
public struct HimalayasReader: JobReader {
    static let maxPages = 3

    let key: String?
    let http: any HTTPClient
    let clock: any WallClock

    public init(key: String?, http: any HTTPClient, clock: any WallClock = SystemWallClock()) {
        self.key = key.flatMap { $0.isEmpty ? nil : $0 }
        self.http = http
        self.clock = clock
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        let searches = request.roles.searches
        guard !searches.isEmpty else {
            throw .invalidConfiguration("Himalayas searches by your roles; choose some in Settings, Search")
        }
        let budget = request.budget ?? SearchBudget.himalayas.run
        let now = clock.now
        let cutoff = request.maxAgeDays.map { now.addingTimeInterval(-.days(Double($0))) }
        var calls = 0
        var seen: Set<String> = []
        var postings: [Posting] = []
        searching: for country in request.countries {
            for phrase in searches {
                for page in 1...Self.maxPages {
                    guard calls < budget else { break searching }
                    calls += 1
                    let result: HimalayasPage
                    do {
                        result = try await search(phrase, in: country, page: page)
                    } catch {
                        // A later failure keeps what came before: a search's answer is partial anyway.
                        guard calls > 1, error != .cancelled else { throw error }
                        break searching
                    }
                    var fresh = 0
                    for job in result.jobs where seen.insert(job.guid).inserted {
                        // Expired jobs go, as its terms ask; jobs older than your limit aren't wanted.
                        if let expiry = job.expiryDate, Date(timeIntervalSince1970: expiry) < now { continue }
                        let posted = job.pubDate.map { Date(timeIntervalSince1970: $0) }
                        if let cutoff, let posted, posted < cutoff { continue }
                        guard let posting = posting(job, country: country, posted: posted) else { continue }
                        if !request.knownURLs.contains(URLCanonicalizer.canonical(posting.url)) { fresh += 1 }
                        postings.append(posting)
                    }
                    if result.jobs.isEmpty || fresh == 0 { break }
                }
            }
        }
        return ReadResult(postings: postings, requests: calls, complete: false)
    }

    private func search(_ phrase: String, in country: Country, page: Int) async throws(SourceError) -> HimalayasPage {
        var components = URLComponents(string: "https://himalayas.app/jobs/api/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: phrase), URLQueryItem(name: "country", value: country.rawValue),
            URLQueryItem(name: "sort", value: "recent"), URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components?.url else { throw .invalidConfiguration("Himalayas search for \(phrase)") }
        do {
            return try await http.getJSON(
                url, as: HimalayasPage.self, headers: key.map { ["Authorization": "Bearer \($0)"] } ?? [:],
                decoder: JSONDecoder())
        } catch .http(let status, _) where status == 401 || status == 403 {
            throw .invalidConfiguration("Himalayas didn't accept the key; check it in Sources, Himalayas")
        }
    }

    private func posting(_ job: HimalayasPage.Job, country: Country, posted: Date?) -> Posting? {
        // Its own page is the job's address and names Himalayas as the source; Apply opens the
        // application link unchanged, as its terms ask.
        guard let url = URL(string: job.guid) ?? job.applicationLink.flatMap(URL.init(string:)) else { return nil }
        let places = job.locationRestrictions ?? []
        let salary: Salary? =
            job.minSalary == nil && job.maxSalary == nil
            ? nil
            : Salary(
                min: job.minSalary, max: job.maxSalary, currency: job.currency,
                period: job.salaryPeriod.flatMap { Salary.Period(rawValue: $0.lowercased()) })
        return Posting(
            url: url, company: job.companyName, title: job.title,
            location: places.isEmpty ? "Remote, anywhere" : "Remote - " + places.joined(separator: ", "),
            postedAt: posted, descriptionHTML: job.description ?? job.excerpt ?? "",
            countryHint: places.isEmpty ? nil : country.rawValue, workplace: .remote, salary: salary,
            applyURL: job.applicationLink.flatMap(URL.init(string:)), via: "Himalayas")
    }
}

struct HimalayasPage: Decodable {
    struct Job: Decodable {
        let title: String
        let companyName: String
        let guid: String
        let applicationLink: String?
        let description: String?
        let excerpt: String?
        /// Seconds since 1970.
        let pubDate: Double?
        let expiryDate: Double?
        let locationRestrictions: [String]?
        let minSalary: Double?
        let maxSalary: Double?
        let currency: String?
        let salaryPeriod: String?
    }
    let jobs: [Job]
}

/// Google for Jobs, through SerpApi with your key. Google gathers postings from LinkedIn, Indeed,
/// Workday sites and the rest, which Kairos can't read itself. One page (10 jobs) per search: the
/// turns the fetch planned, until the run's share of the free plan is spent. Each job's address is
/// the page Google took it from (`source_link`); behind a job board's copy, Apply goes to the
/// employer's own page when an apply option names it.
public struct GoogleJobsReader: JobReader {
    let key: String
    let http: any HTTPClient
    let clock: any WallClock

    public init(key: String, http: any HTTPClient, clock: any WallClock = SystemWallClock()) {
        self.key = key
        self.http = http
        self.clock = clock
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        var turns = request.turns
        if turns.isEmpty {
            let phrases = request.roles.googlePhrases
            guard !phrases.isEmpty else {
                throw .invalidConfiguration("Google Jobs searches by your roles; choose some in Settings, Search")
            }
            turns = request.countries.flatMap { country in
                phrases.map { SearchTurn(phrase: $0, place: nil, country: country) }
            }
        }
        let budget = request.budget ?? SearchBudget.serpAPI.run
        var calls = 0
        var seen: Set<String> = []
        var postings: [Posting] = []
        for turn in turns {
            guard calls < budget else { break }
            calls += 1
            let page: SerpAPIJobs
            do {
                page = try await search(turn)
            } catch {
                guard calls > 1, error != .cancelled else { throw error }
                break
            }
            for job in page.jobsResults ?? [] where seen.insert(job.jobId).inserted {
                if let posting = posting(job, country: turn.country) { postings.append(posting) }
            }
        }
        return ReadResult(postings: postings, requests: calls, complete: false)
    }

    private func search(_ turn: SearchTurn) async throws(SourceError) -> SerpAPIJobs {
        var components = URLComponents(string: "https://serpapi.com/search.json")
        components?.queryItems = [
            URLQueryItem(name: "engine", value: "google_jobs"),
            URLQueryItem(name: "q", value: turn.remote ? "\(turn.phrase) remote" : turn.phrase),
            URLQueryItem(name: "location", value: turn.place?.googleLocation ?? turn.country.name),
            URLQueryItem(name: "gl", value: turn.country.rawValue.lowercased()), URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "api_key", value: key),
        ]
        guard let url = components?.url else { throw .invalidConfiguration("Google Jobs search") }
        do {
            return try await http.getJSON(url, as: SerpAPIJobs.self)
        } catch .http(let status, _) where status == 401 || status == 403 {
            throw .invalidConfiguration("SerpApi didn't accept the key; check it in Sources, Google Jobs")
        }
    }

    private func posting(_ job: SerpAPIJobs.Job, country: Country) -> Posting? {
        let options = (job.applyOptions ?? []).compactMap { option in
            URL(string: option.link).map { (title: option.title ?? "", link: $0) }
        }
        // The page Google took the posting from is the job's address; a trusted apply option stands
        // in when Google gave none. Google's own search page never does.
        guard
            let page = job.sourceLink.flatMap(URL.init(string:))
                ?? Self.employerOption(options, company: job.companyName, via: job.via)?.link ?? options.first?.link
        else { return nil }
        let highlights = (job.jobHighlights ?? []).map { highlight in
            "<h3>\(HTMLEntities.escape(highlight.title ?? ""))</h3><ul>"
                + highlight.items.map { "<li>\(HTMLEntities.escape($0))</li>" }.joined() + "</ul>"
        }.joined()
        let location = job.location ?? ""
        let remote =
            job.detectedExtensions?.workFromHome == true || location.localizedCaseInsensitiveContains("anywhere")
            || location.localizedCaseInsensitiveContains("remote")
        // "7 days ago" sits in `extensions`; `detected_extensions` is usually empty (2026-10-26).
        let extensions = job.extensions ?? []
        let posted = extensions.compactMap(posted).first ?? job.detectedExtensions?.postedAt.flatMap(posted)
        let pay = extensions.first { $0.contains("$") && ($0.contains("year") || $0.contains("hour")) }
        return Posting(
            url: JobBoards.stripped(page), company: job.companyName, title: job.title,
            location: remote && location.localizedCaseInsensitiveContains("anywhere")
                ? "Remote - \(country.name)" : location,
            postedAt: posted,
            descriptionHTML: "<p>" + HTMLEntities.escape(job.description ?? "").replacing("\n", with: "</p><p>") + "</p>"
                + highlights,
            countryHint: country.rawValue, workplace: remote ? .remote : nil, salary: pay.map { Salary(text: $0) },
            applyURL: Self.applyLink(page: page, options: options, company: job.companyName, via: job.via),
            via: job.via, links: options.map(\.link))
    }

    /// Where to apply: the page itself, unless it's a job board's copy and an option names the
    /// employer's own page. Tracking parameters are dropped either way.
    static func applyLink(page: URL, options: [(title: String, link: URL)], company: String, via: String?) -> URL {
        guard JobBoards.isJobBoard(page), let employer = employerOption(options, company: company, via: via) else {
            return JobBoards.stripped(page)
        }
        return JobBoards.stripped(employer.link)
    }

    /// The first option off a job board whose title names the company or the site the posting came
    /// from: Google lists other postings' links among a job's options now and then.
    static func employerOption(_ options: [(title: String, link: URL)], company: String, via: String?)
        -> (title: String, link: URL)?
    {
        options.first { !JobBoards.isJobBoard($0.link) && JobBoards.names($0.title, company: company, via: via) }
    }

    /// "3 days ago", "5 hours ago", "1 month ago".
    func posted(_ text: String) -> Date? {
        let words = text.lowercased().split(separator: " ")
        guard words.count >= 2, let count = Double(words[0]) else { return nil }
        let unit: Double =
            switch words[1] {
            case let word where word.hasPrefix("minute"): 60
            case let word where word.hasPrefix("hour"): 3_600
            case let word where word.hasPrefix("day"): 86_400
            case let word where word.hasPrefix("week"): 7 * 86_400
            case let word where word.hasPrefix("month"): 30 * 86_400
            default: 0
            }
        return unit == 0 ? nil : clock.now.addingTimeInterval(-count * unit)
    }
}

struct SerpAPIJobs: Decodable {
    struct Job: Decodable {
        struct Highlight: Decodable {
            let title: String?
            let items: [String]
        }
        struct Extensions: Decodable {
            let postedAt: String?
            let workFromHome: Bool?
        }
        struct Option: Decodable {
            let title: String?
            let link: String
        }
        let jobId: String
        let title: String
        let companyName: String
        let location: String?
        /// Where Google took the posting from: "Scotiabank", "LinkedIn", "Indeed".
        let via: String?
        let description: String?
        /// The page the posting was taken from.
        let sourceLink: String?
        /// "7 days ago", "Full-time", "$65K–$75K a year".
        let extensions: [String]?
        let jobHighlights: [Highlight]?
        let detectedExtensions: Extensions?
        let applyOptions: [Option]?
    }
    let jobsResults: [Job]?
}

/// Adzuna's job search, with your free app ID and key. Each of your roles' searches, Canada first,
/// newest first, page after page until a page has nothing new, within the run's share of the plan.
/// Adzuna sends a 500-character snippet of each posting and its advertisers pay per click, so
/// Kairos never follows an advert's link: its results are leads, the companies to look up on their
/// own boards.
public struct AdzunaReader: JobReader {
    public struct Credentials: Sendable, Equatable {
        public var appID: String
        public var appKey: String

        public init(appID: String, appKey: String) {
            self.appID = appID
            self.appKey = appKey
        }
    }

    static let resultsPerPage = 50

    let credentials: Credentials
    let http: any HTTPClient
    let clock: any WallClock

    public init(credentials: Credentials, http: any HTTPClient, clock: any WallClock = SystemWallClock()) {
        self.credentials = credentials
        self.http = http
        self.clock = clock
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        let searches = request.roles.searches
        guard !searches.isEmpty else {
            throw .invalidConfiguration("Adzuna searches by your roles; choose some in Settings, Search")
        }
        let budget = request.budget ?? 20
        let days = days(since: request.since, limit: request.maxAgeDays)
        var calls = 0
        var seen: Set<String> = []
        var postings: [Posting] = []
        searching: for (country, phrase) in request.countries.flatMap({ country in searches.map { (country, $0) } }) {
            var page = 1
            while calls < budget {
                // A failed request may still count against the plan.
                calls += 1
                let answer: AdzunaPage
                do {
                    answer = try await search(phrase, in: country, maxAgeDays: days, page: page)
                } catch {
                    guard calls > 1, error != .cancelled else { throw error }
                    break searching
                }
                var fresh = 0
                for result in answer.results where seen.insert(result.id).inserted {
                    let posting = posting(result, country: country)
                    if !request.knownURLs.contains(URLCanonicalizer.canonical(posting.url)),
                        request.roles.matches(posting.title)
                    {
                        fresh += 1
                    }
                    postings.append(posting)
                }
                // Newest first: a page of known jobs means the rest are known too.
                guard answer.results.count == Self.resultsPerPage, fresh > 0 else { break }
                page += 1
            }
            if calls >= budget { break }
        }
        return ReadResult(postings: postings, requests: calls, complete: false)
    }

    /// `max_days_old`: the days since `since`, rounded up, plus one for overlap, within `limit`.
    func days(since: Date?, limit: Int?) -> Int? {
        guard let since else { return limit }
        let elapsed = Int((clock.now.timeIntervalSince(since) / 86_400).rounded(.up)) + 1
        return limit.map { min($0, max(1, elapsed)) } ?? max(1, elapsed)
    }

    private func search(_ phrase: String, in country: Country, maxAgeDays: Int?, page: Int) async throws(SourceError)
        -> AdzunaPage
    {
        var items = [
            ("app_id", credentials.appID), ("app_key", credentials.appKey),
            ("results_per_page", String(Self.resultsPerPage)), ("title_only", phrase), ("sort_by", "date"),
        ]
        if let maxAgeDays { items.append(("max_days_old", String(maxAgeDays))) }
        items.append(("content-type", "application/json"))
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        let query = items.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }
        let code = country.rawValue.lowercased()
        guard
            let url = URL(
                string: "https://api.adzuna.com/v1/api/jobs/\(code)/search/\(page)?" + query.joined(separator: "&"))
        else { throw .invalidConfiguration("Adzuna search for \(phrase)") }
        do {
            return try await http.getJSON(url, as: AdzunaPage.self)
        } catch .http(let status, _) where status == 401 || status == 403 {
            throw .invalidConfiguration("Adzuna didn't accept the app ID or key; check them in Sources, Adzuna")
        }
    }

    private func posting(_ result: AdzunaPage.Result, country: Country) -> Posting {
        let title = Self.plain(result.title)
        let location = result.location.map(Self.place) ?? ""
        let remote = "\(title) \(location)".localizedCaseInsensitiveContains("remote")
        let company = result.company?.displayName.map(Self.plain).flatMap { $0.isEmpty ? nil : $0 }
        return Posting(
            url: result.redirectUrl, company: company ?? "Company not listed", title: title, location: location,
            postedAt: result.created,
            descriptionHTML: "<p>\(HTMLEntities.escape(Self.plain(result.description ?? "")))</p>",
            countryHint: country.rawValue, workplace: remote ? .remote : nil, isSnippet: true)
    }

    /// City and province from Adzuna's place list (country, province, city, neighbourhood), not its
    /// display name, which can be a neighbourhood ("Regent Park, City of Toronto").
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
