import Foundation
import KairosKit

public enum Country: String, Sendable, CaseIterable, Codable, Hashable {
    case canada = "CA"
    case unitedStates = "US"

    public var name: String { self == .canada ? "Canada" : "United States" }
}

/// Where the work happens. `remoteCountry` is remote within the job's country only ("Remote (US
/// only)"); `remoteAnywhere` spans countries ("Remote - North America", "Worldwide"); `remote`
/// doesn't say where. Raw values are what the first Kairos stored.
public enum RemoteScope: String, Sendable, CaseIterable, Codable {
    case unknown, onsite, hybrid, remote
    case remoteCountry = "remote_country"
    case remoteAnywhere = "remote_anywhere"

    public var isRemote: Bool { [.remote, .remoteCountry, .remoteAnywhere].contains(self) }
}

/// Where a board says the work happens, when it says.
public enum Workplace: String, Sendable, CaseIterable, Codable {
    case onsite, hybrid, remote
}

/// A posted pay range, when the source gives one.
public struct Salary: Codable, Sendable, Equatable, Hashable {
    public enum Period: String, Codable, Sendable, CaseIterable { case year, month, week, day, hour }

    public var min: Double?
    public var max: Double?
    /// ISO 4217: "CAD", "USD".
    public var currency: String?
    public var period: Period?
    /// The source's own words, when it gave words rather than numbers: "$120K – $150K".
    public var text: String?

    public init(
        min: Double? = nil, max: Double? = nil, currency: String? = nil, period: Period? = nil, text: String? = nil
    ) {
        self.min = min
        self.max = max
        self.currency = currency
        self.period = period
        self.text = text
    }
}

/// Where jobs come from. Raw values are what the first Kairos stored.
public enum SourceKind: String, Sendable, CaseIterable, Codable, Hashable {
    case greenhouse, lever, ashby
    case smartRecruiters = "smartrecruiters"
    case workable, recruitee, personio
    case bambooHR = "bamboohr"
    case teamtailor
    /// Remote jobs, searched by role.
    case himalayas
    /// Google for Jobs, through SerpApi with your key.
    case googleJobs = "google_jobs"
    /// Adzuna's search: snippets only, so its results are leads, never jobs.
    case adzuna

    /// Companies' own public job boards.
    public static let boards: [SourceKind] = [
        .greenhouse, .lever, .ashby, .smartRecruiters, .workable, .recruitee, .personio, .bambooHR, .teamtailor,
    ]
    /// Searches across companies.
    public static let searches: [SourceKind] = [.himalayas, .googleJobs, .adzuna]

    public var isBoard: Bool { Self.boards.contains(self) }

    public var displayName: String {
        switch self {
        case .greenhouse: "Greenhouse"
        case .lever: "Lever"
        case .ashby: "Ashby"
        case .smartRecruiters: "SmartRecruiters"
        case .workable: "Workable"
        case .recruitee: "Recruitee"
        case .personio: "Personio"
        case .bambooHR: "BambooHR"
        case .teamtailor: "Teamtailor"
        case .himalayas: "Himalayas"
        case .googleJobs: "Google Jobs"
        case .adzuna: "Adzuna"
        }
    }
}

/// One company's board on one job-board system.
public struct Board: Sendable, Hashable, Codable {
    public var kind: SourceKind
    /// The board's token, slug or account name. Case matters only for SmartRecruiters.
    public var slug: String
    /// The company's name as shown.
    public var name: String
    /// "eu" for a company on Lever's EU instance.
    public var region: String?

    public init(kind: SourceKind, slug: String, name: String, region: String? = nil) {
        self.kind = kind
        self.slug = slug
        self.name = name
        self.region = region
    }

    /// The same board whatever the case of its slug; SmartRecruiters ids keep theirs.
    public var key: String { Self.key(kind: kind, slug: slug) }

    public static func key(kind: SourceKind, slug: String) -> String {
        "\(kind.rawValue)|\(kind == .smartRecruiters ? slug : slug.lowercased())"
    }

