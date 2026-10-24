import Foundation
import Store

/// The prefilter's rules, in the order they run (SPEC §5.2). The raw value is the rule id stored
/// with a prefilter verdict, so it never changes.
public enum PrefilterRule: String, Sendable, CaseIterable, Codable {
    case titleInclude = "title_include"
    case titleExclude = "title_exclude"
    case seniority
    case yearsRequired = "years_required"
    case location
    case remoteScope = "remote_scope"
    case workAuthorization = "work_authorization"
    case clearance
    case french
    case blacklist
    case postingAge = "posting_age"
    case alreadyApplied = "already_applied"
}

/// Why the prefilter dropped a job: the first rule it failed, and one sentence you can read.
public struct Rejection: Sendable, Equatable {
    public let rule: PrefilterRule
    public let reason: String
}

/// A job you applied to, for the "already applied" rule.
public struct AppliedJob: Sendable, Equatable {
    public let company: String
    public let title: String

    public init(company: String, title: String) {
        self.company = company
        self.title = title
    }
}

/// Levels a title can name. Most titles name none, and those never fail the seniority rule.
public enum Seniority: String, Codable, Sendable, CaseIterable {
    case intern, junior, mid, senior, lead, staff, principal, manager, director

    /// The level `title` names; the highest when it names several ("Senior Staff Engineer" is staff).
    public static func of(title: String) -> Seniority? {
        let text = TextScan.fold(title)
        func has(_ phrases: String...) -> Bool { phrases.contains { TextScan.containsPhrase(text, $0) } }
        let words = TextScan.words(text)
        if has("director", "vp", "vice president", "head of", "chief") { return .director }
        // "Product manager" and the like are roles, not a people-manager level. "Management" names a
        // team or a product area ("Software Engineer, Spend Management"), never a level.
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

/// What you're looking for: the synced "screening" setting (SPEC §6.2, `setting`). Every rule is
/// off until you set it, so a fresh install drops nothing it shouldn't.
public struct SearchPreferences: Codable, Sendable, Equatable {
    /// The kinds of work you look for (job collection v2, J3). With any set, a title must be one of
    /// them or contain one of `titleInclude`; searches ask for them; a board's other jobs aren't kept.
    public var roles: Set<RoleFamily> = []
    /// Watch every company in Kairos's board catalog with jobs in your countries (job collection
    /// v2, J5; on, as the owner chose on 2026-10-23).
    public var watchCatalog = true
    /// When any are set, a title must contain one of them (whole words, any case); with roles set,
    /// these are your other titles.
    public var titleInclude: [String] = []
    /// A title containing any of these is out.
    public var titleExclude: [String] = []
    /// Levels you're open to; a title naming another level is out.
    public var seniority: Set<Seniority> = Set(Seniority.allCases)
    /// A posting asking for more years than this is out.
    public var maxYearsRequired: Int?
    /// Countries you'd work in, in priority order (Canada first, SPEC §5.9).
    public var countries: [Country] = [.canada, .unitedStates]
    /// Country code → the provinces or states you'd work in on site; none listed means anywhere.
    public var regions: [String: [String]] = [:]
    public var remoteAllowed = true
    /// Companies you never want to see, matched on whole words ("Amazon" also blocks Amazon Web Services).
    public var blacklist: [String] = []
    /// Postings older than this many days are out: never stored by a fetch (the Fetch screen's
    /// "Posted" menu; Adzuna asks for it in its search), and rejected by the prefilter when a job
    /// stored earlier is screened again.
    public var maxAgeDays: Int?
    /// How much of a posting your skills must cover for a yes or a maybe (the verdict, T29).
    public var thresholds = VerdictThresholds()

    public static let storageKey = "screening"

    public init() {}

    /// Your roles and other titles, as one matcher for searches, the title rule and fetches.
    public var roleMatcher: RoleMatcher { RoleMatcher(families: roles, extra: titleInclude) }

    private enum CodingKeys: String, CodingKey {
        case roles, watchCatalog, titleInclude, titleExclude, seniority, maxYearsRequired, countries, regions,
            remoteAllowed,
            blacklist
        case maxAgeDays, thresholds
    }

    /// Missing fields keep their defaults, so older settings still load after a field is added.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SearchPreferences()
        roles = try container.decodeIfPresent(Set<RoleFamily>.self, forKey: .roles) ?? defaults.roles
        watchCatalog =
            try container.decodeIfPresent(Bool.self, forKey: .watchCatalog) ?? defaults.watchCatalog
        titleInclude = try container.decodeIfPresent([String].self, forKey: .titleInclude) ?? defaults.titleInclude
        titleExclude = try container.decodeIfPresent([String].self, forKey: .titleExclude) ?? defaults.titleExclude
        seniority = try container.decodeIfPresent(Set<Seniority>.self, forKey: .seniority) ?? defaults.seniority
        maxYearsRequired = try container.decodeIfPresent(Int.self, forKey: .maxYearsRequired)
        countries = try container.decodeIfPresent([Country].self, forKey: .countries) ?? defaults.countries
        regions = try container.decodeIfPresent([String: [String]].self, forKey: .regions) ?? defaults.regions
        remoteAllowed = try container.decodeIfPresent(Bool.self, forKey: .remoteAllowed) ?? defaults.remoteAllowed
        blacklist = try container.decodeIfPresent([String].self, forKey: .blacklist) ?? defaults.blacklist
        maxAgeDays = try container.decodeIfPresent(Int.self, forKey: .maxAgeDays)
        thresholds = try container.decodeIfPresent(VerdictThresholds.self, forKey: .thresholds) ?? defaults.thresholds
    }
}

/// Where you may work, and whether you hold a security clearance (SPEC §5.9). Kept only on this
/// Mac, in `private_setting`.
public struct WorkProfile: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case citizen
        case permanentResident = "permanent_resident"
        case workPermit = "work_permit"
        case needsSponsorship = "needs_sponsorship"
    }

    /// Whether you're a student now, for postings that ask for one (internships, co-ops). Nil is
    /// "not set": such a requirement is taken as met and noted.
    public enum Enrolment: String, Codable, Sendable, CaseIterable {
        case student
        case graduated
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
