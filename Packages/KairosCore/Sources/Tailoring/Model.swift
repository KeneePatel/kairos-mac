import Foundation
import Jobs
import Resume
import Screening

/// Strict by default; stretch only when you turn it on; lite copies your bullets word for word.
public enum BuildMode: String, Codable, Sendable, CaseIterable {
    case strict, lite, stretch

    public var title: String {
        switch self {
        case .strict: "Tailored"
        case .lite: "Lite"
        case .stretch: "Stretch"
        }
    }
}

/// Stretch mode: off until you turn it on.
public struct StretchSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// The most gap bullets one role gets, 0 to 2.
    public var perRole: Int

    public static let storageKey = "stretch_mode"
    public static let maxPerRole = 2

    public init(enabled: Bool = false, perRole: Int = 1) {
        self.enabled = enabled
        self.perRole = perRole
    }

    public var limit: Int { min(Self.maxPerRole, max(0, perRole)) }

    private enum CodingKeys: String, CodingKey { case enabled, perRole }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        perRole = try container.decodeIfPresent(Int.self, forKey: .perRole) ?? 1
    }
}

/// How long a resume may run: one page unless you allow a second, and then only when the
/// posting's evidence needs it.
public struct PageSettings: Codable, Sendable, Equatable {
    public var twoPagesWhenNeeded: Bool

    public static let storageKey = "resume_pages"

    public init(twoPagesWhenNeeded: Bool = false) {
        self.twoPagesWhenNeeded = twoPagesWhenNeeded
    }

    private enum CodingKeys: String, CodingKey { case twoPagesWhenNeeded }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        twoPagesWhenNeeded = try container.decodeIfPresent(Bool.self, forKey: .twoPagesWhenNeeded) ?? false
    }
}

/// Canadian spelling for Canadian jobs, US spelling for US jobs.
public enum SpellingLocale: String, Sendable, Codable, CaseIterable {
    case canada = "en-CA"
    case unitedStates = "en-US"

    public init(country: Country?) {
        self = country == .unitedStates ? .unitedStates : .canada
    }

    var instruction: String {
        switch self {
        case .canada: "Spelling: Canadian spelling (colour, centre, travelled, modelling; -ize as in optimize)."
        case .unitedStates: "Spelling: American spelling (color, center, traveled, modeling)."
        }
    }
}

/// What a posting asks for, as tailoring reads it: requirement texts, must-haves first.
public struct JobRequirements: Sendable, Equatable {
    public var musts: [String]
    public var nices: [String]
    public var domains: [String]
    /// The posting asks about spoken languages, so the resume shows yours.
    public var asksForLanguages: Bool
    /// What the posting says about certifications: the resume shows yours that match.
    public var certificationAsks: [String]

    public init(
        musts: [String], nices: [String] = [], domains: [String] = [], asksForLanguages: Bool = false,
        certificationAsks: [String] = []
    ) {
        self.musts = musts
        self.nices = nices
        self.domains = domains
        self.asksForLanguages = asksForLanguages
        self.certificationAsks = certificationAsks
    }

    /// Skills and experience only: soft traits, location, authorization, availability and
    /// enrolment are screening's to judge, and education and languages have their own rows, so none
    /// of them is a must-have the writers chase or the score counts.
    public init(_ analysis: JobAnalysis) {
        let shown = analysis.requirements.filter { $0.category.map { [.skill, .experience].contains($0) } ?? true }
        self.init(
            musts: shown.filter { $0.kind == .must }.map(\.text), nices: shown.filter { $0.kind == .nice }.map(\.text),
            domains: analysis.domains, asksForLanguages: analysis.requirements.contains { $0.category == .language },
            certificationAsks: analysis.requirements.map(\.text).filter { $0.localizedCaseInsensitiveContains("certif") })
    }
}

/// A bullet a build writes: its text and the master-resume bullets it cites.
public struct TailoredBullet: Codable, Sendable, Equatable {
    public var text: String
    public var sourceIDs: [UUID]
    /// A stretch-mode bullet covering a requirement the master resume doesn't show.
    public var gap: Bool
    /// How well its sources matched the job: page fitting cuts the lowest.
    public var rank: Double
    /// The requirement a gap bullet answers, for "Be ready to discuss".
    public var covers: String?

