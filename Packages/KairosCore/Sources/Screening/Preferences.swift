import Foundation
import Jobs

/// A job's verdict: should you apply?
public enum Verdict: String, Sendable, CaseIterable, Codable {
    case yes, maybe, no

    public var title: String {
        switch self {
        case .yes: "Yes"
        case .maybe: "Maybe"
        case .no: "No"
        }
    }
}

/// Levels a title can name. Most titles name none, and those never fail the seniority rule.
public enum Seniority: String, Codable, Sendable, CaseIterable {
    case intern, junior, mid, senior, lead, staff, principal, manager, director

    public var title: String { rawValue.capitalized }

    /// The level `title` names; the highest when it names several ("Senior Staff Engineer" is staff).
    public static func of(title: String) -> Seniority? {
        let text = TextScan.fold(title)
        func has(_ phrases: String...) -> Bool { phrases.contains { TextScan.containsPhrase(text, $0) } }
        let words = TextScan.words(text)
        if has("director", "vp", "vice president", "head of", "chief") { return .director }
        // "Product manager" is a role, not a people-manager level; "Management" names a team or a
        // product area ("Software Engineer, Spend Management"), never a level.
        let roles = ["product", "project", "program", "account", "marketing", "sales", "office", "community"]
        if has("manager"), !roles.contains(where: { has("\($0) manager") }) { return .manager }
        if has("principal") { return .principal }
        if has("staff") { return .staff }
        if has("lead", "tech lead", "team lead") { return .lead }
        if has("senior", "sr") || words.contains(where: { ["iii", "iv", "v"].contains($0) }) { return .senior }
        if has("intermediate", "mid level", "mid-level") || words.contains("ii") { return .mid }
        if has("intern", "internship", "co-op", "coop", "student") { return .intern }
        if has("junior", "jr", "entry level", "entry-level", "new grad", "graduate", "associate") || words.last == "i" {
            return .junior
        }
        return nil
    }
}

/// How much of a posting your resume must show.
public struct VerdictThresholds: Codable, Sendable, Equatable {
    /// Share of the must-haves shown for a yes.
    public var yesAt: Double
    /// Below this share, a no; between the two, a maybe.
    public var maybeAt: Double
    /// Asking for up to this many years more than you have makes a maybe at best; more is a no.
    public var yearsGrace: Int

    public init(yesAt: Double = 0.75, maybeAt: Double = 0.5, yearsGrace: Int = 2) {
        self.yesAt = yesAt
        self.maybeAt = maybeAt
        self.yearsGrace = yearsGrace
    }

    private enum CodingKeys: String, CodingKey { case yesAt, maybeAt, yearsGrace }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VerdictThresholds()
        yesAt = try container.decodeIfPresent(Double.self, forKey: .yesAt) ?? defaults.yesAt
        maybeAt = try container.decodeIfPresent(Double.self, forKey: .maybeAt) ?? defaults.maybeAt
        yearsGrace = try container.decodeIfPresent(Int.self, forKey: .yearsGrace) ?? defaults.yearsGrace
    }
}

/// What you're looking for: the "screening" setting, in the first Kairos's JSON shape. Every rule
/// is off until you set it, so a fresh install drops nothing it shouldn't.
public struct SearchPreferences: Codable, Sendable, Equatable {
    /// The kinds of work you look for. With any set, a title must be one of them or one of
    /// `titleInclude`; searches ask for them; a board's other jobs aren't kept.
    public var roles: Set<RoleFamily> = []
    /// Watch every board in Kairos's catalog with jobs in your countries (Kenee's choice, 2026-10-23).
    public var watchCatalog = true
    /// Your other titles: a title containing one counts as yours.
    public var titleInclude: [String] = []
    /// A title containing any of these is out.
    public var titleExclude: [String] = []
    /// Levels you're open to; a title naming another level is out.
    public var seniority: Set<Seniority> = Set(Seniority.allCases)
    /// A posting asking for more years than this is out.
    public var maxYearsRequired: Int?
    /// Countries you'd work in, in priority order (Canada first).
    public var countries: [Country] = [.canada, .unitedStates]
    /// Country code → the provinces or states you'd work in on site; none listed means anywhere.
    public var regions: [String: [String]] = [:]
    public var remoteAllowed = true
    /// Companies you never want to see, matched on whole words ("Amazon" also blocks Amazon Web Services).
    public var blacklist: [String] = []
    /// Keep postings from staffing agencies, recruiters and contractor marketplaces.
    public var showAgencies = false
    /// The cities Google Jobs searches in; nil means the usual cities of your countries.
    public var places: [Place]?
    /// Postings older than this many days are never stored and are filtered out.
    public var maxAgeDays: Int?
    public var thresholds = VerdictThresholds()

    public static let storageKey = "screening"

    public init() {}

    /// Your roles and other titles as one matcher.
    public var roleMatcher: RoleMatcher { RoleMatcher(families: roles, extra: titleInclude) }

    /// Your places, or the usual cities of your countries.
    public var effectivePlaces: [Place] { places ?? countries.flatMap(Place.defaults(for:)) }

