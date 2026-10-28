import Foundation
import KairosKit

/// What a pasted careers URL points at.
public enum ATSDetection: Equatable, Sendable {
    case board(kind: SourceKind, slug: String, region: String?)
    /// Why not, in words the Sources screen can show.
    case notABoard(String)
}

/// Turns a careers URL into a board: board pages, single postings, embeds and API URLs, with or
/// without a scheme.
public enum ATSDetector {
    public static func detect(_ text: String) -> ATSDetection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme), let host = components.host?.lowercased(),
            ["http", "https"].contains(components.scheme?.lowercased() ?? "")
        else {
            return .notABoard("That doesn't look like a web address.")
        }
        // Encoded, so "%2F" inside a segment can't split it into more segments.
        let path = components.percentEncodedPath.split(separator: "/").map(String.init)
        let forParameter = components.queryItems?.first { $0.name == "for" }?.value

        let found: (SourceKind, String?)? =
            switch host {
            // boards.greenhouse.io/acme, /acme/jobs/123, /embed/job_board?for=acme
            case "boards.greenhouse.io", "job-boards.greenhouse.io":
                (.greenhouse, path.first == "embed" ? forParameter : path.first)
            case "boards-api.greenhouse.io":
                (.greenhouse, path.count >= 3 && path[0] == "v1" && path[1] == "boards" ? path[2] : nil)
            // jobs.lever.co/acme, /acme/<posting>; jobs.eu.lever.co for Lever's EU instance
            case "jobs.lever.co", "jobs.eu.lever.co":
                (.lever, path.first)
            case "api.lever.co", "api.eu.lever.co":
                (.lever, path.count >= 3 && path[0] == "v0" && path[1] == "postings" ? path[2] : nil)
            case "jobs.ashbyhq.com":
                (.ashby, path.first)
            case "api.ashbyhq.com":
                (.ashby, path.count >= 3 && path[0] == "posting-api" && path[1] == "job-board" ? path[2] : nil)
            // jobs.smartrecruiters.com/Acme, /Acme/<id> (case matters)
            case "jobs.smartrecruiters.com", "careers.smartrecruiters.com":
                (.smartRecruiters, path.first)
            case "api.smartrecruiters.com":
                (.smartRecruiters, path.count >= 3 && path[0] == "v1" && path[1] == "companies" ? path[2] : nil)
            // apply.workable.com/acme, /acme/j/<code>; the widget feed's /api/v1/widget/accounts/acme
            case "apply.workable.com":
                (
                    .workable,
                    path.first == "api"
                        ? (path.count >= 5 && path[3] == "accounts" ? path[4] : nil)
                        : path.first == "j" ? nil : path.first
                )
            default:
                subdomainBoard(host)
            }

        guard let (kind, slug) = found else {
            if components.queryItems?.contains(where: { $0.name == "gh_jid" || $0.name == "ashby_jid" }) == true {
                return .notABoard("This page embeds its job board. Open the board itself and paste that address.")
            }
            if host.hasSuffix("myworkdayjobs.com") || host.hasSuffix("myworkdaysite.com") {
                return .notABoard(
                    "This company's jobs are on Workday, whose terms don't allow automated access, so Kairos can't watch them. Google Jobs often finds them."
                )
            }
            return .notABoard(
                "Not a job board Kairos reads. It reads Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR and Teamtailor."
            )
        }
        guard let slug, BoardSlug.isValid(slug) else {
            return .notABoard("That's a \(kind.displayName) address, but it doesn't say which company.")
        }
        return .board(kind: kind, slug: slug, region: trimmed.lowercased().contains("eu.lever.co") ? "eu" : nil)
    }

    /// Boards on a subdomain of their system: acme.recruitee.com, acme.jobs.personio.de,
    /// acme.bamboohr.com, acme.teamtailor.com and Workable's older acme.workable.com.
    static func subdomainBoard(_ host: String) -> (SourceKind, String?)? {
        let suffixes: [(String, SourceKind)] = [
            (".recruitee.com", .recruitee), (".jobs.personio.de", .personio), (".jobs.personio.com", .personio),
            (".bamboohr.com", .bambooHR), (".teamtailor.com", .teamtailor), (".workable.com", .workable),
        ]
        for (suffix, kind) in suffixes where host.hasSuffix(suffix) {
            let name = String(host.dropLast(suffix.count))
            // The vendor's own site, not a company's board.
            let isCompany = !name.isEmpty && !name.contains(".") && !["www", "api", "app", "apply"].contains(name)
            return (kind, isCompany ? name : nil)
        }
        return nil
    }

    /// The boards a search's postings link to: each a company whose every posting Kairos can then
    /// read in full. Job boards and staffing agencies never count.
    public static func boards(behind postings: [Posting]) -> [Board] {
        var found: [Board] = []
        var keys: Set<String> = []
        for posting in postings where !BoardCatalog.isAggregator(posting.company) {
            for link in [posting.url] + (posting.applyURL.map { [$0] } ?? []) + posting.links {
                guard case .board(let kind, let slug, let region) = detect(link.absoluteString) else { continue }
                let board = Board(kind: kind, slug: slug, name: posting.company, region: region)
                if keys.insert(board.key).inserted { found.append(board) }
            }
        }
        return found
    }
}

