import Foundation
import Tailoring

/// What a resume template reads, as JSON: a header from the contact block, then sections in order.
/// Everything is final text: templates lay it out and never decide content.
public struct ResumeDocument: Codable, Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public var name: String
        public var headline: String?
        public var contact: [ContactItem]

        public init(name: String, headline: String? = nil, contact: [ContactItem] = []) {
            self.name = name
            self.headline = headline
            self.contact = contact
        }
    }

    public struct ContactItem: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case email, phone, website, location
            case linkedIn = "linkedin"
            case gitHub = "github"

            /// From the link: mailto, tel, LinkedIn, GitHub or another site. Without one, a phone
            /// number when it's mostly digits, otherwise the place.
            public init(text: String, url: String?) {
                guard let url = url?.lowercased() else {
                    self = text.filter(\.isNumber).count >= 7 ? .phone : .location
                    return
                }
                if url.hasPrefix("mailto:") {
                    self = .email
                } else if url.hasPrefix("tel:") {
                    self = .phone
                } else {
                    let host = URL(string: url)?.host() ?? ""
                    func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
                    self = on("linkedin.com") ? .linkedIn : on("github.com") ? .gitHub : .website
                }
            }
        }

        public var text: String
        public var url: String?
        public var kind: Kind

        public init(text: String, url: String? = nil, kind: Kind? = nil) {
            self.text = text
            self.url = url
            self.kind = kind ?? Kind(text: text, url: url)
        }

        /// The order of Harvard's samples: place, phone, email, then links.
        static func harvardOrder(_ items: [ContactItem]) -> [ContactItem] {
            let order: [Kind] = [.location, .phone, .email, .linkedIn, .gitHub, .website]
            return items.enumerated().sorted {
                (order.firstIndex(of: $0.element.kind) ?? order.count, $0.offset)
                    < (order.firstIndex(of: $1.element.kind) ?? order.count, $1.offset)
            }.map(\.element)
        }
    }

    public enum SectionKind: String, Codable, Sendable, CaseIterable {
        case summary, experience, projects, education, skills, certifications, languages, custom
    }

    public struct Section: Codable, Sendable, Equatable {
        public var kind: SectionKind
        public var title: String
        public var visible: Bool
        /// A paragraph, for the summary.
        public var text: String?
        public var items: [Item]
        /// Labelled lists, for skills.
        public var groups: [Group]

        public init(
            kind: SectionKind, title: String, visible: Bool = true, text: String? = nil, items: [Item] = [],
            groups: [Group] = []
        ) {
            self.kind = kind
            self.title = title
            self.visible = visible
            self.text = text
            self.items = items
            self.groups = groups
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var title: String
        public var subtitle: String?
        public var location: String?
        public var dates: String?
        public var bullets: [String]
        /// Makes the title a link: a project's page in the master resume export.
        public var url: String?

        public init(
            title: String, subtitle: String? = nil, location: String? = nil, dates: String? = nil,
            bullets: [String] = [], url: String? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.location = location
            self.dates = dates
            self.bullets = bullets
            self.url = url
        }
    }

    public struct Group: Codable, Sendable, Equatable {
        public var label: String
        public var items: [String]

        public init(label: String, items: [String]) {
            self.label = label
            self.items = items
        }
    }

    public struct Style: Codable, Sendable, Equatable {
        public enum Paper: String, Codable, Sendable {
            case usLetter = "us-letter"
            case a4
        }
        public var paper: Paper
        /// Body size in points.
        public var fontSize: Double
        /// Page margin in inches.
        public var margin: Double

        /// Harvard's: one size kept consistent (its sample's 11 pt) and equal margins of ¾ in.
        public init(paper: Paper = .usLetter, fontSize: Double = 11, margin: Double = 0.75) {
            self.paper = paper
            self.fontSize = fontSize
            self.margin = margin
        }
    }

    public var header: Header
    public var sections: [Section]
    public var style: Style

    public init(header: Header, sections: [Section], style: Style = Style()) {
        self.header = header
        self.sections = sections
        self.style = style
    }

    /// About how many characters a line of bullets holds (Harvard measured 104 for typical text),
    /// so writers can fill whole lines.
    public static let lineCharacters = 100

    /// A build as Harvard's Mignone Center lays a resume out (Kenee chose Harvard's rules over their
    /// own, 2026-10-21): Education then Skills first, as its guide says for tech resumes, then
    /// Experience, Projects and Certifications; spoken languages as a Language row under Skills; no
    /// summary; every date as month and year spelled out, the year on both ends of a range, so a
    /// parser reads it exactly (one stores a year alone as January 1st); a degree still under way
    /// marked "(Expected)".
    public init(_ resume: TailoredResume, now: Date = Date()) {
        func item(_ entry: TailoredResume.Entry, degree: Bool = false) -> Item {
            Item(
                title: entry.title, subtitle: entry.organization, location: entry.location,
                dates: entry.period.flatMap { HarvardDates.text($0, expected: degree, now: now) }
                    ?? entry.dates.map(HarvardDates.spelledOut),
                bullets: entry.bullets.map(\.text))
        }
        var sections: [Section] = []
        if !resume.education.isEmpty {
            sections.append(
                Section(kind: .education, title: "Education", items: resume.education.map { item($0, degree: true) }))
        }
        var groups = resume.skills.map { Group(label: $0.label, items: $0.skills) }
        if let languages = resume.languages, !languages.isEmpty {
            groups.append(Group(label: "Language", items: [languages]))
        }
        if !groups.isEmpty { sections.append(Section(kind: .skills, title: "Skills", groups: groups)) }
        if !resume.experience.isEmpty {
            sections.append(Section(kind: .experience, title: "Experience", items: resume.experience.map { item($0) }))
        }
        if !resume.projects.isEmpty {
            sections.append(Section(kind: .projects, title: "Projects", items: resume.projects.map { item($0) }))
        }
        if !resume.certifications.isEmpty {
            sections.append(
                Section(kind: .certifications, title: "Certifications", items: resume.certifications.map { item($0) }))
        }
        self.init(
            header: Header(
                name: resume.header.name, headline: resume.header.headline,
                contact: ContactItem.harvardOrder(resume.header.contact.map { ContactItem(text: $0.text, url: $0.url) })
            ),
            sections: sections)
    }

    /// Your whole master resume in the same layout with no page budget: your highlights as a
    /// summary, then Education, Skills (Proven by category, then Can discuss, with a Language row),
    /// Experience, Projects, Certifications on one line each, and every other section by its name.
    public init(_ resume: FullResume, now: Date = Date()) {
        func item(_ entry: FullResume.Entry, degree: Bool = false, oneLine: Bool = false) -> Item {
            Item(
                title: oneLine
                    ? [entry.title, entry.organization].compactMap { $0 }.joined(separator: " · ") : entry.title,
                subtitle: oneLine ? nil : entry.organization, location: entry.location,
                dates: entry.period.flatMap { HarvardDates.text($0, expected: degree, now: now) },
                bullets: entry.bullets,
                url: entry.url)
        }
        var sections: [Section] = []
        if let summary = resume.summary, !summary.isEmpty {
            sections.append(Section(kind: .summary, title: "Summary", text: summary))
        }
        if !resume.education.isEmpty {
            sections.append(
                Section(kind: .education, title: "Education", items: resume.education.map { item($0, degree: true) }))
        }
        var groups = resume.skills.map { Group(label: $0.label, items: $0.skills) }
        if let languages = resume.languages, !languages.isEmpty {
            groups.append(Group(label: "Language", items: [languages]))
        }
        if !groups.isEmpty { sections.append(Section(kind: .skills, title: "Skills", groups: groups)) }
        if !resume.experience.isEmpty {
            sections.append(Section(kind: .experience, title: "Experience", items: resume.experience.map { item($0) }))
        }
        if !resume.projects.isEmpty {
            sections.append(Section(kind: .projects, title: "Projects", items: resume.projects.map { item($0) }))
        }
        if !resume.certifications.isEmpty {
            sections.append(
                Section(
                    kind: .certifications, title: "Certifications",
                    items: resume.certifications.map { item($0, oneLine: true) }))
        }
        for section in resume.additional where !section.entries.isEmpty {
            sections.append(Section(kind: .custom, title: section.title, items: section.entries.map { item($0) }))
        }
        self.init(
            header: Header(
                name: resume.header.name, headline: resume.header.headline,
                contact: ContactItem.harvardOrder(resume.header.contact.map { ContactItem(text: $0.text, url: $0.url) })
            ),
            sections: sections)
    }
}

