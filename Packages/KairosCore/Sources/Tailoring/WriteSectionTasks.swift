import Foundation
import LLM
import MasterResume

/// What every writer knows about the job (SPEC §5.5 catalog: requirements, mode rules, spelling).
public struct WriterBrief: Sendable, Equatable {
    public var jobTitle: String
    public var requirements: JobRequirements
    public var locale: SpellingLocale
    /// Characters a line of the template's bullets holds, so bullets fill whole lines.
    public var lineCharacters: Int

    public init(jobTitle: String, requirements: JobRequirements, locale: SpellingLocale, lineCharacters: Int = 100) {
        self.jobTitle = jobTitle
        self.requirements = requirements
        self.locale = locale
        self.lineCharacters = lineCharacters
    }

    /// `<layout>`, for the section writers: a bullet a few words past a line wastes the line.
    var layoutBlock: String {
        let two = (Double(lineCharacters) * 1.7).rounded()
        return """
            <layout>
            A line holds about \(lineCharacters) characters. A bullet of up to \(lineCharacters) characters takes one line; one of \(Int(two)) to \(lineCharacters * 2) takes two nearly full lines. Anything between wastes most of its second line.
            </layout>
            """
    }

    /// `<job>` and `<requirements>`, shared by every writer's prompt.
    var promptBlocks: String {
        let requirements =
            requirements.musts.map { "Must: \($0)" } + requirements.nices.map { "Nice: \($0)" }
            + (requirements.domains.isEmpty ? [] : ["Domains: \(requirements.domains.joined(separator: ", "))"])
        return """
            <job>
            Title: \(jobTitle)
            </job>
            <requirements>
            \(requirements.joined(separator: "\n"))
            </requirements>
            """
    }
}

/// Selected roles or projects for a section writer, with your Proven skills and the verifier its
/// replies are checked with. Prompts call entries "e1" and bullets "b1", never by UUID.
public struct WriteSectionInput: Sendable {
    public let brief: WriterBrief
    public let entries: [SelectedEntry]
    public let skills: [Skill]
    public let verifier: Verifier

    /// Short id → entry, and short id → (bullet, its entry's short id), in prompt order.
    let entryIDs: [String: UUID]
    let bulletIDs: [String: (bullet: UUID, entry: String)]
    let entryOrder: [String]

    public init(brief: WriterBrief, entries: [SelectedEntry], skills: [Skill], verifier: Verifier) {
        self.brief = brief
        self.entries = entries
        self.skills = skills
        self.verifier = verifier
        var entryIDs: [String: UUID] = [:]
        var bulletIDs: [String: (bullet: UUID, entry: String)] = [:]
        var order: [String] = []
        var bulletNumber = 0
        for (index, selected) in entries.enumerated() {
            let entry = "e\(index + 1)"
            entryIDs[entry] = selected.entry.id
            order.append(entry)
            for ranked in selected.bullets {
                bulletNumber += 1
                bulletIDs["b\(bulletNumber)"] = (ranked.bullet.id, entry)
            }
        }
        self.entryIDs = entryIDs
        self.bulletIDs = bulletIDs
        entryOrder = order
    }

    func shortID(of bullet: UUID) -> String? {
        bulletIDs.first { $0.value.bullet == bullet }?.key
    }
}

/// A section writer's reply: bullets per entry, citing short bullet ids.
public struct SectionOutput: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public var id: String
        public var bullets: [Bullet]
    }

    public struct Bullet: Decodable, Sendable, Equatable {
        public var text: String
        public var sourceIds: [String]
    }

    public var entries: [Entry]
}

/// The bullets written for one master-resume entry.
public struct WrittenEntry: Sendable, Equatable {
    public let entryID: UUID
    public let bullets: [TailoredBullet]
    /// Your bullets word for word (lite mode, or a writer that failed): polish leaves them alone.
    public let verbatim: Bool

    public init(entryID: UUID, bullets: [TailoredBullet], verbatim: Bool = false) {
        self.entryID = entryID
        self.bullets = bullets
        self.verbatim = verbatim
    }
}

/// The shared work of the experience and projects writers (SPEC §5.3, Write).
enum SectionWriter {
    static let schema = JSONSchema.object([
        .required(
            "entries",
            .array(
                of: .object([
                    .required("id", .string(maxLength: 8)),
                    .required(
                        "bullets",
                        .array(
                            of: .object([
                                .required("text", .string(maxLength: 600)),
                                .required("source_ids", .array(of: .string(maxLength: 8), maxItems: 4)),
                            ]), maxItems: 8)),
                ]), maxItems: 12))
    ])