/// Companies' public job boards with jobs in Canada or the US, found by `scripts/discover-boards.py`
/// from Common Crawl's URL index, each checked against its system, and bundled with the app. The
/// app never crawls; a release refreshes the catalog.
public struct BoardCatalog: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Codable {
        /// A `SourceKind` raw value.
        public let kind: String
        public let slug: String
        public let name: String
        /// Jobs it listed in Canada and in the US when checked.
        public let ca: Int
        public let us: Int
        public let jobs: Int
        public let region: String?

        public init(kind: String, slug: String, name: String, ca: Int, us: Int, jobs: Int, region: String? = nil) {
            self.kind = kind
            self.slug = slug
            self.name = name
            self.ca = ca
            self.us = us
            self.jobs = jobs
            self.region = region
        }

        public var board: Board? {
            SourceKind(rawValue: kind).flatMap {
                $0.isBoard ? Board(kind: $0, slug: slug, name: name, region: region) : nil
            }
        }

        public func lists(in countries: [Country]) -> Bool {
            (countries.contains(.canada) && ca > 0) || (countries.contains(.unitedStates) && us > 0)
        }
    }

    /// The day the boards were checked.
    public let checked: String
    public let entries: [Entry]

    public init(checked: String, entries: [Entry]) {
        self.checked = checked
        self.entries = entries
    }

    /// The catalog that ships with Kairos.
    public static let bundled: BoardCatalog = {
        struct File: Decodable {
            let checked: String
            let boards: [Entry]
        }
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json", subdirectory: "Resources"),
            let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
        else { return BoardCatalog(checked: "", entries: []) }
        return BoardCatalog(checked: file.checked, entries: file.boards)
    }()

    /// The boards with jobs in any of `countries`, job sites and agencies left out.
    public func boards(in countries: [Country]) -> [Board] {
        entries.filter { $0.lists(in: countries) && !Self.isAggregator($0.name, slug: $0.slug) }.compactMap(\.board)
    }

    /// The catalog's board for a company name, if it has one.
    public func board(forCompany name: String) -> Board? {
        let key = DedupKey.company(name)
        guard !key.isEmpty else { return nil }
        return entries.first { DedupKey.company($0.name) == key }?.board
    }

    /// Job sites and agencies that repost other companies' jobs (2026-10-23: one board added 207
    /// reposted jobs): kept out of the catalog and never looked up behind a search's company.
    public static func isAggregator(_ name: String, slug: String = "") -> Bool {
        let keys = [name, slug].map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        return keys.contains { aggregators.contains($0) }
            || [name, slug].contains {
                $0.range(of: "agency|staffing|recruit", options: [.regularExpression, .caseInsensitive]) != nil
            }
    }

    static let aggregators: Set<String> = [
        "jobgether", "jooble", "talent", "lensa", "dice", "ziprecruiter", "indeed", "linkedin", "glassdoor", "monster",
        "careerbuilder", "remoterocketship", "jobot", "turing", "crossover", "toptal", "hired", "recruitnet",
        "jobsforhumanity", "clickjobs", "adzuna", "workopolis", "eluta", "bjakcareer",
    ]
}

