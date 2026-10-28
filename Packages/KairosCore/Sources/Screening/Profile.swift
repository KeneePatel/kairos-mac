import Foundation
import Resume

/// Your master resume as evidence for `analyzeJob`: every skill, degree, language, role, project
/// and bullet gets a short id the model cites when it says a requirement is met ("s4", "x1b2",
/// "d1"), and code checks each cited id exists.
///
/// In it (Kenee's decision, 2026-10-20): skill names and levels, degrees and fields (not the
/// school), languages, roles with employer and dates, projects with their tech, every bullet.
/// Never in it: contact details (redacted from every line, in case a bullet names your GitHub), work
/// authorization, clearance, or where you live. Code judges those on this Mac.
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
    /// Can-discuss skills, "c1"…: a partial match at most.
    public let canDiscuss: [Item]
    /// "d1"…: "MACS, Applied Computer Science".
    public let education: [Item]
    /// "l1"…: "English (fluent)".
    public let languages: [Item]
    /// "x1", bullets "x1b1"…
    public let experience: [Entry]
    /// "p1", bullets "p1b1"…
    public let projects: [Entry]
    /// Every id's text, built once: the job pane describes evidence for every requirement it shows.
    private let lookup: [String: String]

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
            [entry.start?.description, entry.isCurrent ? "present" : entry.end?.description].compactMap { $0 }
                .joined(separator: " to ")
        }
        totalYears = header.totalYears
        skills = items("s", resume.provenSkills.map(\.name))
        canDiscuss = items("c", resume.canDiscussSkills.map(\.name))
        education = items(
            "d",
            resume.entries(.education).compactMap { entry in
                guard case .education(let school) = entry.fields else { return nil }
                return [school.credential, school.field].filter { !$0.isEmpty }.joined(separator: ", ")
            })
        languages = items("l", resume.languages.map { "\($0.language) (\($0.proficiency.rawValue))" })
        func entries(_ kind: EntryKind, _ prefix: String) -> [Entry] {
            resume.entries(kind).enumerated().map { index, entry in
                let id = "\(prefix)\(index + 1)"
                let heading: String =
                    switch entry.fields {
                    case .experience(let role):
                        [role.title, role.employer, dates(entry)].filter { !$0.isEmpty }.joined(separator: " · ")
                    case .project(let project):
                        ([project.name] + (project.tech.isEmpty ? [] : [project.tech.joined(separator: ", ")]) + [
                            dates(entry)
                        ])
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                    default: ""
                    }
                return Entry(id: id, heading: clean(heading), bullets: items("\(id)b", entry.bullets.map(\.text)))
            }
        }
        experience = entries(.experience, "x")
        projects = entries(.project, "p")
        let flat =
            skills + canDiscuss + education + languages
            + (experience + projects).flatMap { [Item(id: $0.id, text: $0.heading)] + $0.bullets }
        lookup = Dictionary(flat.map { ($0.id, $0.text) }) { first, _ in first }
    }

    /// The `<profile>` block. Total years get an id ("y1"), so a years requirement can cite it.
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

    /// The evidence an id names, in words.
    public func describe(_ id: String) -> String? {
        if id == "y1", let totalYears {
            return "\(totalYears.formatted()) year\(totalYears == 1 ? "" : "s") of professional experience"
        }
        return lookup[id]
    }

    /// Whether `id` names a Can-discuss skill, which can only partly meet a requirement.
    public func isCanDiscuss(_ id: String) -> Bool { canDiscuss.contains { $0.id == id } }

    /// Skill and language names, as the first prompt's `matched_skill` used them.
    var names: [String] {
        skills.map(\.text) + canDiscuss.map(\.text) + languages.map { $0.text.components(separatedBy: " (")[0] }
    }
}
