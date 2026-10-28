import Foundation
import KairosKit

/// A company's Greenhouse board, through the public board API (no key). It reads the light list
/// (445 KB for Stripe's 713 jobs, against 5.5 MB with every text; 2026-10-28) and asks for a job's
/// text only when it's new and at your roles, or known and edited in the last two days. When that
/// would be many requests, one request for the whole board with its texts is cheaper.
public struct GreenhouseReader: JobReader {
    let board: Board
    let http: any HTTPClient
    let clock: any WallClock

    /// A known job edited this recently has its text read again.
    static let editedWithin: TimeInterval = .days(2)
    /// More texts to ask for than this, and the whole board is read in one request instead.
    static let detailLimit = 25

    public init(board: Board, http: any HTTPClient, clock: any WallClock = SystemWallClock()) {
        self.board = board
        self.http = http
        self.clock = clock
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        guard BoardSlug.isValid(board.slug),
            let list = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(board.slug)/jobs"),
            let full = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(board.slug)/jobs?content=true")
        else { throw .invalidConfiguration("Greenhouse board token: \(board.slug)") }

        let (answer, etag) = try await http.getJSON(list, as: GreenhousePage.self, etag: request.etag)
        guard let page = answer else { return .notModified(etag: etag) }

        let now = clock.now
        let wanted = page.jobs.filter { job in
            let known = request.knownURLs.contains(URLCanonicalizer.canonical(job.absoluteUrl))
            let edited = job.updatedAt.map { now.timeIntervalSince($0) < Self.editedWithin } ?? false
            return known ? edited : request.roles.matches(job.title)
        }
        if wanted.count > Self.detailLimit {
            let whole: GreenhousePage = try await http.getJSON(full, as: GreenhousePage.self)
            return ReadResult(postings: whole.jobs.map(posting), etag: etag, requests: 2, complete: true)
        }

        let slug = board.slug
        let http = http
        let details = await concurrentMap(wanted, limit: 4) { job -> GreenhousePage.Job? in
            guard let id = job.id,
                let url = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(slug)/jobs/\(id)?pay_transparency=true")
            else { return nil }
            return try? await http.getJSON(url, as: GreenhousePage.Job.self)
        }
        let byURL = Dictionary(details.compactMap { $0.map { ($0.absoluteUrl, $0) } }) { first, _ in first }
        let postings = page.jobs.map { job in
            if let detailed = byURL[job.absoluteUrl] { return posting(detailed) }
            var listed = posting(job)
            listed.textOmitted = true
            return listed
        }
        return ReadResult(postings: postings, etag: etag, requests: 1 + wanted.count, complete: true)
    }

    private func posting(_ job: GreenhousePage.Job) -> Posting {
        let pay = job.payInputRanges?.first
        return Posting(
            url: job.absoluteUrl, company: board.name.isEmpty ? (job.companyName ?? board.slug) : board.name,
            title: job.title, location: job.location?.name ?? "",
            // updated_at moves on every edit, which would make old postings look new.
            postedAt: job.firstPublished ?? job.updatedAt,
            // Greenhouse sends its HTML entity-escaped once.
            descriptionHTML: HTMLEntities.decode(job.content ?? ""),
            salary: pay.map {
                Salary(
                    min: $0.minCents.map { Double($0) / 100 }, max: $0.maxCents.map { Double($0) / 100 },
                    currency: $0.currencyType, period: .year)
            })
    }
}

struct GreenhousePage: Decodable {
    struct Job: Decodable {
        struct Location: Decodable { let name: String }
        struct Pay: Decodable {
            let minCents: Int?
            let maxCents: Int?
            let currencyType: String?
        }
        let id: Int?
        let title: String
        let updatedAt: Date?
        let firstPublished: Date?
        let absoluteUrl: URL
        let location: Location?
        let companyName: String?
        let content: String?
        let payInputRanges: [Pay]?
    }
    let jobs: [Job]
}

/// A company's Lever site, through the public postings API (no key). Companies hosted in the EU
/// are on Lever's EU instance, which has its own API host.
public struct LeverReader: JobReader {
    let board: Board
    let http: any HTTPClient

    public init(board: Board, http: any HTTPClient) {
        self.board = board
        self.http = http
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        let host = board.region == "eu" ? "api.eu.lever.co" : "api.lever.co"
        guard BoardSlug.isValid(board.slug), let url = URL(string: "https://\(host)/v0/postings/\(board.slug)?mode=json")
        else { throw .invalidConfiguration("Lever company slug: \(board.slug)") }
        let (answer, etag) = try await http.getJSON(url, as: [LeverPosting].self, etag: request.etag)
        guard let postings = answer else { return .notModified(etag: etag) }
        return ReadResult(postings: postings.map(posting), etag: etag, complete: true)
    }

