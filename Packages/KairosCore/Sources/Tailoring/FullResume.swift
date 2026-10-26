import Foundation
import MasterResume

/// Your whole master resume laid out for printing: every entry with every bullet, nothing
/// selected and no page budget (SPEC §5.10, Export). A build is a `TailoredResume`; this is the
/// "everything" document you keep for yourself. Contact details come from your contact block by
/// code, as for a build.
public struct FullResume: Sendable, Equatable {
    /// A role, project, degree, certificate or any other entry, every line final.
    public struct Entry: Sendable, Equatable {
        public var title: String
        /// The employer, the school, the issuer, or a project's role and stack.
        public var organization: String?
        public var location: String?
        public var period: TailoredResume.Period?
        /// A project's page or repository, a certificate's credential, a publication's link.
        public var url: String?
        public var bullets: [String]

        public init(
            title: String, organization: String? = nil, location: String? = nil,
            period: TailoredResume.Period? = nil, url: String? = nil, bullets: [String] = []
        ) {
            self.title = title
            self.organization = organization
            self.location = location
            self.period = period
            self.url = url
            self.bullets = bullets
        }
    }

    /// Awards, Volunteering, Publications, or a section you named yourself.
    public struct Section: Sendable, Equatable {
        public var title: String
        public var entries: [Entry]

        public init(title: String, entries: [Entry]) {
            self.title = title
            self.entries = entries
        }
    }

    public var header: TailoredResume.Header
    /// Your highlights, as the profile paragraph.
    public var summary: String?
    /// Proven skills by category, in the order you keep them, then one group of what you can discuss.
    public var skills: [SkillGroup]
    public var experience: [Entry]
    public var projects: [Entry]
    public var education: [Entry]
    public var certifications: [Entry]
    /// "English (fluent), Hindi (native)".
    public var languages: String?
    /// Awards, Volunteering and Publications when you have any, then your own sections in order.
    public var additional: [Section]
    /// The master resume's version, printed so you know which one you're holding.
    public var version: Int

    public init(
        header: TailoredResume.Header, summary: String? = nil, skills: [SkillGroup] = [], experience: [Entry] = [],
        projects: [Entry] = [], education: [Entry] = [], certifications: [Entry] = [], languages: String? = nil,
        additional: [Section] = [], version: Int = 0
    ) {
        self.header = header
        self.summary = summary
        self.skills = skills
        self.experience = experience
        self.projects = projects
        self.education = education
        self.certifications = certifications
        self.languages = languages
        self.additional = additional
        self.version = version
    }

    /// The label of the group that holds your Can-discuss skills.
    public static let canDiscussLabel = "Can discuss"

    /// Everything in `resume`, in the order it keeps its entries.
    public init(_ resume: MasterResume) {
        let highlights = resume.header.highlights.trimmingCharacters(in: .whitespacesAndNewlines)
        var titled: [EntryKind: [Entry]] = [:]
        var custom: [(section: String, entry: Entry)] = []
        for entry in resume.entries {
            let bullets = entry.bullets.map(\.text)
            let period = TailoredResume.Period(entry)
            switch entry.fields {
            case .experience(let role):
                let type = role.employmentType.trimmingCharacters(in: .whitespaces)
                titled[.experience, default: []].append(
                    Entry(
                        title: type.isEmpty ? role.title : "\(role.title) (\(type))", organization: role.employer,
                        location: Self.text(role.location), period: period, bullets: bullets))
            case .project(let project):
                let stack = project.tech.filter { !$0.isEmpty }.joined(separator: ", ")
                let subtitle = [Self.text(project.role), Self.text(stack)].compactMap { $0 }.joined(separator: " · ")
                titled[.project, default: []].append(
                    Entry(
                        title: project.name, organization: Self.text(subtitle), period: period,
                        url: Self.text(project.projectURL ?? "") ?? Self.text(project.repoURL ?? ""),
                        bullets: bullets))
            case .education(let school):
                let title = [school.credential, school.field, school.honours].filter { !$0.isEmpty }
                    .joined(separator: ", ")
                let coursework = school.coursework.filter { !$0.isEmpty }
                titled[.education, default: []].append(
                    Entry(
                        title: title.isEmpty ? school.institution : title,
                        organization: title.isEmpty ? nil : school.institution, location: Self.text(school.location),
                        period: period,
                        bullets: (coursework.isEmpty ? [] : ["Coursework: " + coursework.joined(separator: "; ")])
                            + bullets))
            case .certification(let certificate):
                titled[.certification, default: []].append(
                    Entry(
                        title: certificate.name, organization: Self.text(certificate.issuer), period: period,
                        url: Self.text(certificate.credentialURL ?? ""), bullets: bullets))
            case .award(let value), .volunteering(let value), .publication(let value):
                titled[entry.kind, default: []].append(
                    Entry(
                        title: value.title, organization: Self.text(value.organization), period: period,
                        url: Self.text(value.url ?? ""), bullets: bullets))
            case .language:
                break
            case .custom(let value):
                let section = value.section.trimmingCharacters(in: .whitespaces)
                custom.append(
                    (
                        section.isEmpty ? "Additional" : section,
                        Entry(title: value.title, period: period, bullets: bullets)
                    ))
            }
        }
        var additional: [Section] = []
        for (kind, title) in [
            (EntryKind.award, "Awards"), (.volunteering, "Volunteering"), (.publication, "Publications"),
        ]
        where !(titled[kind] ?? []).isEmpty {
            additional.append(Section(title: title, entries: titled[kind] ?? []))
        }
        for (section, entry) in custom {
            if let index = additional.firstIndex(where: { $0.title == section }) {
                additional[index].entries.append(entry)
            } else {
                additional.append(Section(title: section, entries: [entry]))
            }
        }
        let spoken = resume.entries(.language).compactMap { entry -> String? in
            guard case .language(let language) = entry.fields else { return nil }
            return "\(language.language) (\(language.proficiency.rawValue))"
        }
        self.init(
            header: TailoredResume.Header(resume.header), summary: highlights.isEmpty ? nil : highlights,
            skills: Self.groups(resume.skills), experience: titled[.experience] ?? [], projects: titled[.project] ?? [],
            education: titled[.education] ?? [], certifications: titled[.certification] ?? [],
            languages: spoken.isEmpty ? nil : spoken.joined(separator: ", "), additional: additional,
            version: resume.version)
    }

    /// Proven skills under their categories in order of first appearance (uncategorized ones under
    /// "Other"), then every Can-discuss skill in one group: only Stretch mode may use those.
    static func groups(_ skills: [Skill]) -> [SkillGroup] {
        var labels: [String] = []
        var proven: [String: [String]] = [:]
        var discuss: [String] = []
        for skill in skills {
            switch skill.level {
            case .proven:
                let label = text(skill.category) ?? "Other"
                if proven[label] == nil { labels.append(label) }
                proven[label, default: []].append(skill.name)
            case .canDiscuss:
                discuss.append(skill.name)
            }
        }
        return labels.map { SkillGroup(label: $0, skills: proven[$0] ?? []) }
            + (discuss.isEmpty ? [] : [SkillGroup(label: canDiscussLabel, skills: discuss)])
    }

    /// Trimmed, or nil when blank.
    private static func text(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