    /// Backed by your master resume. A gap bullet isn't, so it's listed to prepare for; the PDF
    /// never marks it.
    public var verified: Bool { !gap }

    public init(text: String, sourceIDs: [UUID], gap: Bool = false, rank: Double = 0, covers: String? = nil) {
        self.text = text
        self.sourceIDs = sourceIDs
        self.gap = gap
        self.rank = rank
        self.covers = covers
    }

    private enum CodingKeys: String, CodingKey { case text, sourceIDs, gap, rank, covers, verified }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        sourceIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceIDs) ?? []
        gap = try container.decodeIfPresent(Bool.self, forKey: .gap) ?? false
        rank = try container.decodeIfPresent(Double.self, forKey: .rank) ?? 0
        covers = try container.decodeIfPresent(String.self, forKey: .covers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(sourceIDs, forKey: .sourceIDs)
        try container.encode(gap, forKey: .gap)
        try container.encode(rank, forKey: .rank)
        try container.encodeIfPresent(covers, forKey: .covers)
        try container.encode(verified, forKey: .verified)
    }
}

/// A labelled line of the skills section.
public struct SkillGroup: Codable, Sendable, Equatable {
    public let label: String
    public let skills: [String]

    public init(label: String, skills: [String]) {
        self.label = label
        self.skills = skills
    }
}

/// One build's resume before rendering: every line final, every bullet citing the master-resume
/// bullets it came from. Its JSON is the first Kairos's `build.content`, so old builds still open.
public struct TailoredResume: Codable, Sendable, Equatable {
    public struct ContactLine: Codable, Sendable, Equatable {
        public var text: String
        public var url: String?

        public init(text: String, url: String? = nil) {
            self.text = text
            self.url = url
        }
    }

    /// From the master resume's contact block, by code: contact details never pass through a model.
    public struct Header: Codable, Sendable, Equatable {
        public var name: String
        public var headline: String?
        public var contact: [ContactLine]

        public init(name: String, headline: String? = nil, contact: [ContactLine] = []) {
            self.name = name
            self.headline = headline
            self.contact = contact
        }
    }

    /// When an entry ran, as numbers, so a template can print dates its own way.
    public struct Period: Codable, Sendable, Equatable {
        public struct Month: Codable, Sendable, Equatable {
            public var year: Int
            public var month: Int

            public init(year: Int, month: Int) {
                self.year = year
                self.month = month
            }
        }

        public var start: Month?
        public var end: Month?
        public var isCurrent: Bool

        public init(start: Month? = nil, end: Month? = nil, isCurrent: Bool = false) {
            self.start = start
            self.end = end
            self.isCurrent = isCurrent
        }

        /// Nil when the entry has no dates.
        public init?(_ entry: ResumeEntry) {
            func month(_ value: YearMonth?) -> Month? { value.map { Month(year: $0.year, month: $0.month) } }
            guard entry.start != nil || entry.end != nil || entry.isCurrent else { return nil }
            self.init(start: month(entry.start), end: entry.isCurrent ? nil : month(entry.end), isCurrent: entry.isCurrent)
        }
    }

    /// A role, project, degree or certification as the build shows it.
    public struct Entry: Codable, Sendable, Equatable {
        public var entryID: UUID
        public var title: String
        public var organization: String?
        public var location: String?
        /// "Mar 2022 – Present", for templates that print text.
        public var dates: String?
        public var period: Period?
        public var bullets: [TailoredBullet]

        public init(
            entryID: UUID, title: String, organization: String? = nil, location: String? = nil, dates: String? = nil,
            period: Period? = nil, bullets: [TailoredBullet] = []
        ) {
            self.entryID = entryID
            self.title = title
            self.organization = organization
            self.location = location
            self.dates = dates
            self.period = period
            self.bullets = bullets
        }
    }

    public var header: Header
    public var summary: String?
    public var skills: [SkillGroup]
    public var experience: [Entry]
    public var projects: [Entry]
    public var education: [Entry]
    public var certifications: [Entry]
    /// "English (native), French (conversational)".
    public var languages: String?