/// Dates as Harvard writes them: months in full, a year on every month.
enum HarvardDates {
    private static let names = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November",
        "December",
    ]
    private static let abbreviations = [
        "Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April", "Jun": "June", "Jul": "July",
        "Aug": "August",
        "Sep": "September", "Sept": "September", "Oct": "October", "Nov": "November", "Dec": "December",
    ]

    /// `text(_:)`, plus "(Expected)" after a degree that ends after `now`.
    static func text(_ period: TailoredResume.Period, expected: Bool, now: Date) -> String? {
        guard let text = text(period) else { return nil }
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        guard expected, let end = period.end, let year = today.year, let month = today.month,
            (end.year, end.month) > (year, month)
        else { return text }
        return text + " (Expected)"
    }

    /// "January 2024 – August 2025", "September 2024 – Present", or one date when there's one.
    static func text(_ period: TailoredResume.Period) -> String? {
        func month(_ value: TailoredResume.Period.Month) -> String {
            names.indices.contains(value.month - 1) ? "\(names[value.month - 1]) \(value.year)" : "\(value.year)"
        }
        let start = period.start.map(month)
        let end = period.isCurrent ? "Present" : period.end.map(month)
        switch (start, end) {
        case (let start?, let end?): return start == end ? start : "\(start) – \(end)"
        case (let only?, nil), (nil, let only?): return only
        case (nil, nil): return nil
        }
    }

    /// Stored text from a build made before dates were kept as numbers: "Mar 2022" → "March 2022".
    static func spelledOut(_ dates: String) -> String {
        dates.split(separator: " ", omittingEmptySubsequences: false).map { word in
            abbreviations[String(word).trimmingCharacters(in: CharacterSet(charactersIn: "."))] ?? String(word)
        }.joined(separator: " ")
    }
}

/// What `cover.typ` reads: a letter that's final text, under the same header as the resume.
public struct LetterDocument: Codable, Sendable, Equatable {
    public var header: ResumeDocument.Header
    public var date: String
    /// "Hiring team", then the company.
    public var recipient: [String]
    /// "Re: Backend Developer II".
    public var subject: String?
    public var greeting: String
    public var paragraphs: [String]
    public var closing: String
    public var signature: String
    public var style: ResumeDocument.Style

    public init(_ letter: CoverLetter, style: ResumeDocument.Style = ResumeDocument.Style(fontSize: 11, margin: 1)) {
        header = ResumeDocument.Header(
            name: letter.header.name,
            contact: ResumeDocument.ContactItem.harvardOrder(
                letter.header.contact.map { ResumeDocument.ContactItem(text: $0.text, url: $0.url) }))
        date = letter.date
        recipient = ["Hiring team", letter.company]
        subject = letter.jobTitle.isEmpty ? nil : "Re: \(letter.jobTitle)"
        greeting = letter.greeting
        paragraphs = letter.paragraphs
        closing = letter.closing
        signature = letter.signature
        self.style = style
    }
}
