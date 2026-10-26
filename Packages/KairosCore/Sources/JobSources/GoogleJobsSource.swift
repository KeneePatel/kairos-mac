import Foundation
import Store

/// Google for Jobs, through SerpApi with your own key (serpapi.com/google-jobs-api; job collection
/// v2, J7, the owner's choice of 2026-10-23). Google for Jobs gathers postings from LinkedIn,
/// Indeed, Workday career sites and the rest, which Kairos can't read itself. SerpApi queries
/// Google for you; its free plan allows 250 searches a month, 10 jobs each, so Kairos asks your
/// first roles' searches, a few a day. Each result keeps the page Google took it from as its
/// address and, behind a job board's copy, the employer's own page to apply on (v3, C1).
public struct GoogleJobsSource: JobSource {
    /// What Kairos spends of SerpApi's free plan (250 searches a month).
    public static let budget = AdzunaSource.Budget(day: 8, week: 56, month: 240, run: 8)

    public let id: SourceID
    let key: String
    let http: any HTTPClient
    let now: @Sendable () -> Date

    public init(id: SourceID, key: String, http: any HTTPClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id
        self.key = key
        self.http = http
        self.now = now
    }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard case .postings(let postings, _) = try await fetch(query, since: nil) else { return [] }
        return postings
    }

    /// One page (10 jobs) per search: the turns the fetch planned (a role in a place, or remote in
    /// a country), else your roles' searches in each country, until the run's share is spent.
    public func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        var turns = query.turns
        if turns.isEmpty {
            let titles = query.titles.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !titles.isEmpty else {
                throw SourceError.invalidConfiguration(
                    "Google Jobs searches by your roles; choose some in Settings, Search")
            }
            turns = query.countries.flatMap { country in
                titles.map { SearchTurn(phrase: $0, place: nil, country: country) }
            }
        }
        let budget = query.callBudget ?? Self.budget.run
        var calls = 0
        var seen: Set<String> = []
        var postings: [Posting] = []
        for turn in turns {
            guard calls < budget else { break }
            calls += 1
            let page: SerpApiJobs
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
        return .postings(postings, memo: FetchMemo(etag: nil, requests: calls))
    }

    /// Typed like Adzuna's: Swift 6.3's compiler crashed on this `catch` pattern in an untyped
    /// throwing function (CI, 2026-10-24).
    private func search(_ turn: SearchTurn) async throws(SourceError) -> SerpApiJobs {
        var components = URLComponents(string: "https://serpapi.com/search.json")
        components?.queryItems = [
            URLQueryItem(name: "engine", value: "google_jobs"),
            URLQueryItem(name: "q", value: turn.remote ? "\(turn.phrase) remote" : turn.phrase),
            URLQueryItem(name: "location", value: turn.place?.googleLocation ?? turn.country.googleName),
            URLQueryItem(name: "gl", value: turn.country.rawValue.lowercased()), URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "api_key", value: key),
        ]
        guard let url = components?.url else { throw .invalidConfiguration("Google Jobs search") }
        do {
            return try await http.getJSON(url, as: SerpApiJobs.self)
        } catch .http(let status, _) where status == 401 || status == 403 {
            throw SourceError.invalidConfiguration("SerpApi didn't accept the key; check it in Sources, Google Jobs")
        }
    }

    private func posting(_ job: SerpApiJobs.Job, country: Country) -> Posting? {
        let options = (job.applyOptions ?? []).compactMap { option in
            URL(string: option.link).map { (title: option.title ?? "", link: $0) }
        }
        // The page Google took the posting from is the job's address (job collection v3, C1); a
        // trusted apply option stands in when Google gave none. Google's own search page never does.
        guard
            let page = job.sourceLink.flatMap(URL.init(string:))
                ?? Self.employerOption(options, company: job.companyName, via: job.via)?.link ?? options.first?.link
        else { return nil }
        let url = JobBoards.stripped(page)
        let highlights = (job.jobHighlights ?? []).map { highlight in
            "<h3>\(HTMLEntities.escape(highlight.title ?? ""))</h3><ul>"
                + highlight.items.map { "<li>\(HTMLEntities.escape($0))</li>" }.joined() + "</ul>"
        }.joined()
        let location = job.location ?? ""
        let remote =
            job.detectedExtensions?.workFromHome == true || location.localizedCaseInsensitiveContains("anywhere")
            || location.localizedCaseInsensitiveContains("remote")
        // "7 days ago" sits in `extensions`; `detected_extensions` is usually empty (2026-10-26).
        let posted = (job.extensions ?? []).compactMap(posted).first ?? job.detectedExtensions?.postedAt.flatMap(posted)
        return Posting(
            sourceID: id, url: url, company: job.companyName, title: job.title,
            location: remote && location.localizedCaseInsensitiveContains("anywhere")
                ? "Remote - \(country == .canada ? "Canada" : "United States")" : location,
            postedAt: posted,
            descriptionHTML: "<p>"
                + HTMLEntities.escape(job.description ?? "").replacing("\n", with: "</p><p>") + "</p>" + highlights,
            countryHint: country.rawValue, workplace: remote ? .remote : nil,
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

    /// The first option off a job board whose title names the company or the site the posting
    /// came from: Google lists other postings' links among a job's options now and then.
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
        return unit == 0 ? nil : now().addingTimeInterval(-count * unit)
    }
}

struct SerpApiJobs: Decodable {
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
        let shareLink: String?
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