/// Job boards and aggregators: sites that carry other employers' postings. A posting found on one
/// is real, but the employer's own page is the better link, and a job board is never a company.
public enum JobBoards {
    /// Hosts, matched as themselves or as a parent domain ("ca.indeed.com" is "indeed.com").
    static let hosts: [String] = [
        "indeed.com", "linkedin.com", "glassdoor.com", "glassdoor.ca", "ziprecruiter.com", "jooble.org", "talent.com",
        "simplyhired.com", "simplyhired.ca", "workopolis.com", "eluta.ca", "jobrapido.com", "bebee.com", "trabajo.org",
        "jobleads.com", "theladders.com", "startup.jobs", "csjobs.ca", "careerbeacon.com", "jobgether.com",
        "remote.com", "remoterocketship.com", "matcha.fm", "flexjobs.com", "lensa.com", "jobot.com", "monster.com",
        "monster.ca", "careerbuilder.com", "dice.com", "neuvoo.com", "jobillico.com", "adzuna.com", "adzuna.ca",
        "google.com", "jobmesh.io", "careers-page.com", "expertini.com", "jobs.ca", "hirify.me", "up2staff.com",
        "unjobs.ru", "remotesource.com", "hireft.com", "onetapapply.com", "remotejobify.app", "katchup.world",
        "remotepilot.dev", "entracareers.com", "recroid.com", "parsejobs.com", "workreap.com", "allibo.com",
        "wellfound.com", "himalayas.app", "remotive.com", "jobbank.gc.ca", "kijiji.ca", "jobspresso.co",
        "weworkremotely.com", "remoteok.com", "builtin.com", "builtincanada.com", "ycombinator.com", "otta.com",
    ]

    public static func isJobBoard(_ url: URL) -> Bool { url.host().map(isJobBoard) ?? false }