    static func messages(_ task: TaskID, version: Int, tag: String, input: WriteSectionInput) -> [ChatMessage] {
        let instructions = PromptLibrary.instructions(for: task, version: version) ?? ""
        let entries = zip(input.entryOrder, input.entries).map { short, selected in
            let bullets = selected.bullets.map { ranked -> String in
                let id = input.shortID(of: ranked.bullet.id) ?? "?"
                var details: [String] = []
                if !ranked.bullet.metrics.isEmpty {
                    details.append("metrics: \(ranked.bullet.metrics.joined(separator: "; "))")
                }
                if !ranked.bullet.skills.isEmpty {
                    details.append("skills: \(ranked.bullet.skills.joined(separator: ", "))")
                }
                return "[\(id)] \(ranked.bullet.text)"
                    + (details.isEmpty ? "" : " (\(details.joined(separator: "; ")))")
            }
            return "<\(tag) id=\"\(short)\">\(heading(selected.entry))\n\(bullets.joined(separator: "\n"))\n</\(tag)>"
        }
        let data = """
            \(input.brief.promptBlocks)
            \(input.brief.layoutBlock)
            <skills>
            \(input.skills.map(\.name).joined(separator: ", "))
            </skills>
            <\(tag)s>
            \(entries.joined(separator: "\n"))
            </\(tag)s>
            """
        return [.system(instructions + "\n\n" + input.brief.locale.instruction), .user(data)]
    }

    /// Ids, completeness, length, and every claim through the verifier. Problems go back to the
    /// model in one repair call.
    static func check(_ output: SectionOutput, for input: WriteSectionInput) throws {
        var problems: [String] = []
        let written = Set(output.entries.map(\.id))
        for entry in output.entries where input.entryIDs[entry.id] == nil {
            problems.append("“\(entry.id)” isn't one of the entries given.")
        }
        for missing in input.entryOrder where !written.contains(missing) {
            problems.append("\(missing) is missing: write at least one bullet for every entry.")
        }
        for entry in output.entries where input.entryIDs[entry.id] != nil {
            if entry.bullets.isEmpty { problems.append("\(entry.id) has no bullets.") }
            for bullet in entry.bullets {
                problems += self.problems(with: bullet, in: entry.id, input: input)
            }
        }
        if !problems.isEmpty {
            throw LLMError.invalidOutput(problems.prefix(6).joined(separator: " "))
        }
    }

    private static func problems(with bullet: SectionOutput.Bullet, in entry: String, input: WriteSectionInput)
        -> [String]
    {
        let text = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ["\(entry) has a blank bullet."] }
        var problems: [String] = []
        if text.count > Polish.maxBulletLength {
            problems.append("“\(text.prefix(40))…” is over \(Polish.maxBulletLength) characters.")
        }
        if bullet.sourceIds.isEmpty { problems.append("“\(text.prefix(40))…” cites no bullet.") }
        if text.contains(ContactRedactor.marker) {
            problems.append("“\(text.prefix(40))…” contains \(ContactRedactor.marker); leave that detail out.")
        }
        var sources: [UUID] = []
        for id in bullet.sourceIds {
            guard let source = input.bulletIDs[id] else {
                problems.append("“\(text.prefix(40))…” cites \(id), which isn't one of the bullets given.")
                continue
            }
            if source.entry != entry {
                problems.append("“\(text.prefix(40))…” cites \(id), which belongs to another entry.")
            }
            sources.append(source.bullet)
        }
        guard sources.count == bullet.sourceIds.count else { return problems }
        for violation in input.verifier.check(TailoredBullet(text: text, sourceIDs: sources)) {
            problems.append("“\(text.prefix(40))…”: \(violation.detail)")
        }
        return problems
    }

    static func written(_ output: SectionOutput, input: WriteSectionInput) -> [WrittenEntry] {
        input.entryOrder.compactMap { short in
            guard let id = input.entryIDs[short], let entry = output.entries.first(where: { $0.id == short }) else {
                return nil
            }
            return WrittenEntry(
                entryID: id,
                bullets: entry.bullets.map { bullet in
                    TailoredBullet(
                        text: bullet.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        sourceIDs: bullet.sourceIds.compactMap { input.bulletIDs[$0]?.bullet })
                })
        }
    }

    /// "Software Developer, Backend · Harbourline Logistics · Mar 2022 – present".
    static func heading(_ entry: ResumeEntry) -> String {
        let dates = [entry.start.map(month), entry.isCurrent ? "present" : entry.end.map(month)].compactMap { $0 }
            .joined(separator: " – ")
        let name: String =
            switch entry.fields {
            case .experience(let role): "\(role.title) · \(role.employer)"
            case .project(let project):
                ([project.name] + (project.tech.isEmpty ? [] : [project.tech.joined(separator: ", ")])).joined(
                    separator: " · ")
            default: ""
            }
        return dates.isEmpty ? name : "\(name) · \(dates)"
    }

    private static func month(_ month: YearMonth) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(names[month.month - 1]) \(month.year)"
    }
}

