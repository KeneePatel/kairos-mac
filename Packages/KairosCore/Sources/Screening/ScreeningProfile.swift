import Foundation
import MasterResume

/// Your master resume as evidence for `analyzeJob` (prompt v2): every skill, degree, language,
/// role, project and bullet gets a short id the model cites when it says a requirement is met
/// ("s4", "x1b2", "d1"), and code checks each id it cites exists.
///
/// What's in it (your decision, 2026-10-20): skill names and levels, degrees and fields (not the
/// school), languages, roles with employer and dates, projects with their tech, and every bullet.
/// What's never in it: contact details (redacted from every line, in case a bullet names your
/// GitHub), work authorization, clearance, and where you live. Code judges those on this Mac.
public struct ScreeningProfile: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let id: String
        public let text: String
    }

    public struct Entry: Sendable, Equatable {
        public let id: String
        public let heading: String
        public let bullets: [Item]
    }

    public let totalYears: Double?
    /// Proven skills, "s1"…
    public let skills: [Item]
    /// Can-discuss skills, "c1"…: at most a partial match.
    public let canDiscuss: [Item]
    /// "d1"…: "MACS, Applied Computer Science".
    public let education: [Item]
    /// "l1"…: "English (fluent)".
    public let languages: [Item]
    /// "x1", bullets "x1b1"…
    public let experience: [Entry]
    /// "p1", bullets "p1b1"…
    public let projects: [Entry]

    public init(_ resume: MasterResume) {
        let header = resume.header
        func clean(_ text: String) -> String {
            ContactRedactor.redact(text, header: header).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func items(_ prefix: String, _ texts: [String]) -> [Item] {
            texts.map(clean).filter { !$0.isEmpty }.enumerated().map {
                Item(id: "\(prefix)\($0.offset + 1)", text: $0.element)
            }
        }
        func dates(_ entry: ResumeEntry) -> String {
            let start = entry.start.map { "\($0.year)-\(String(format: "%02d", $0.month))" }
            let end = entry.isCurrent ? "present" : entry.end.map { "\($0.year)-\(String(format: "%02d", $0.month))" }
            return [start, end].compactMap { $0 }.joined(separator: " to ")
        }
        totalYears = header.totalYears
        skills = items("s", resume.skills.filter { $0.level == .proven }.map(\.name))
        canDiscuss = items("c", resume.skills.filter { $0.level == .canDiscuss }.map(\.name))
        education = items(
            "d",
            resume.entries(.education).compactMap { entry in
                guard case .education(let school) = entry.fields else { return nil }
                return [school.credential, school.field].filter { !$0.isEmpty }.joined(separator: ", ")
            })
        languages = items(
            "l",
            resume.entries(.language).compactMap { entry in
                guard case .language(let language) = entry.fields else { return nil }
                return "\(language.language) (\(language.proficiency.rawValue))"
            })
        func entries(_ kind: EntryKind, _ prefix: String) -> [Entry] {
            resume.entries(kind).enumerated().map { index, entry in
                let id = "\(prefix)\(index + 1)"
                let heading: String =
                    switch entry.fields {
                    case .experience(let role):
                        [role.title, role.employer, dates(entry)].filter { !$0.isEmpty }
                            .joined(separator: " · ")
                    case .project(let project):
                        ([project.name] + (project.tech.isEmpty ? [] : [project.tech.joined(separator: ", ")])
                            + [dates(entry)]).filter { !$0.isEmpty }.joined(separator: " · ")
                    default: ""
                    }
                return Entry(id: id, heading: clean(heading), bullets: items("\(id)b", entry.bullets.map(\.text)))
            }
        }
        experience = entries(.experience, "x")
        projects = entries(.project, "p")
    }

    /// Skill names and languages only, for callers that have no master resume (and older tests).
    public init(skills: [Skill], languages: [EntryFields.Language], totalYears: Double? = nil) {
        var resume = MasterResume()
        resume.skills = skills
        resume.entries = languages.map { ResumeEntry(fields: .language($0)) }
        resume.header.totalYears = totalYears
        self.init(resume)
    }

    /// The `<profile>` block of the prompt. Your total years get an id ("y1") too, so a years
    /// requirement judged against them can cite it.
    public var text: String {
        var lines = [
            totalYears.map { "[y1] Total years of professional experience: \($0.formatted())" }
                ?? "Total years of professional experience: not stated"
        ]
        func list(_ title: String, _ items: [Item]) {
            if !items.isEmpty {
                lines.append("\(title): " + items.map { "[\($0.id)] \($0.text)" }.joined(separator: ", "))
            }
        }
        list("Skills", skills)
        list("Can discuss (not proven)", canDiscuss)
        list("Education", education)
        list("Languages", languages)
        for (title, entries) in [("Experience", experience), ("Project", projects)] {
            for entry in entries {
                lines.append("[\(entry.id)] \(title): \(entry.heading)")
                lines += entry.bullets.map { "  [\($0.id)] \($0.text)" }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The evidence an id names, in words: a skill, a degree, a role or project, or a bullet.
    public func describe(_ id: String) -> String? {
        if id == "y1", let totalYears {
            return "\(totalYears.formatted()) year\(totalYears == 1 ? "" : "s") of professional experience"
        }
        let flat =
            skills + canDiscuss + education + languages
            + (experience + projects).flatMap { [Item(id: $0.id, text: $0.heading)] + $0.bullets }
        return flat.first { $0.id == id }?.text
    }

    /// Whether `id` names a Can-discuss skill, which can only partly meet a requirement.
    public func isCanDiscuss(_ id: String) -> Bool { canDiscuss.contains { $0.id == id } }

    /// Skill and language names, as the v1 prompt's `matched_skill` used them.
    var names: [String] {
        skills.map(\.text) + canDiscuss.map(\.text) + languages.map { $0.text.components(separatedBy: " (")[0] }
    }
}