    public static func isJobBoard(_ host: String) -> Bool {
        let host = host.lowercased()
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The link without the `utm_*` and `ref` parameters a search adds.
    public static func stripped(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else { return url }
        let kept = items.filter { !$0.name.lowercased().hasPrefix("utm_") && $0.name.lowercased() != "ref" }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// Words that don't tell companies apart.
    private static let filler: Set<String> = [
        "the", "inc", "ltd", "llc", "corp", "co", "company", "careers", "jobs", "canada", "group", "technologies",
        "technology", "solutions", "services", "limited", "corporation", "and", "of", "at",
    ]

    /// Whether an apply option's title names the company ("Softline" for "Softline Technology",
    /// "Intuit Careers" for "Intuit") or the site the posting came from.
    public static func names(_ title: String, company: String, via: String?) -> Bool {
        if let via, !via.isEmpty, fold(via) == fold(title) { return true }
        let titleWords = Set(words(title))
        let companyWords = Set(words(company))
        return !titleWords.isEmpty && !companyWords.isEmpty && !titleWords.isDisjoint(with: companyWords)
    }

    private static func fold(_ text: String) -> String {
        text.folded.filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
    }

    private static func words(_ text: String) -> [String] {
        fold(text).split(separator: " ").map(String.init).filter { !filler.contains($0) }
    }
}

/// Looks for a company's public board by its name: a search's company may have its jobs, in full,
/// on a board Kairos reads. It tries the name's likely slugs on the boards whose lists are cheap,
/// and a board counts only when it lists at least one job.
public struct BoardProbe: Sendable {
    let http: any HTTPClient

    public init(http: any HTTPClient) {
        self.http = http
    }

    /// The likely slugs for a name: "Traction Rec Inc." → "tractionrec", "traction-rec".
    public static func slugs(for name: String) -> [String] {
        let suffixes: Set<String> = [
            "inc", "incorporated", "ltd", "limited", "llc", "corp", "corporation", "co", "company", "technologies",
            "technology", "solutions", "group", "canada", "the",
        ]
        let words = name.folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let core = words.filter { !suffixes.contains($0) }
        let kept = core.isEmpty ? words : core
        return [kept.joined(), kept.joined(separator: "-")].filter { !$0.isEmpty && BoardSlug.isValid($0) }.uniqued()
    }

    /// The first board that lists jobs under one of the name's slugs.
    public func find(_ name: String) async -> Board? {
        for slug in Self.slugs(for: name) {
            for kind in [SourceKind.greenhouse, .lever, .ashby, .workable, .recruitee, .smartRecruiters] {
                let tries = kind == .smartRecruiters ? [slug, slug.prefix(1).uppercased() + slug.dropFirst()] : [slug]
                for attempt in tries where await lists(kind, attempt) {
                    return Board(kind: kind, slug: attempt, name: name)
                }
            }
        }
        return nil
    }

    /// Whether that board answers with at least one job.
    func lists(_ kind: SourceKind, _ slug: String) async -> Bool {
        let address: String
        switch kind {
        case .greenhouse: address = "https://boards-api.greenhouse.io/v1/boards/\(slug)/jobs"
        case .lever: address = "https://api.lever.co/v0/postings/\(slug)?mode=json&limit=1"
        case .ashby: address = "https://api.ashbyhq.com/posting-api/job-board/\(slug)"
        case .workable: address = "https://apply.workable.com/api/v1/widget/accounts/\(slug)"
        case .recruitee: address = "https://\(slug).recruitee.com/api/offers/"
        case .smartRecruiters: address = "https://api.smartrecruiters.com/v1/companies/\(slug)/postings?limit=1"
        default: return false
        }
        guard let url = URL(string: address), let response = try? await http.send(.json(url)), response.status == 200,
            response.url.host() == url.host(), let value = try? JSONValue(parsing: response.body)
        else { return false }
        if let list = value.arrayValue { return !list.isEmpty }
        if let total = value["totalFound"]?.numberValue { return total > 0 }
        for key in ["jobs", "offers"] {
            if let list = value[key]?.arrayValue { return !list.isEmpty }
        }
        return false
    }
}

/// The reader for a source.
public enum Readers {
    /// The keys the searches need, read by the caller from its secret store.
    public struct Keys: Sendable, Equatable {
        public var adzuna: AdzunaReader.Credentials?
        public var himalayas: String?
        public var serpAPI: String?

        public init(adzuna: AdzunaReader.Credentials? = nil, himalayas: String? = nil, serpAPI: String? = nil) {
            self.adzuna = adzuna
            self.himalayas = himalayas
            self.serpAPI = serpAPI
        }
    }

    public static func board(_ board: Board, http: any HTTPClient, clock: any WallClock = SystemWallClock())
        -> any JobReader
    {
        switch board.kind {
        case .greenhouse: GreenhouseReader(board: board, http: http, clock: clock)
        case .lever: LeverReader(board: board, http: http)
        case .ashby: AshbyReader(board: board, http: http)
        case .smartRecruiters: SmartRecruitersReader(board: board, http: http)
        case .workable: WorkableReader(board: board, http: http)
        case .recruitee: RecruiteeReader(board: board, http: http)
        case .personio: PersonioReader(board: board, http: http)
        case .bambooHR: BambooHRReader(board: board, http: http)
        case .teamtailor: TeamtailorReader(board: board, http: http)
        case .himalayas, .googleJobs, .adzuna: Unreadable(kind: board.kind)
        }
    }

    /// The reader for a search, or why it can't run.
    public static func search(
        _ kind: SourceKind, keys: Keys, http: any HTTPClient, clock: any WallClock = SystemWallClock()
    )
        -> Result<any JobReader, SourceError>
    {
        switch kind {
        case .himalayas:
            return .success(HimalayasReader(key: keys.himalayas, http: http, clock: clock))
        case .googleJobs:
            guard let key = keys.serpAPI, !key.isEmpty else {
                return .failure(.invalidConfiguration("Google Jobs needs your SerpApi key (Sources, Google Jobs)"))
            }
            return .success(GoogleJobsReader(key: key, http: http, clock: clock))
        case .adzuna:
            guard let credentials = keys.adzuna, !credentials.appID.isEmpty, !credentials.appKey.isEmpty else {
                return .failure(.invalidConfiguration("Adzuna needs your app ID and key (Sources, Adzuna)"))
            }
            return .success(AdzunaReader(credentials: credentials, http: http, clock: clock))
        default:
            return .failure(.invalidConfiguration("\(kind.displayName) is a company board, not a search"))
        }
    }

    struct Unreadable: JobReader {
        let kind: SourceKind
        func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
            throw .invalidConfiguration("\(kind.displayName) is a search, not a company board")
        }
    }
}