    /// The board's public page, for "Open board".
    public var pageURL: URL? {
        switch kind {
        case .greenhouse: URL(string: "https://job-boards.greenhouse.io/\(slug)")
        case .lever: URL(string: region == "eu" ? "https://jobs.eu.lever.co/\(slug)" : "https://jobs.lever.co/\(slug)")
        case .ashby: URL(string: "https://jobs.ashbyhq.com/\(slug)")
        case .smartRecruiters: URL(string: "https://jobs.smartrecruiters.com/\(slug)")
        case .workable: URL(string: "https://apply.workable.com/\(slug)")
        case .recruitee: URL(string: "https://\(slug).recruitee.com")
        case .personio: URL(string: "https://\(slug).jobs.personio.de")
        case .bambooHR: URL(string: "https://\(slug).bamboohr.com/careers")
        case .teamtailor: URL(string: "https://\(slug).teamtailor.com/jobs")
        case .himalayas, .googleJobs, .adzuna: nil
        }
    }
}

/// Board tokens, slugs and org names as the APIs accept them: ASCII letters, digits, "-" and "_".
/// No "." or "/", so a slug can never step out of its URL path segment.
public enum BoardSlug {
    public static func isValid(_ slug: String) -> Bool {
        (1...100).contains(slug.count)
            && slug.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            }
    }
}

/// A city Kairos searches in: Google Jobs works best city by city. Board jobs anywhere in your
/// countries still count.
public struct Place: Codable, Equatable, Hashable, Sendable {
    public var city: String
    /// The province or state, spelled out: "Ontario", "California".
    public var region: String
    public var country: Country

    public init(city: String, region: String, country: Country) {
        self.city = city
        self.region = region
        self.country = country
    }

    /// "Toronto, Ontario".
    public var displayName: String { "\(city), \(region)" }

    /// What SerpApi's `location` takes: "Toronto, Ontario, Canada".
    public var googleLocation: String { "\(city), \(region), \(country.name)" }

    /// One key per place, whatever the case.
    public var key: String { "\(city)|\(region)|\(country.rawValue)".lowercased() }

    /// Canada's seven tech hubs (Kenee's choice, 2026-10-26) or five US ones, for anyone who hasn't
    /// set their own.
    public static func defaults(for country: Country) -> [Place] {
        switch country {
        case .canada:
            [
                ("Toronto", "Ontario"), ("Vancouver", "British Columbia"), ("Montreal", "Quebec"),
                ("Ottawa", "Ontario"), ("Calgary", "Alberta"), ("Waterloo", "Ontario"), ("Halifax", "Nova Scotia"),
            ].map { Place(city: $0.0, region: $0.1, country: .canada) }
        case .unitedStates:
            [
                ("New York", "New York"), ("San Francisco", "California"), ("Seattle", "Washington"),
                ("Austin", "Texas"), ("Boston", "Massachusetts"),
            ].map { Place(city: $0.0, region: $0.1, country: .unitedStates) }
        }
    }

    /// "Halifax, Nova Scotia" or "Halifax, NS": the place, its country found from the region.
    public static func parse(_ text: String) -> Place? {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        let given = parts[1].lowercased()
        for country in Country.allCases {
            for (name, code) in Regions.of(country) where name.lowercased() == given || code.lowercased() == given {
                return Place(city: parts[0], region: name, country: country)
            }
        }
        return nil
    }
}

/// Provinces, territories and states with their codes.
public enum Regions {
    public static func of(_ country: Country) -> [(name: String, code: String)] {
        country == .canada ? provinces : states
    }

    public static func name(of code: String, in country: Country) -> String? {
        of(country).first { $0.code == code }?.name
    }

    static let provinces: [(name: String, code: String)] = [
        ("Alberta", "AB"), ("British Columbia", "BC"), ("Manitoba", "MB"), ("New Brunswick", "NB"),
        ("Newfoundland and Labrador", "NL"), ("Nova Scotia", "NS"), ("Northwest Territories", "NT"), ("Nunavut", "NU"),
        ("Ontario", "ON"), ("Prince Edward Island", "PE"), ("Quebec", "QC"), ("Saskatchewan", "SK"), ("Yukon", "YT"),
    ]

