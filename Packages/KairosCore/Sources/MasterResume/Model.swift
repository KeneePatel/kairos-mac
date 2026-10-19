import Foundation
import Store

/// A calendar month, the precision resumes use: "2021-03".
public struct YearMonth: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init?(year: Int, month: Int) {
        guard (1900...2200).contains(year), (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    /// Parses "YYYY-MM".
    public init?(_ text: String) {
        let parts = text.split(separator: "-")
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2, let year = Int(parts[0]),
            let month = Int(parts[1])
        else { return nil }
        self.init(year: year, month: month)
    }

    public var description: String { String(format: "%04d-%02d", year, month) }

    /// Whole months from `self` to `other`; negative if `other` is earlier.
    public func months(until other: YearMonth) -> Int {
        (other.year - year) * 12 + (other.month - month)
    }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = YearMonth(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not YYYY-MM"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// The contact block and header. Validation (T16) normalizes the phone and checks the URLs.
public struct ResumeHeader: Equatable, Sendable {
    public var fullName = ""
    public var email = ""
    /// E.164 once validated, such as "+14165550123".
    public var phone = ""
    public var linkedInURL = ""
    public var gitHubURL: String?
    public var portfolioURL: String?
    public var city: String?
    public var region: String?
    public var country: String?
    public var headline = ""
    /// Free text the summary writer may draw from.
    public var highlights = ""
    /// The number you enter; validation warns when it disagrees with your experience dates.
    public var totalYears: Double?

    public init() {}
}

public enum EntryKind: String, Sendable, CaseIterable, Codable {
    case experience, project, education, certification, award, volunteering, publication, language, custom
}

/// The per-kind fields of an entry, stored as `resume_entry.fields`.
public enum EntryFields: Equatable, Sendable {
    public struct Experience: Codable, Equatable, Sendable {
        public var employer: String
        public var title: String
        public var location: String
        /// Full-time, part-time, contract, internship, ...
        public var employmentType: String

        public init(employer: String, title: String, location: String = "", employmentType: String = "") {
            self.employer = employer
            self.title = title
            self.location = location
            self.employmentType = employmentType
        }
    }

    public struct Project: Codable, Equatable, Sendable {
        public var name: String
        public var role: String
        public var tech: [String]
        public var projectURL: String?
        public var repoURL: String?

        public init(
            name: String, role: String = "", tech: [String] = [], projectURL: String? = nil, repoURL: String? = nil
        ) {
            self.name = name
            self.role = role
            self.tech = tech
            self.projectURL = projectURL
            self.repoURL = repoURL
        }
    }

    public struct Education: Codable, Equatable, Sendable {
        public var institution: String
        public var credential: String
        public var field: String
        public var location: String
        public var honours: String
        public var coursework: [String]

        public init(
            institution: String, credential: String = "", field: String = "", location: String = "",
            honours: String = "", coursework: [String] = []
        ) {
            self.institution = institution
            self.credential = credential
            self.field = field
            self.location = location
            self.honours = honours
            self.coursework = coursework
        }
    }

    public struct Certification: Codable, Equatable, Sendable {
        public var name: String
        public var issuer: String
        public var credentialURL: String?

        public init(name: String, issuer: String = "", credentialURL: String? = nil) {
            self.name = name
            self.issuer = issuer
            self.credentialURL = credentialURL
        }
    }

    /// An award, a volunteering role or a publication: a title, who it's from or for, and a link.
    public struct Titled: Codable, Equatable, Sendable {
        public var title: String
        /// The issuer, organization or publisher.
        public var organization: String
        public var url: String?

        public init(title: String, organization: String = "", url: String? = nil) {
            self.title = title
            self.organization = organization
            self.url = url
        }
    }

    public struct Language: Codable, Equatable, Sendable {
        public enum Proficiency: String, Codable, Sendable, CaseIterable {
            case native, fluent, professional, conversational, basic
        }
        public var language: String
        public var proficiency: Proficiency

        public init(language: String, proficiency: Proficiency) {
            self.language = language
            self.proficiency = proficiency
        }
    }

    /// An entry in a section you name yourself.
    public struct Custom: Codable, Equatable, Sendable {
        public var section: String
        public var title: String

        public init(section: String, title: String) {
            self.section = section
            self.title = title
        }
    }

    case experience(Experience)
    case project(Project)
    case education(Education)
    case certification(Certification)
    case award(Titled)
    case volunteering(Titled)
    case publication(Titled)
    case language(Language)
    case custom(Custom)

    public var kind: EntryKind {
        switch self {
        case .experience: .experience
        case .project: .project
        case .education: .education
        case .certification: .certification
        case .award: .award
        case .volunteering: .volunteering
        case .publication: .publication
        case .language: .language
        case .custom: .custom
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        switch self {
        case .experience(let value): return try encoder.encode(value)
        case .project(let value): return try encoder.encode(value)
        case .education(let value): return try encoder.encode(value)
        case .certification(let value): return try encoder.encode(value)
        case .award(let value), .volunteering(let value), .publication(let value): return try encoder.encode(value)
        case .language(let value): return try encoder.encode(value)
        case .custom(let value): return try encoder.encode(value)
        }
    }

    static func decode(kind: EntryKind, from data: Data) throws -> EntryFields {
        let decoder = JSONDecoder()
        switch kind {
        case .experience: return .experience(try decoder.decode(Experience.self, from: data))
        case .project: return .project(try decoder.decode(Project.self, from: data))
        case .education: return .education(try decoder.decode(Education.self, from: data))
        case .certification: return .certification(try decoder.decode(Certification.self, from: data))
        case .award: return .award(try decoder.decode(Titled.self, from: data))
        case .volunteering: return .volunteering(try decoder.decode(Titled.self, from: data))
        case .publication: return .publication(try decoder.decode(Titled.self, from: data))
        case .language: return .language(try decoder.decode(Language.self, from: data))
        case .custom: return .custom(try decoder.decode(Custom.self, from: data))
        }
    }
}

/// A line under an entry. Its id never changes: tailored bullets cite it (SPEC §5.10).
public struct ResumeBullet: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    /// Chips such as "40% faster".
    public var metrics: [String]
    /// Names of the skills this bullet shows.
    public var skills: [String]

    public init(id: UUID = .v7(), text: String, metrics: [String] = [], skills: [String] = []) {
        self.id = id
        self.text = text
        self.metrics = metrics
        self.skills = skills
    }
}

/// One experience, project, degree, certificate and so on, with its bullets in order.
public struct ResumeEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var fields: EntryFields
    public var start: YearMonth?
    /// Nil while `isCurrent`.
    public var end: YearMonth?
    public var isCurrent: Bool
    public var bullets: [ResumeBullet]

    public var kind: EntryKind { fields.kind }

    public init(
        id: UUID = .v7(), fields: EntryFields, start: YearMonth? = nil, end: YearMonth? = nil, isCurrent: Bool = false,
        bullets: [ResumeBullet] = []
    ) {
        self.id = id
        self.fields = fields
        self.start = start
        self.end = end
        self.isCurrent = isCurrent
        self.bullets = bullets
    }
}

public enum SkillLevel: String, Sendable, CaseIterable, Codable {
    /// Backed by your experience; resumes may claim it.
    case proven
    /// You could talk about it; only Stretch mode may use it (SPEC §5.3).
    case canDiscuss = "can_discuss"
}

public struct Skill: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// Language, framework, cloud, tool, ...
    public var category: String
    public var level: SkillLevel

    public init(id: UUID = .v7(), name: String, category: String = "", level: SkillLevel = .proven) {
        self.id = id
        self.name = name
        self.category = category
        self.level = level
    }
}

/// Everything you've done: the only source the resume and cover-letter builders read (SPEC §5.10).
public struct MasterResume: Equatable, Sendable {
    public var header: ResumeHeader
    /// Every kind, each in its own order.
    public var entries: [ResumeEntry]
    public var skills: [Skill]
    /// Goes up by one on every save. Builds record it.
    public let version: Int

    public init(
        header: ResumeHeader = ResumeHeader(), entries: [ResumeEntry] = [], skills: [Skill] = [], version: Int = 0
    ) {
        self.header = header
        self.entries = entries
        self.skills = skills
        self.version = version
    }

    public func entries(_ kind: EntryKind) -> [ResumeEntry] {
        entries.filter { $0.kind == kind }
    }
}