    private enum CodingKeys: String, CodingKey {
        case roles, watchCatalog, titleInclude, titleExclude, seniority, maxYearsRequired, countries, regions
        case remoteAllowed, blacklist, maxAgeDays, thresholds, showAgencies, places
    }

    /// Missing fields keep their defaults, so older settings still load after a field is added.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SearchPreferences()
        roles = Set(try container.decodeIfPresent([String].self, forKey: .roles)?.compactMap(RoleFamily.init) ?? [])
        watchCatalog = try container.decodeIfPresent(Bool.self, forKey: .watchCatalog) ?? defaults.watchCatalog
        titleInclude = try container.decodeIfPresent([String].self, forKey: .titleInclude) ?? []
        titleExclude = try container.decodeIfPresent([String].self, forKey: .titleExclude) ?? []
        let levels = try container.decodeIfPresent([String].self, forKey: .seniority)?.compactMap(Seniority.init)
        seniority = levels.map(Set.init) ?? defaults.seniority
        maxYearsRequired = try container.decodeIfPresent(Int.self, forKey: .maxYearsRequired)
        countries =
            try container.decodeIfPresent([String].self, forKey: .countries)?.compactMap(Country.init)
            ?? defaults.countries
        regions = try container.decodeIfPresent([String: [String]].self, forKey: .regions) ?? [:]
        remoteAllowed = try container.decodeIfPresent(Bool.self, forKey: .remoteAllowed) ?? defaults.remoteAllowed
        blacklist = try container.decodeIfPresent([String].self, forKey: .blacklist) ?? []
        showAgencies = try container.decodeIfPresent(Bool.self, forKey: .showAgencies) ?? false
        places = try container.decodeIfPresent([Place].self, forKey: .places)
        maxAgeDays = try container.decodeIfPresent(Int.self, forKey: .maxAgeDays)
        thresholds = try container.decodeIfPresent(VerdictThresholds.self, forKey: .thresholds) ?? defaults.thresholds
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(roles.map(\.rawValue).sorted(), forKey: .roles)
        try container.encode(watchCatalog, forKey: .watchCatalog)
        try container.encode(titleInclude, forKey: .titleInclude)
        try container.encode(titleExclude, forKey: .titleExclude)
        try container.encode(seniority.map(\.rawValue).sorted(), forKey: .seniority)
        try container.encodeIfPresent(maxYearsRequired, forKey: .maxYearsRequired)
        try container.encode(countries.map(\.rawValue), forKey: .countries)
        try container.encode(regions, forKey: .regions)
        try container.encode(remoteAllowed, forKey: .remoteAllowed)
        try container.encode(blacklist, forKey: .blacklist)
        try container.encode(showAgencies, forKey: .showAgencies)
        try container.encodeIfPresent(places, forKey: .places)
        try container.encodeIfPresent(maxAgeDays, forKey: .maxAgeDays)
        try container.encode(thresholds, forKey: .thresholds)
    }
}

/// Where you may work, whether you hold a clearance, and whether you're a student now. Kept only on
/// this Mac and never sent to a model: code judges these.
public struct WorkProfile: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case citizen
        case permanentResident = "permanent_resident"
        case workPermit = "work_permit"
        case needsSponsorship = "needs_sponsorship"

        public var title: String {
            switch self {
            case .citizen: "Citizen"
            case .permanentResident: "Permanent resident"
            case .workPermit: "Work permit"
            case .needsSponsorship: "Needs sponsorship"
            }
        }
    }

    /// For postings that ask for a current student (internships, co-ops). Nil: taken as met, noted.
    public enum Enrolment: String, Codable, Sendable, CaseIterable {
        case student, graduated
    }

    /// Per country. A country left out is unknown, and an unknown never rejects a job.
    public var authorization: [Country: Status]
    public var hasClearance: Bool
    public var enrolment: Enrolment?

    public static let storageKey = "work_profile"

    public init(authorization: [Country: Status] = [:], hasClearance: Bool = false, enrolment: Enrolment? = nil) {
        self.authorization = authorization
        self.hasClearance = hasClearance
        self.enrolment = enrolment
    }

    private enum CodingKeys: String, CodingKey { case authorization, hasClearance, enrolment }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let byCode = try container.decodeIfPresent([String: Status].self, forKey: .authorization) ?? [:]
        authorization = Dictionary(
            uniqueKeysWithValues: byCode.compactMap { code, status in Country(rawValue: code).map { ($0, status) } })
        hasClearance = try container.decodeIfPresent(Bool.self, forKey: .hasClearance) ?? false
        enrolment = try container.decodeIfPresent(Enrolment.self, forKey: .enrolment)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            Dictionary(uniqueKeysWithValues: authorization.map { ($0.key.rawValue, $0.value) }), forKey: .authorization)
        try container.encode(hasClearance, forKey: .hasClearance)
        try container.encodeIfPresent(enrolment, forKey: .enrolment)
    }
}

extension Country {
    /// "the US", for sentences.
    var inSentence: String { self == .canada ? "Canada" : "the US" }
    var adjective: String { self == .canada ? "Canadian" : "US" }
}
