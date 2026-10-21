import Foundation
import Tailoring

extension ResumeDocument {
    /// A build laid out for `template`: Classic's arrangement below, or Harvard's (`harvard(_:)`).
    public init(_ resume: TailoredResume, for template: ResumeTemplate) {
        switch template {
        case .classic: self.init(resume, style: template.style)
        case .harvard: self = Self.harvard(resume)
        }
    }

    /// A build as the template reads it, in the Build mockup's order: summary, experience,
    /// projects, skills, education, certifications, languages. Empty sections are left out.
    public init(_ resume: TailoredResume, style: Style = Style()) {
        var sections: [Section] = []
        if let summary = resume.summary, !summary.isEmpty {
            sections.append(Section(kind: .summary, title: "Summary", text: summary))
        }
        if !resume.experience.isEmpty {
            sections.append(Section(kind: .experience, title: "Experience", items: resume.experience.map(Self.item)))
        }
        if !resume.projects.isEmpty {
            sections.append(Section(kind: .projects, title: "Projects", items: resume.projects.map(Self.item)))
        }
        if !resume.skills.isEmpty {
            sections.append(
                Section(
                    kind: .skills, title: "Skills",
                    groups: resume.skills.map { Group(label: $0.label, items: $0.skills) }))
        }
        if !resume.education.isEmpty {
            sections.append(Section(kind: .education, title: "Education", items: resume.education.map(Self.item)))
        }
        if !resume.certifications.isEmpty {
            sections.append(
                Section(kind: .certifications, title: "Certifications", items: resume.certifications.map(Self.item)))
        }
        if let languages = resume.languages, !languages.isEmpty {
            sections.append(Section(kind: .languages, title: "Languages", text: languages))
        }
        self.init(
            header: Header(
                name: resume.header.name, headline: resume.header.headline,
                contact: resume.header.contact.map { ContactItem(text: $0.text, url: $0.url) }),
            sections: sections, style: style)
    }

    private static func item(_ entry: TailoredResume.Entry) -> Item {
        Item(
            title: entry.title, subtitle: entry.organization, location: entry.location, dates: entry.dates,
            bullets: entry.bullets.map(\.text))
    }
}

extension ResumeDocument {
    /// A build as Harvard's Mignone Center lays a resume out (polish P5b):
    /// - Education first, then Skills, "for tech (computer science) resumes" (Optional category
    ///   examples, 2026), then Experience, Projects and Certifications. Spoken languages are a
    ///   "Language" row under Skills, as in Harvard's "Skills & Interests".
    /// - No summary: neither Harvard template nor any of its samples has one.
    /// - Every date as month and year, spelled out ("Don't abbreviate"), with the year on both ends
    ///   of a range, education included: "January 2024 – August 2025". A parser reads that exactly;
    ///   a year alone it stores as 1 January (polish P5c).
    /// - The contact line in the order of its master's samples: place, phone, email, then links.
    static func harvard(_ resume: TailoredResume) -> ResumeDocument {
        func item(_ entry: TailoredResume.Entry) -> Item {
            Item(
                title: entry.title, subtitle: entry.organization, location: entry.location,
                dates: entry.period.flatMap(HarvardDates.text) ?? entry.dates.map(HarvardDates.spelledOut),
                bullets: entry.bullets.map(\.text))
        }
        var sections: [Section] = []
        if !resume.education.isEmpty {
            sections.append(
                Section(
                    kind: .education, title: "Education", items: resume.education.map { item($0) }))
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
        let contact = ContactItem.harvardOrder(resume.header.contact.map { ContactItem(text: $0.text, url: $0.url) })
        return ResumeDocument(
            header: Header(name: resume.header.name, headline: resume.header.headline, contact: contact),
            sections: sections, style: ResumeTemplate.harvard.style, template: .harvard)
    }
}

extension ResumeDocument.ContactItem {
    /// The order of Harvard's master's samples: place, phone, email, then links. Ties keep their order.
    static func harvardOrder(_ items: [Self]) -> [Self] {
        let order: [Kind] = [.location, .phone, .email, .linkedIn, .gitHub, .website]
        return items.enumerated().sorted {
            (order.firstIndex(of: $0.element.kind) ?? order.count, $0.offset)
                < (order.firstIndex(of: $1.element.kind) ?? order.count, $1.offset)
        }.map(\.element)
    }
}

/// Dates as Harvard writes them: months in full, and a year on every month.
enum HarvardDates {
    private static let names = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
        "November", "December",
    ]
    private static let abbreviations = [
        "Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April", "Jun": "June", "Jul": "July",
        "Aug": "August", "Sep": "September", "Sept": "September", "Oct": "October", "Nov": "November",
        "Dec": "December",
    ]

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

    /// Stored text from a build made before dates were kept as numbers: "Mar 2022 – Present" →
    /// "March 2022 – Present". Years stay as they are; there's no month to add.
    static func spelledOut(_ dates: String) -> String {
        dates.split(separator: " ", omittingEmptySubsequences: false).map { word in
            abbreviations[String(word).trimmingCharacters(in: CharacterSet(charactersIn: "."))] ?? String(word)
        }.joined(separator: " ")
    }
}
