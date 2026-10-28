import AI
import Foundation
import KairosKit
import PDFKit

/// `importResume`: drafts master-resume sections from resume text whose contact details code has
/// already removed. The draft is shown for review; nothing is saved without you.
public struct ImportResumeTask: AITask {
    public typealias Input = String

    public struct Experience: Decodable, Sendable, Equatable {
        public var title: String
        public var employer: String
        public var location: String?
        public var employmentType: String?
        public var start: String?
        public var end: String?
        public var current: Bool?
        public var bullets: [String]
    }

    public struct Project: Decodable, Sendable, Equatable {
        public var name: String
        public var role: String?
        public var tech: [String]?
        public var url: String?
        public var start: String?
        public var end: String?
        public var current: Bool?
        public var bullets: [String]
    }

    public struct Education: Decodable, Sendable, Equatable {
        public var institution: String
        public var credential: String?
        public var field: String?
        public var location: String?
        public var honours: String?
        public var coursework: [String]?
        public var start: String?
        public var end: String?
    }

    public struct SkillDraft: Decodable, Sendable, Equatable {
        public var name: String
        public var category: String?
        public var level: String
    }

    public struct Certification: Decodable, Sendable, Equatable {
        public var name: String
        public var issuer: String?
        public var date: String?
    }

    public struct Language: Decodable, Sendable, Equatable {
        public var language: String
        public var proficiency: String
    }

    public struct Other: Decodable, Sendable, Equatable {
        public var section: String
        public var title: String
        public var bullets: [String]?
    }

    public struct Output: Decodable, Sendable, Equatable {
        public var headline: String?
        public var highlights: String?
        public var totalYears: Double?
        public var experience: [Experience]
        public var projects: [Project]
        public var education: [Education]
        public var skills: [SkillDraft]
        public var certifications: [Certification]?
        public var languages: [Language]?
        public var other: [Other]?
    }

    public static let id = TaskID.importResume
    public static let promptVersion = 2

    public static let outputSchema: JSONSchema = {
        let month = JSONSchema.string(maxLength: 7)
        let bullets = JSONSchema.array(of: .string(maxLength: 600), maxItems: 40)
        let names = JSONSchema.array(of: .string(maxLength: 80), maxItems: 40)
        return .object([
            .optional("headline", .string(maxLength: 200)),
            .optional("highlights", .string(maxLength: 2_000)),
            .optional("total_years", .number(minimum: 0, maximum: 60)),
            .required(
                "experience",
                .array(
                    of: .object([
                        .required("title", .string(maxLength: 200)), .required("employer", .string(maxLength: 200)),
                        .optional("location", .string(maxLength: 120)),
                        .optional("employment_type", .string(maxLength: 40)),
                        .optional("start", month), .optional("end", month), .optional("current", .boolean),
                        .required("bullets", bullets),
                    ]), maxItems: 40)),
            .required(
                "projects",
                .array(
                    of: .object([
                        .required("name", .string(maxLength: 200)), .optional("role", .string(maxLength: 120)),
                        .optional("tech", names), .optional("url", .string(maxLength: 300)), .optional("start", month),
                        .optional("end", month), .optional("current", .boolean), .required("bullets", bullets),
                    ]), maxItems: 40)),
            .required(
                "education",
                .array(
                    of: .object([
                        .required("institution", .string(maxLength: 200)),
                        .optional("credential", .string(maxLength: 120)),
                        .optional("field", .string(maxLength: 120)), .optional("location", .string(maxLength: 120)),
                        .optional("honours", .string(maxLength: 200)), .optional("coursework", names),
                        .optional("start", month), .optional("end", month),
                    ]), maxItems: 20)),
            .required(
                "skills",
                .array(
                    of: .object([
                        .required("name", .string(maxLength: 80)), .optional("category", .string(maxLength: 40)),
                        .required("level", .enumeration(SkillLevel.allCases.map(\.rawValue))),
                    ]), maxItems: 200)),
            .optional(
                "certifications",
                .array(
                    of: .object([
                        .required("name", .string(maxLength: 200)), .optional("issuer", .string(maxLength: 120)),
                        .optional("date", month),
                    ]), maxItems: 40)),
            .optional(
                "languages",
                .array(
                    of: .object([
                        .required("language", .string(maxLength: 60)),
                        .required(
                            "proficiency", .enumeration(EntryFields.Language.Proficiency.allCases.map(\.rawValue))),
                    ]), maxItems: 20)),
            .optional(
                "other",
                .array(
                    of: .object([
                        .required("section", .string(maxLength: 80)), .required("title", .string(maxLength: 200)),
                        .optional("bullets", bullets),
                    ]), maxItems: 40)),
        ])
    }()

