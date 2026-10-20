import Foundation
import MasterResume

/// One build's resume, before rendering: every line final, every bullet citing the master-resume
/// bullets it came from (SPEC §6.2, `build.content`).
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

    /// A role, project, degree or certification as the build shows it.
    public struct Entry: Codable, Sendable, Equatable {
        public var entryID: UUID
        public var title: String
        public var organization: String?
        public var location: String?
        public var dates: String?
        public var bullets: [TailoredBullet]

        public init(
            entryID: UUID, title: String, organization: String? = nil, location: String? = nil,
            dates: String? = nil, bullets: [TailoredBullet] = []
        ) {
            self.entryID = entryID
            self.title = title
            self.organization = organization
            self.location = location
            self.dates = dates
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
        header: Header, summary: String? = nil, skills: [SkillGroup] = [], experience: [Entry] = [],
        projects: [Entry] = [], education: [Entry] = [], certifications: [Entry] = [], languages: String? = nil
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

    /// Every bullet, for scoring and fitting.
    var allBullets: [TailoredBullet] { (experience + projects).flatMap(\.bullets) }
}

extension TailoredResume.Header {
    /// Name, headline and contact line from your contact block: email, phone, LinkedIn, GitHub,
    /// portfolio, then city. A GitHub or portfolio link that doesn't validate is left off rather
    /// than blocking the build (SPEC §5.10).
    public init(_ entered: ResumeHeader) {
        let validation = Validator.validate(entered)
        var header = validation.header
        if validation.issue(for: .gitHub) != nil { header.gitHubURL = nil }
        if validation.issue(for: .portfolio) != nil { header.portfolioURL = nil }
        var contact: [TailoredResume.ContactLine] = []
        if !header.email.isEmpty { contact.append(.init(text: header.email, url: "mailto:\(header.email)")) }
        if !header.phone.isEmpty { contact.append(.init(text: Self.displayPhone(header.phone))) }
        for url in [header.linkedInURL, header.gitHubURL ?? "", header.portfolioURL ?? ""] where !url.isEmpty {
            contact.append(.init(text: Self.displayURL(url), url: url))
        }
        let place = [header.city, header.region].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if !place.isEmpty { contact.append(.init(text: place)) }
        let headline = header.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(name: header.fullName, headline: headline.isEmpty ? nil : headline, contact: contact)
    }

    /// "+14165550123" → "(416) 555-0123"; other numbers as stored.
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

/// "Mar 2022 – Present", "2015 – 2019" for education, and so on.
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

    private static func month(_ month: YearMonth, named: Bool) -> String {
        guard named else { return "\(month.year)" }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month.month - 1]) \(month.year)"
    }
}