    private func posting(_ job: LeverPosting) -> Posting {
        let location = job.categories.location ?? ""
        return Posting(
            url: job.hostedUrl, company: board.name.isEmpty ? board.slug : board.name, title: job.text,
            location: location, postedAt: job.createdAt.map { Date(milliseconds: $0) },
            descriptionHTML: job.fullDescriptionHTML,
            otherLocations: (job.categories.allLocations ?? []).filter { $0 != location }, countryHint: job.country,
            workplace: job.workplace,
            salary: job.salaryRange.map {
                Salary(min: $0.min, max: $0.max, currency: $0.currency, period: Salary.Period(lever: $0.interval))
            })
    }
}

struct LeverPosting: Decodable {
    struct Categories: Decodable {
        let location: String?
        let allLocations: [String]?
    }
    /// A titled section, usually requirements or responsibilities; `content` is `<li>` items.
    struct Section: Decodable {
        let text: String
        let content: String
    }
    struct SalaryRange: Decodable {
        let min: Double?
        let max: Double?
        let currency: String?
        let interval: String?
    }
    let text: String
    let hostedUrl: URL
    /// Milliseconds since 1970, unlike the ISO dates other boards send.
    let createdAt: Int64?
    let categories: Categories
    let country: String?
    /// "on-site" (Lever's docs), "onsite", "hybrid", "remote" or "unspecified".
    let workplaceType: String?
    let description: String?
    let lists: [Section]?
    let additional: String?
    let salaryRange: SalaryRange?

    var workplace: Workplace? {
        switch workplaceType?.lowercased() {
        case "on-site", "onsite": .onsite
        case "hybrid": .hybrid
        case "remote": .remote
        default: nil
        }
    }

    /// Lever splits a posting into an intro, titled lists and a closing note. The lists hold the
    /// requirements, so all three are joined in page order.
    var fullDescriptionHTML: String {
        var html = description ?? ""
        for section in lists ?? [] {
            html += "<h3>\(HTMLEntities.escape(section.text))</h3><ul>\(section.content)</ul>"
        }
        return html + (additional ?? "")
    }
}

extension Salary.Period {
    init?(lever interval: String?) {
        switch interval?.lowercased() {
        case "per-year-salary": self = .year
        case "per-month-salary": self = .month
        case "per-week-salary": self = .week
        case "per-day-wage": self = .day
        case "per-hour-wage": self = .hour
        default: return nil
        }
    }
}

/// A company's Ashby board, through the public posting API (no key).
public struct AshbyReader: JobReader {
    let board: Board
    let http: any HTTPClient

    public init(board: Board, http: any HTTPClient) {
        self.board = board
        self.http = http
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        guard BoardSlug.isValid(board.slug),
            let url = URL(string: "https://api.ashbyhq.com/posting-api/job-board/\(board.slug)?includeCompensation=true")
        else { throw .invalidConfiguration("Ashby organization: \(board.slug)") }
        let (answer, etag) = try await http.getJSON(url, as: AshbyBoard.self, etag: request.etag)
        guard let page = answer else { return .notModified(etag: etag) }
        // Unlisted jobs are reachable by link only; the company doesn't advertise them.
        let postings = page.jobs.filter { $0.isListed ?? true }.map { job in
            Posting(
                url: job.jobUrl, company: board.name.isEmpty ? board.slug : board.name, title: job.title,
                location: job.location ?? "", postedAt: job.publishedAt, descriptionHTML: job.descriptionHtml ?? "",
                otherLocations: (job.secondaryLocations ?? []).compactMap(\.location),
                countryHint: job.address?.postalAddress?.addressCountry, workplace: job.workplace,
                salary: job.compensation?.compensationTierSummary.map { Salary(text: $0) })
        }
        return ReadResult(postings: postings, etag: etag, complete: true)
    }
}

struct AshbyBoard: Decodable {
    struct Address: Decodable {
        struct PostalAddress: Decodable { let addressCountry: String? }
        let postalAddress: PostalAddress?
    }
    struct SecondaryLocation: Decodable { let location: String? }
    struct Compensation: Decodable { let compensationTierSummary: String? }
    struct Job: Decodable {
        let title: String
        let jobUrl: URL
        let location: String?
        let secondaryLocations: [SecondaryLocation]?
        let address: Address?
        let publishedAt: Date?
        let isListed: Bool?
        let isRemote: Bool?
        /// "OnSite", "Hybrid" or "Remote".
        let workplaceType: String?
        let descriptionHtml: String?
        let compensation: Compensation?

        var workplace: Workplace? {
            switch workplaceType?.lowercased() {
            case "onsite": .onsite
            case "hybrid": .hybrid
            case "remote": .remote
            default: isRemote == true ? .remote : nil
            }
        }
    }
    let jobs: [Job]
}