    public init() {}

    public func messages(for input: String, budget: TokenBudget) -> [ChatMessage] {
        let instructions = Prompts.text(Self.id, version: Self.promptVersion, in: .module)
        let room = budget.characters(after: instructions.count + 400)
        let text = input.count > room ? String(input.prefix(room)) + "\n[resume shortened to fit]" : input
        return [.system(instructions), .user(Prompts.block("resume", text))]
    }

    /// Dates are "YYYY-MM" or a year alone, names aren't blank, and no contact details come back
    /// (the input had none, so any would be invented).
    public func check(_ output: Output, for input: String) throws(AIError) {
        var months = output.experience.flatMap { [$0.start, $0.end] } + output.projects.flatMap { [$0.start, $0.end] }
        months += output.education.flatMap { [$0.start, $0.end] } + (output.certifications ?? []).map(\.date)
        for month in months.compactMap({ $0 }) where Self.date(month) == nil {
            throw .invalidOutput("\"\(month)\" isn't a month in YYYY-MM form or a year alone")
        }
        let blanks =
            output.experience.filter { $0.title.tidied.isEmpty || $0.employer.tidied.isEmpty }.count
            + output.projects.filter { $0.name.tidied.isEmpty }.count
            + output.education.filter { $0.institution.tidied.isEmpty }.count
        if blanks > 0 { throw .invalidOutput("\(blanks) entries have no title, employer or name") }
        let everything =
            [output.headline, output.highlights].compactMap { $0 }
            + output.experience.flatMap { $0.bullets + [$0.title, $0.employer] } + output.projects.flatMap(\.bullets)
            + (output.other ?? []).flatMap { ($0.bullets ?? []) + [$0.title] }
        if ContactRedactor.containsContactDetails(everything.joined(separator: "\n")) {
            throw .invalidOutput("the reply contains contact details, which must be left out")
        }
    }

    /// "YYYY-MM", or a year alone when the resume gives no month: January, marked as a guess.
    static func date(_ text: String) -> (month: YearMonth, guessed: Bool)? {
        if let month = YearMonth(text) { return (month, false) }
        guard text.count == 4, text.allSatisfy(\.isASCII), let year = Int(text),
            let month = YearMonth(year: year, month: 1)
        else { return nil }
        return (month, true)
    }
}

/// The reviewed form of an import: entries and skills ready to save, plus the header text.
public struct ImportDraft: Sendable, Equatable {
    public var headline: String?
    public var highlights: String?
    public var totalYears: Double?
    public var entries: [ResumeEntry]
    public var skills: [Skill]
    /// Entries with a date the resume gave as a year alone, set to January: review asks you to check.
    public var monthsToCheck: Set<UUID> = []

    public init(entries: [ResumeEntry], skills: [Skill] = []) {
        self.entries = entries
        self.skills = skills
    }