    static let states: [(name: String, code: String)] = [
        ("Alabama", "AL"), ("Alaska", "AK"), ("Arizona", "AZ"), ("Arkansas", "AR"), ("California", "CA"),
        ("Colorado", "CO"), ("Connecticut", "CT"), ("Delaware", "DE"), ("District of Columbia", "DC"),
        ("Florida", "FL"), ("Georgia", "GA"), ("Hawaii", "HI"), ("Idaho", "ID"), ("Illinois", "IL"), ("Indiana", "IN"),
        ("Iowa", "IA"), ("Kansas", "KS"), ("Kentucky", "KY"), ("Louisiana", "LA"), ("Maine", "ME"), ("Maryland", "MD"),
        ("Massachusetts", "MA"), ("Michigan", "MI"), ("Minnesota", "MN"), ("Mississippi", "MS"), ("Missouri", "MO"),
        ("Montana", "MT"), ("Nebraska", "NE"), ("Nevada", "NV"), ("New Hampshire", "NH"), ("New Jersey", "NJ"),
        ("New Mexico", "NM"), ("New York", "NY"), ("North Carolina", "NC"), ("North Dakota", "ND"), ("Ohio", "OH"),
        ("Oklahoma", "OK"), ("Oregon", "OR"), ("Pennsylvania", "PA"), ("Rhode Island", "RI"), ("South Carolina", "SC"),
        ("South Dakota", "SD"), ("Tennessee", "TN"), ("Texas", "TX"), ("Utah", "UT"), ("Vermont", "VT"),
        ("Virginia", "VA"), ("Washington", "WA"), ("West Virginia", "WV"), ("Wisconsin", "WI"), ("Wyoming", "WY"),
    ]
}

/// One Google Jobs search: a role phrase in a place, or remote in a country.
public struct SearchTurn: Sendable, Equatable, Hashable {
    public var phrase: String
    /// Nil with `remote`: "<phrase> remote" in the country.
    public var place: Place?
    public var country: Country
    public var remote: Bool

    public init(phrase: String, place: Place?, country: Country, remote: Bool = false) {
        self.phrase = phrase
        self.place = place
        self.country = country
        self.remote = remote
    }

    /// One key per turn, for remembering when it was last searched.
    public var key: String {
        "\(phrase.lowercased())|\(place?.key ?? (remote ? "remote" : "country"))|\(country.rawValue)"
    }

    /// Every turn the settings call for, in a stable order: each phrase in each place, then remote
    /// in each country.
    public static func all(phrases: [String], places: [Place], countries: [Country]) -> [SearchTurn] {
        phrases.flatMap { phrase in
            places.map { SearchTurn(phrase: phrase, place: $0, country: $0.country) }
                + countries.map { SearchTurn(phrase: phrase, place: nil, country: $0, remote: true) }
        }
    }

    /// The `count` turns least recently searched: never searched first, then the oldest, ties in
    /// the plan's order. On SerpApi's free plan (8 a day) each pair comes round every few days.
    public static func due(_ turns: [SearchTurn], lastSearched: [String: Date], count: Int) -> [SearchTurn] {
        guard count > 0 else { return [] }
        return Array(
            turns.enumerated().sorted { a, b in
                let (la, lb) = (
                    lastSearched[a.element.key] ?? .distantPast, lastSearched[b.element.key] ?? .distantPast
                )
                return la != lb ? la < lb : a.offset < b.offset
            }.prefix(count).map(\.element))
    }
}

/// What a search may spend of its plan: per day (UTC), per 7 days, per month and per fetch.
public struct SearchBudget: Sendable, Equatable {
    public let day: Int
    public let week: Int
    public let month: Int
    /// One fetch's share, so several fetches a day all find jobs.
    public let run: Int

    public init(day: Int, week: Int, month: Int, run: Int) {
        self.day = day
        self.week = week
        self.month = month
        self.run = run
    }

    /// Adzuna's free plan allows 25 a minute, 250 a day, 1,000 a week and 2,500 a month; Kairos
    /// spends most of it (Kenee's choice, 2026-10-23).
    public static let adzuna = SearchBudget(day: 200, week: 950, month: 2_400, run: 80)
    /// SerpApi's free plan allows 250 searches a month.
    public static let serpAPI = SearchBudget(day: 8, week: 56, month: 240, run: 8)
    /// Himalayas allows far more, but its jobs change slowly.
    public static let himalayas = SearchBudget(day: 120, week: 600, month: 2_000, run: 30)

    /// Requests left now, given what was used today, in the last 7 days and this month.
    public func remaining(today: Int, week: Int, month: Int) -> Int {
        max(0, min(day - today, self.week - week, self.month - month, run))
    }
}