/// A company's Workable board, through the public widget feed its careers page uses (no key).
/// Every open job with its text in one answer. Workable doesn't document this feed, so its shape is
/// pinned by a recorded answer.
public struct WorkableReader: JobReader {
    let board: Board
    let http: any HTTPClient

    public init(board: Board, http: any HTTPClient) {
        self.board = board
        self.http = http
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        guard BoardSlug.isValid(board.slug),
            let url = URL(string: "https://apply.workable.com/api/v1/widget/accounts/\(board.slug)?details=true")
        else { throw .invalidConfiguration("Workable account: \(board.slug)") }
        let page: WorkableBoard = try await http.getJSON(url, as: WorkableBoard.self)
        let postings = page.jobs.compactMap { job -> Posting? in
            guard let link = URL(string: job.url) else { return nil }
            let places = (job.locations ?? []).filter { $0.hidden != true }
            let main = places.first
            return Posting(
                url: link, company: board.name.isEmpty ? (page.name ?? board.slug) : board.name, title: job.title,
                location: main.map(Self.place)
                    ?? [job.city, job.state, job.country].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: ", "),
                postedAt: (job.publishedOn ?? job.createdAt).flatMap(ISODate.parse),
                descriptionHTML: job.description ?? "", otherLocations: places.dropFirst().map(Self.place),
                countryHint: main?.countryCode ?? job.country, workplace: job.telecommuting == true ? .remote : nil)
        }
        return ReadResult(postings: postings, complete: true)
    }

    static func place(_ location: WorkableBoard.Job.Location) -> String {
        [location.city, location.region, location.country].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct WorkableBoard: Decodable {
    struct Job: Decodable {
        struct Location: Decodable {
            let country: String?
            let countryCode: String?
            let city: String?
            let region: String?
            let hidden: Bool?
        }
        let title: String
        let url: String
        let publishedOn: String?
        let createdAt: String?
        let country: String?
        let city: String?
        let state: String?
        let telecommuting: Bool?
        let locations: [Location]?
        let description: String?
    }
    let name: String?
    let jobs: [Job]
}

/// A company's Recruitee careers site, through its public Careers Site API (no key). Every
/// published job with its text and requirements in one answer.
public struct RecruiteeReader: JobReader {
    let board: Board
    let http: any HTTPClient

    public init(board: Board, http: any HTTPClient) {
        self.board = board
        self.http = http
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        guard BoardSlug.isValid(board.slug), let url = URL(string: "https://\(board.slug).recruitee.com/api/offers/")
        else { throw .invalidConfiguration("Recruitee company: \(board.slug)") }
        let page: RecruiteeBoard = try await http.getJSON(url, as: RecruiteeBoard.self)
        let postings = page.offers.compactMap { offer -> Posting? in
            guard let link = URL(string: offer.careersUrl) else { return nil }
            let others = (offer.locations ?? []).dropFirst().map { location in
                [location.city, location.state, location.country].compactMap { $0 }.joined(separator: ", ")
            }
            let requirements = offer.requirements.map { $0.isEmpty ? "" : "<h3>Requirements</h3>" + $0 } ?? ""
            return Posting(
                url: link, company: board.name.isEmpty ? (offer.companyName ?? board.slug) : board.name,
                title: offer.title,
                location: offer.location ?? [offer.city, offer.country].compactMap { $0 }.joined(separator: ", "),
                postedAt: (offer.publishedAt ?? offer.createdAt).flatMap(ISODate.parse),
                descriptionHTML: (offer.description ?? "") + requirements, otherLocations: Array(others),
                countryHint: offer.countryCode ?? offer.country,
                workplace: offer.remote == true
                    ? .remote : offer.hybrid == true ? .hybrid : offer.onSite == true ? .onsite : nil,
                salary: offer.salary.flatMap { pay in
                    pay.min?.value == nil && pay.max?.value == nil
                        ? nil : Salary(min: pay.min?.value, max: pay.max?.value, currency: pay.currency)
                })
        }
        return ReadResult(postings: postings, complete: true)
    }
}

struct RecruiteeBoard: Decodable {
    struct Offer: Decodable {
        struct Location: Decodable {
            let city: String?
            let state: String?
            let country: String?
        }
        struct Pay: Decodable {
            let min: LenientNumber?
            let max: LenientNumber?
            let currency: String?
        }
        let title: String
        let careersUrl: String
        let companyName: String?
        let location: String?
        let city: String?
        let country: String?
        let countryCode: String?
        let locations: [Location]?
        let remote: Bool?
        let hybrid: Bool?
        let onSite: Bool?
        let publishedAt: String?
        let createdAt: String?
        let description: String?
        let requirements: String?
        let salary: Pay?
    }
    let offers: [Offer]
}
