import Foundation
import Tailoring

extension ResumeDocument {
    /// Your whole master resume as Harvard lays a resume out, with no page budget (SPEC §5.10,
    /// Export): your highlights as a summary, then Education, Skills (Proven by category, then Can
    /// discuss, with a Language row), Experience, Projects, Certifications, and every other
    /// section under its own name. Every entry keeps every bullet; a project's title links to its
    /// page. Dates are spelled out as for a build, and a degree still under way is "(Expected)".
    /// A certificate takes one line, "name · issuer", as a build prints it.
    public init(_ resume: FullResume, now: Date = Date()) {
        func item(_ entry: FullResume.Entry, degree: Bool = false, oneLine: Bool = false) -> Item {
            Item(
                title: oneLine
                    ? [entry.title, entry.organization].compactMap { $0 }.joined(separator: " · ") : entry.title,
                subtitle: oneLine ? nil : entry.organization, location: entry.location,
                dates: entry.period.flatMap { HarvardDates.text($0, expected: degree, now: now) },
                bullets: entry.bullets, url: entry.url)
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
        let contact = ContactItem.harvardOrder(resume.header.contact.map { ContactItem(text: $0.text, url: $0.url) })
        self.init(
            header: Header(name: resume.header.name, headline: resume.header.headline, contact: contact),
            sections: sections, style: ResumeTemplate.harvard.style, template: .harvard)
    }
}