    public init(_ output: ImportResumeTask.Output) {
        headline = output.headline?.tidied.nonEmpty
        highlights = output.highlights?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        totalYears = output.totalYears
        var guessed = false
        func date(_ text: String?) -> YearMonth? {
            guard let text, let parsed = ImportResumeTask.date(text) else { return nil }
            guessed = guessed || parsed.guessed
            return parsed.month
        }
        func bullets(_ texts: [String]?) -> [ResumeBullet] {
            (texts ?? []).map(\.tidied).filter { !$0.isEmpty }.map { ResumeBullet(text: $0) }
        }
        var entries: [ResumeEntry] = []
        var monthsToCheck: Set<UUID> = []
        func add(_ entry: ResumeEntry) {
            if guessed { monthsToCheck.insert(entry.id) }
            guessed = false
            entries.append(entry)
        }
        for job in output.experience {
            let current = job.current ?? false
            add(
                ResumeEntry(
                    fields: .experience(
                        .init(
                            employer: job.employer.tidied, title: job.title.tidied, location: job.location ?? "",
                            employmentType: job.employmentType ?? "")),
                    start: date(job.start), end: current ? nil : date(job.end), isCurrent: current,
                    bullets: bullets(job.bullets)))
        }
        for project in output.projects {
            let current = project.current ?? false
            add(
                ResumeEntry(
                    fields: .project(
                        .init(
                            name: project.name.tidied, role: project.role ?? "", tech: project.tech ?? [],
                            projectURL: project.url)),
                    start: date(project.start), end: current ? nil : date(project.end), isCurrent: current,
                    bullets: bullets(project.bullets)))
        }
        for school in output.education {
            add(
                ResumeEntry(
                    fields: .education(
                        .init(
                            institution: school.institution.tidied, credential: school.credential ?? "",
                            field: school.field ?? "", location: school.location ?? "", honours: school.honours ?? "",
                            coursework: school.coursework ?? [])), start: date(school.start), end: date(school.end)))
        }
        for cert in output.certifications ?? [] {
            add(
                ResumeEntry(
                    fields: .certification(.init(name: cert.name.tidied, issuer: cert.issuer ?? "")),
                    start: date(cert.date)))
        }
        for language in output.languages ?? [] {
            let level = EntryFields.Language.Proficiency(rawValue: language.proficiency) ?? .professional
            add(ResumeEntry(fields: .language(.init(language: language.language.tidied, proficiency: level))))
        }
        for other in output.other ?? [] {
            add(
                ResumeEntry(
                    fields: .custom(.init(section: other.section.tidied, title: other.title.tidied)),
                    bullets: bullets(other.bullets)))
        }
        self.entries = entries
        self.monthsToCheck = monthsToCheck
        var seen: Set<String> = []
        skills = output.skills.compactMap { draft in
            let name = draft.name.tidied
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return Skill(
                name: name, category: draft.category ?? "", level: SkillLevel(rawValue: draft.level) ?? .canDiscuss)
        }
    }
}

/// What import needs before anything leaves the Mac.
public enum ImportError: Error, Equatable, Sendable {
    /// Required contact fields aren't filled in yet, so the redactor wouldn't know them.
    case contactIncomplete([ResumeField])
    case emptyText
    case unreadablePDF

    public var message: String {
        switch self {
        case .contactIncomplete:
            "Fill in your name, email, phone and LinkedIn first, so Kairos can take them out before the AI reads your resume."
        case .emptyText: "There's no text to read. A scanned PDF needs its text layer; paste the text instead."
        case .unreadablePDF: "That PDF can't be read."
        }
    }
}

public enum ResumeImporter {
    /// The text that may be sent: contact details, work authorization and clearance removed. Fails
    /// until onboarding has the contact fields the redactor needs.
    public static func prepare(_ text: String, header: ResumeHeader) throws(ImportError) -> String {
        let missing = Validator.validate(header).issues.filter { $0.kind == .missing && $0.field != .totalYears }
            .map(\.field)
        guard missing.isEmpty else { throw .contactIncomplete(missing) }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 40 else { throw .emptyText }
        return ContactRedactor.redactWorkStatus(ContactRedactor.redact(cleaned, header: header))
    }

    /// Plain text from a resume PDF, paragraphs kept and blank-line runs dropped.
    public static func text(fromPDF data: Data) throws(ImportError) -> String {
        guard let document = PDFDocument(data: data), let raw = document.string else { throw .unreadablePDF }
        var kept: [String] = []
        for line in raw.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) })
        where !(line.isEmpty && (kept.last?.isEmpty ?? true)) {
            kept.append(line)
        }
        let text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .emptyText }
        return text
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