    public init(
        header: Header, summary: String? = nil, skills: [SkillGroup] = [], experience: [Entry] = [], projects: [Entry] = [],
        education: [Entry] = [], certifications: [Entry] = [], languages: String? = nil
    ) {
        self.header = header
        self.summary = summary
        self.skills = skills
        self.experience = experience
        self.projects = projects
        self.education = education
        self.certifications = certifications
        self.languages = languages
    }

    /// Every bullet of roles and projects.
    public var allBullets: [TailoredBullet] { (experience + projects).flatMap(\.bullets) }

    /// The gap bullets to be ready to discuss in an interview, with the requirement each answers.
    public var readyToDiscuss: [TailoredBullet] { allBullets.filter(\.gap) }

    func entry(_ id: UUID) -> Entry? { (experience + projects).first { $0.entryID == id } }
}

extension TailoredResume.Header {
    /// Name, headline and contact line from your contact block: email, phone, LinkedIn, GitHub,
    /// portfolio, then city. A GitHub or portfolio link that doesn't validate is left off rather
    /// than blocking the build.
    public init(_ entered: ResumeHeader) {
        let validation = Validator.validate(entered)
        var header = validation.header
        if validation.issue(for: .gitHub) != nil { header.gitHubURL = nil }
        if validation.issue(for: .portfolio) != nil { header.portfolioURL = nil }
        var contact: [TailoredResume.ContactLine] = []
        if !header.email.isEmpty { contact.append(.init(text: header.email, url: "mailto:\(header.email)")) }
        if !header.phone.isEmpty {
            contact.append(.init(text: Self.displayPhone(header.phone), url: "tel:" + (header.phone.hasPrefix("+") ? "+" : "") + header.phone.filter(\.isNumber)))
        }
        for url in [header.linkedInURL, header.gitHubURL ?? "", header.portfolioURL ?? ""] where !url.isEmpty {
            contact.append(.init(text: Self.displayURL(url), url: url))
        }
        if !header.place.isEmpty { contact.append(.init(text: header.place)) }
        let headline = header.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: header.fullName, headline: headline.isEmpty ? nil : headline, contact: contact)
    }

    /// "+14165550123" → "(416) 555-0123".
    static func displayPhone(_ e164: String) -> String {
        let digits = e164.filter(\.isNumber)
        guard e164.hasPrefix("+1"), digits.count == 11 else { return e164 }
        let number = Array(digits.dropFirst())
        return "(\(String(number[0..<3]))) \(String(number[3..<6]))-\(String(number[6..<10]))"
    }

    /// "https://www.linkedin.com/in/jordan-rivera" → "linkedin.com/in/jordan-rivera".
    static func displayURL(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://", "www."] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}

/// A cover letter: the model writes only the paragraphs; code adds the header, date, greeting and
/// sign-off from your master resume.
public struct CoverLetter: Codable, Sendable, Equatable {
    public var header: TailoredResume.Header
    public var date: String
    public var company: String
    public var jobTitle: String
    public var greeting: String
    public var paragraphs: [String]
    public var closing: String
    public var signature: String

    public init(
        header: TailoredResume.Header, date: String, company: String, jobTitle: String, greeting: String,
        paragraphs: [String], closing: String, signature: String
    ) {
        self.header = header
        self.date = date
        self.company = company
        self.jobTitle = jobTitle
        self.greeting = greeting
        self.paragraphs = paragraphs
        self.closing = closing
        self.signature = signature
    }
}

/// "Mar 2022 – Present", "2015 – 2019" for education.
enum DisplayDates {
    static func range(_ entry: ResumeEntry, monthNames: Bool = true) -> String? {
        let start = entry.start.map { month($0, named: monthNames) }
        let end = entry.isCurrent ? "Present" : entry.end.map { month($0, named: monthNames) }
        switch (start, end) {
        case (let start?, let end?): return start == end ? start : "\(start) – \(end)"
        case (let start?, nil): return start
        case (nil, let end?): return end
        case (nil, nil): return nil
        }
    }

    static func month(_ month: YearMonth, named: Bool = true) -> String {
        guard named else { return "\(month.year)" }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month.month - 1]) \(month.year)"
    }
}
