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
    /// - Months spelled out ("Don't abbreviate"), a range within one year written once
    ///   ("May – August 2025"), and a degree shown by when it was finished.
    /// - The contact line in the order of its master's samples: place, phone, email, then links.
    static func harvard(_ resume: TailoredResume) -> ResumeDocument {
        func item(_ entry: TailoredResume.Entry, graduation: Bool = false) -> Item {
            Item(
                title: entry.title, subtitle: entry.organization, location: entry.location,
                dates: entry.dates.map { graduation ? HarvardDates.graduation($0) : HarvardDates.spelledOut($0) },
                bullets: entry.bullets.map(\.text))
        }
        var sections: [Section] = []
        if !resume.education.isEmpty {
            sections.append(
                Section(
                    kind: .education, title: "Education", items: resume.education.map { item($0, graduation: true) }))
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

/// Dates as Harvard writes them.
enum HarvardDates {
    private static let months = [
        "Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April", "Jun": "June", "Jul": "July",
        "Aug": "August", "Sep": "September", "Sept": "September", "Oct": "October", "Nov": "November",
        "Dec": "December",
    ]

    /// "Mar 2022 – Present" → "March 2022 – Present"; "May 2025 – Aug 2025" → "May – August 2025".
    static func spelledOut(_ dates: String) -> String {
        let words = dates.split(separator: " ", omittingEmptySubsequences: false).map { word in
            months[String(word).trimmingCharacters(in: CharacterSet(charactersIn: "."))] ?? String(word)
        }
        // "Month Year – Month Year" in one year: the year once, at the end.
        if words.count == 5, words[2] == "–", words[1] == words[4], Int(words[1]) != nil {
            return "\(words[0]) – \(words[3]) \(words[4])"
        }
        return words.joined(separator: " ")
    }

    /// A finished degree by when it ended ("2015 – 2019" → "2019"); one still under way keeps its range.
    static func graduation(_ dates: String) -> String {
        let spelled = spelledOut(dates)
        guard let end = spelled.components(separatedBy: " – ").last, end != "Present", spelled.contains(" – ")
        else { return spelled }
        return end
    }
}