/// `writeExperience`: bullets for each selected role, rewritten for the job from that role's bullets.
public struct WriteExperienceTask: LLMTask {
    public static let id = TaskID.writeExperience
    /// v2: line-filling lengths, every bullet kept, specifics kept (resume v2 plan, phase 1).
    public static let promptVersion = 2
    public static let outputSchema = SectionWriter.schema

    public init() {}

    public func messages(for input: WriteSectionInput, budget: TokenBudget) -> [ChatMessage] {
        SectionWriter.messages(Self.id, version: Self.promptVersion, tag: "role", input: input)
    }

    public func check(_ output: SectionOutput, for input: WriteSectionInput) throws {
        try SectionWriter.check(output, for: input)
    }

    public static func written(_ output: SectionOutput, input: WriteSectionInput) -> [WrittenEntry] {
        SectionWriter.written(output, input: input)
    }
}

/// `writeProjects`: the same for the selected projects.
public struct WriteProjectsTask: LLMTask {
    public static let id = TaskID.writeProjects
    /// v2: line-filling lengths, every bullet kept, specifics kept (resume v2 plan, phase 1).
    public static let promptVersion = 2
    public static let outputSchema = SectionWriter.schema

    public init() {}

    public func messages(for input: WriteSectionInput, budget: TokenBudget) -> [ChatMessage] {
        SectionWriter.messages(Self.id, version: Self.promptVersion, tag: "project", input: input)
    }

    public func check(_ output: SectionOutput, for input: WriteSectionInput) throws {
        try SectionWriter.check(output, for: input)
    }

    public static func written(_ output: SectionOutput, input: WriteSectionInput) -> [WrittenEntry] {
        SectionWriter.written(output, input: input)
    }
}

// MARK: - Summary

public struct WriteSummaryInput: Sendable {
    public let brief: WriterBrief
    public let selection: Selection
    public let totalYears: Double?
    public let verifier: Verifier
    let highlights: WriteSectionInput

    public init(brief: WriterBrief, selection: Selection, totalYears: Double?, verifier: Verifier) {
        self.brief = brief
        self.selection = selection
        self.totalYears = totalYears
        self.verifier = verifier
        highlights = WriteSectionInput(
            brief: brief, entries: selection.experience + selection.projects, skills: selection.skills,
            verifier: verifier)
    }
}

public struct SummaryOutput: Decodable, Sendable, Equatable {
    public var summary: String
    public var sourceIds: [String]
}

/// `writeSummary`: two or three sentences from your selected highlights, within your years.
public struct WriteSummaryTask: LLMTask {
    public static let id = TaskID.writeSummary
    public static let promptVersion = 1
    public static let outputSchema = JSONSchema.object([
        .required("summary", .string(maxLength: 800)),
        .required("source_ids", .array(of: .string(maxLength: 8), maxItems: 8)),
    ])
    static let maxLength = 450

    public init() {}

    public func messages(for input: WriteSummaryInput, budget: TokenBudget) -> [ChatMessage] {
        let instructions = PromptLibrary.instructions(for: Self.id, version: Self.promptVersion) ?? ""
        let highlights = input.highlights.entries.flatMap(\.bullets).compactMap { ranked -> String? in
            input.highlights.shortID(of: ranked.bullet.id).map { "[\($0)] \(ranked.bullet.text)" }
        }
        let years = input.totalYears.map {
            "Total years of experience: \($0.formatted(.number.precision(.fractionLength(0...1))))"
        }
        let data = """
            \(input.brief.promptBlocks)
            <profile>
            \(years ?? "Total years of experience: not stated")
            </profile>
            <skills>
            \(input.selection.skills.map(\.name).joined(separator: ", "))
            </skills>
            <highlights>
            \(highlights.joined(separator: "\n"))
            </highlights>
            """
        return [.system(instructions + "\n\n" + input.brief.locale.instruction), .user(data)]
    }

