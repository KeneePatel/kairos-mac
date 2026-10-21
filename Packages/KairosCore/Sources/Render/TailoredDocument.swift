import Foundation
import Tailoring

extension ResumeDocument {
    /// A build as the template reads it, in the Build mockup's order: summary, experience,
    /// projects, skills, education, certifications, languages. Empty sections are left out. The style
    /// is the standard template's unless given.
    public init(_ resume: TailoredResume, style: Style = ResumeTemplate.standard.style) {
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
