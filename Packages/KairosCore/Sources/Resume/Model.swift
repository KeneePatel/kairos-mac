import Foundation
import KairosKit

/// A calendar month, the precision resumes use: "2021-03".
public struct YearMonth: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init?(year: Int, month: Int) {
        guard (1900...2200).contains(year), (1...12).contains(month) else { return nil }
        self.year = year
        self.month = month
    }

    private init(clampedYear year: Int, month: Int) {
        self.year = min(max(year, 1900), 2200)
        self.month = min(max(month, 1), 12)
    }

    /// The month `date` falls in.
    public static func containing(_ date: Date, calendar: Calendar = .current) -> YearMonth {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return YearMonth(clampedYear: parts.year ?? 2000, month: parts.month ?? 1)
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

    /// "October 2026", as resumes print it.
    public var spelledOut: String {
        let names = [
            "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
            "November", "December",
        ]
        return "\(names[month - 1]) \(year)"
    }

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

/// The contact block and header. Validation normalizes the phone and checks the links.
public struct ResumeHeader: Equatable, Sendable, Codable {
    public var fullName = ""
    public var email = ""
    /// E.164 once validated: "+14165550123".
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

    /// "Halifax, NS".
    public var place: String {
        [city, region].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }
}

public enum EntryKind: String, Sendable, CaseIterable, Codable {
    case experience, project, education, certification, award, volunteering, publication, language, custom

    public var title: String {
        switch self {
        case .experience: "Experience"
        case .project: "Projects"
        case .education: "Education"
        case .certification: "Certifications"
        case .award: "Awards"
        case .volunteering: "Volunteering"
        case .publication: "Publications"
        case .language: "Languages"
        case .custom: "Other"
        }
    }
}

/// The per-kind fields of an entry. Each kind's JSON is what the first Kairos stored in
/// `resume_entry.fields`, so entries carry over as they are.
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

        public init(name: String, role: String = "", tech: [String] = [], projectURL: String? = nil, repoURL: String? = nil) {
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
            institution: String, credential: String = "", field: String = "", location: String = "", honours: String = "",
            coursework: [String] = []
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

    /// The fields as stored: compact JSON with sorted keys.
    public func json() throws -> String {
        switch self {
        case .experience(let value): try value.jsonText()
        case .project(let value): try value.jsonText()
        case .education(let value): try value.jsonText()
        case .certification(let value): try value.jsonText()
        case .award(let value), .volunteering(let value), .publication(let value): try value.jsonText()
        case .language(let value): try value.jsonText()
        case .custom(let value): try value.jsonText()
        }
    }

    public static func decode(kind: EntryKind, json: String) throws -> EntryFields {
        switch kind {
        case .experience: .experience(try .fromJSON(json))
        case .project: .project(try .fromJSON(json))
        case .education: .education(try .fromJSON(json))
        case .certification: .certification(try .fromJSON(json))
        case .award: .award(try .fromJSON(json))
        case .volunteering: .volunteering(try .fromJSON(json))
        case .publication: .publication(try .fromJSON(json))
        case .language: .language(try .fromJSON(json))
        case .custom: .custom(try .fromJSON(json))
        }
    }

    /// The entry's name in one line: "Software Developer, Acme", "Kairos", "MACS, Dalhousie".
    public var headline: String {
        switch self {
        case .experience(let job): [job.title, job.employer].filter { !$0.isEmpty }.joined(separator: ", ")
        case .project(let project): project.name
        case .education(let school):
            [school.credential, school.institution].filter { !$0.isEmpty }.joined(separator: ", ")
        case .certification(let cert): cert.name
        case .award(let item), .volunteering(let item), .publication(let item): item.title
        case .language(let language): "\(language.language) (\(language.proficiency.rawValue))"
        case .custom(let custom): custom.title
        }
    }
}

/// A line under an entry. Its id never changes: tailored bullets cite it.
public struct ResumeBullet: Identifiable, Equatable, Sendable, Codable {
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

/// One job, project, degree, certificate and so on, with its bullets in order.
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

    /// "2023-05 – Present", for review screens.
    public var period: String {
        let from = start?.description ?? "?"
        return isCurrent ? "\(from) – Present" : end.map { "\(from) – \($0)" } ?? from
    }
}

public enum SkillLevel: String, Sendable, CaseIterable, Codable {
    /// Backed by your work; resumes may claim it.
    case proven
    /// You could talk about it; only Stretch mode may use it.
    case canDiscuss = "can_discuss"
}

public struct Skill: Identifiable, Equatable, Sendable, Codable {
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

/// Everything you've done: the only source resumes and cover letters are written from.
public struct MasterResume: Equatable, Sendable {
    public var header: ResumeHeader
    /// Every kind, each in its own order.
    public var entries: [ResumeEntry]
    public var skills: [Skill]
    /// Goes up by one on every save; builds record it.
    public var version: Int

    public init(header: ResumeHeader = ResumeHeader(), entries: [ResumeEntry] = [], skills: [Skill] = [], version: Int = 0) {
        self.header = header
        self.entries = entries
        self.skills = skills
        self.version = version
    }

    public func entries(_ kind: EntryKind) -> [ResumeEntry] {
        entries.filter { $0.kind == kind }
    }

    public func entry(_ id: UUID) -> ResumeEntry? { entries.first { $0.id == id } }

    /// Every bullet by id, with the entry it belongs to.
    public var bulletsByID: [UUID: (entry: ResumeEntry, bullet: ResumeBullet)] {
        var result: [UUID: (entry: ResumeEntry, bullet: ResumeBullet)] = [:]
        for entry in entries {
            for bullet in entry.bullets { result[bullet.id] = (entry, bullet) }
        }
        return result
    }

    public var provenSkills: [Skill] { skills.filter { $0.level == .proven } }
    public var canDiscussSkills: [Skill] { skills.filter { $0.level == .canDiscuss } }

    /// Spoken languages and their levels.
    public var languages: [EntryFields.Language] {
        entries.compactMap { if case .language(let language) = $0.fields { language } else { nil } }
    }
}