    public func check(_ output: SummaryOutput, for input: WriteSummaryInput) throws {
        let summary = output.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var problems: [String] = []
        if summary.isEmpty { problems.append("The summary is blank.") }
        if summary.count > Self.maxLength { problems.append("The summary is over \(Self.maxLength) characters.") }
        if summary.contains(ContactRedactor.marker) {
            problems.append("The summary contains \(ContactRedactor.marker); leave that detail out.")
        }
        for id in output.sourceIds where input.highlights.bulletIDs[id] == nil {
            problems.append("It cites \(id), which isn't one of the highlights given.")
        }
        problems += input.verifier.check(text: summary).map(\.detail)
        if !problems.isEmpty { throw LLMError.invalidOutput(problems.prefix(6).joined(separator: " ")) }
    }
}

// MARK: - Skills

public struct WriteSkillsInput: Sendable {
    public let brief: WriterBrief
    /// Proven only, in the selector's order.
    public let skills: [Skill]

    public init(brief: WriterBrief, skills: [Skill]) {
        self.brief = brief
        self.skills = skills.filter { $0.level == .proven }
    }
}

public struct SkillsOutput: Decodable, Sendable, Equatable {
    public struct Group: Decodable, Sendable, Equatable {
        public var label: String
        public var skills: [String]
    }

    public var groups: [Group]
}

/// A labelled line of the skills section, in your spelling.
public struct SkillGroup: Codable, Sendable, Equatable {
    public let label: String
    public let skills: [String]

    public init(label: String, skills: [String]) {
        self.label = label
        self.skills = skills
    }
}

/// `writeSkills`: orders and groups your Proven skills for the job. It never adds one.
public struct WriteSkillsTask: LLMTask {
    public static let id = TaskID.writeSkills
    public static let promptVersion = 1
    public static let outputSchema = JSONSchema.object([
        .required(
            "groups",
            .array(
                of: .object([
                    .required("label", .string(maxLength: 40)),
                    .required("skills", .array(of: .string(maxLength: 60), maxItems: 24)),
                ]), maxItems: 5))
    ])

    public init() {}

    public func messages(for input: WriteSkillsInput, budget: TokenBudget) -> [ChatMessage] {
        let instructions = PromptLibrary.instructions(for: Self.id, version: Self.promptVersion) ?? ""
        let data = """
            \(input.brief.promptBlocks)
            <skills>
            \(input.skills.map(\.name).joined(separator: ", "))
            </skills>
            """
        return [.system(instructions + "\n\n" + input.brief.locale.instruction), .user(data)]
    }

    public func check(_ output: SkillsOutput, for input: WriteSkillsInput) throws {
        let yours = Set(input.skills.map { $0.name.lowercased() })
        var seen: Set<String> = []
        var problems: [String] = []
        if output.groups.isEmpty { problems.append("There are no groups.") }
        for group in output.groups {
            if group.label.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("A group has no label.") }
            for skill in group.skills {
                let key = skill.trimmingCharacters(in: .whitespaces).lowercased()
                if !yours.contains(key) {
                    problems.append("“\(skill)” isn't one of your Proven skills; use only names from <skills>.")
                } else if !seen.insert(key).inserted {
                    problems.append("“\(skill)” appears twice.")
                }
            }
        }
        if !problems.isEmpty { throw LLMError.invalidOutput(problems.prefix(6).joined(separator: " ")) }
    }

    /// The groups, with each skill spelled as in your master resume.
    public static func groups(_ output: SkillsOutput, input: WriteSkillsInput) -> [SkillGroup] {
        let names = Dictionary(
            input.skills.map { ($0.name.lowercased(), $0.name) }, uniquingKeysWith: { first, _ in first })
        return output.groups.map { group in
            SkillGroup(
                label: group.label.trimmingCharacters(in: .whitespaces),
                skills: group.skills.compactMap { names[$0.trimmingCharacters(in: .whitespaces).lowercased()] })
        }
    }
}
