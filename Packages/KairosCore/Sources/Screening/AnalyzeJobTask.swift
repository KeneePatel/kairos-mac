import Foundation
import LLM
import MasterResume
import Store

/// What `analyzeJob` found in one posting (SPEC §5.2, step 5): the requirements and which of your
/// skills covers each, plus the facts the verdict needs. Stored in `job_analysis`.
public struct JobAnalysis: Codable, Sendable, Equatable {
    public struct Requirement: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, CaseIterable { case must, nice }

        public var text: String
        public var kind: Kind
        /// Your skill or language that covers it, spelled as in your master resume.
        public var matchedSkill: String?

        public init(text: String, kind: Kind, matchedSkill: String? = nil) {
            self.text = text
            self.kind = kind
            self.matchedSkill = matchedSkill
        }
    }

    /// What the posting says, not what it means for you: the verdict compares these with your profile.
    public struct Flags: Codable, Sendable, Equatable {
        public enum Sponsorship: String, Codable, Sendable, CaseIterable {
            case offered
            case notOffered = "not_offered"
            case notMentioned = "not_mentioned"
        }

        public enum Clearance: String, Codable, Sendable, CaseIterable {
            case required, obtainable
            case notMentioned = "not_mentioned"
        }

        public enum French: String, Codable, Sendable, CaseIterable {
            case required, asset
            case notMentioned = "not_mentioned"
        }

        public var sponsorship: Sponsorship
        public var clearance: Clearance
        public var french: French
        public var remoteScope: RemoteScope

        public init(sponsorship: Sponsorship, clearance: Clearance, french: French, remoteScope: RemoteScope) {
            self.sponsorship = sponsorship
            self.clearance = clearance
            self.french = french
            self.remoteScope = remoteScope
        }
    }

    public var requirements: [Requirement]
    public var yearsRequired: Int?
    /// Nil when the posting names no level.
    public var seniority: Seniority?
    public var domains: [String]
    public var flags: Flags

    public init(
        requirements: [Requirement], yearsRequired: Int?, seniority: Seniority?, domains: [String], flags: Flags
    ) {
        self.requirements = requirements
        self.yearsRequired = yearsRequired
        self.seniority = seniority
        self.domains = domains
        self.flags = flags
    }

    /// The analysis in your words: matched skills spelled as you spell them, empty matches dropped.
    public init(_ output: AnalyzeJobTask.Output, input: AnalyzeJobTask.Input) {
        let yours = Dictionary(
            input.matchable.map { (AnalyzeJobTask.key($0), $0) }, uniquingKeysWith: { first, _ in first })
        requirements = output.requirements.map { requirement in
            Requirement(
                text: requirement.text.trimmingCharacters(in: .whitespacesAndNewlines), kind: requirement.kind,
                matchedSkill: requirement.matchedSkill.flatMap { yours[AnalyzeJobTask.key($0)] })
        }
        yearsRequired = output.yearsRequired
        seniority = Seniority(rawValue: output.seniority)
        domains = output.domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        flags = output.flags
    }

    /// Must-haves one of your skills covers.
    public var coveredMusts: Int { requirements.filter { $0.kind == .must && $0.matchedSkill != nil }.count }
}

/// `analyzeJob` (SPEC §5.5 catalog): once per job that passes the prefilter.
public struct AnalyzeJobTask: LLMTask {
    /// Exactly what's sent (SPEC §5.5, "Least context"): the posting, and the names of your skills
    /// and languages. Nothing else from your master resume, and never contact details.
    public struct Input: Sendable, Equatable {
        public let title: String
        public let company: String
        public let location: String
        public let description: String
        public let skills: [String]
        public let languages: [EntryFields.Language]

        public init(job: Job, skills: [Skill], languages: [EntryFields.Language]) {
            title = job.title
            company = job.company
            location = job.location
            description = job.descriptionMarkdown ?? ""
            self.skills = skills.map(\.name)
            self.languages = languages
        }

        /// What a requirement may be matched to.
        var matchable: [String] { skills + languages.map(\.language) }
    }

    public struct Output: Decodable, Sendable, Equatable {
        public var requirements: [JobAnalysis.Requirement]
        public var yearsRequired: Int?
        /// A `Seniority` raw value, or "unspecified".
        public var seniority: String
        public var domains: [String]
        public var flags: JobAnalysis.Flags
    }

    public static let id = TaskID.analyzeJob
    public static let promptVersion = 1
    public static let outputSchema = JSONSchema.object([
        .required(
            "requirements",
            .array(
                of: .object([
                    .required("text", .string(maxLength: 160)),
                    .required("kind", .enumeration(JobAnalysis.Requirement.Kind.allCases.map(\.rawValue))),
                    .optional("matched_skill", .string(maxLength: 80)),
                ]), maxItems: 30)),
        .optional("years_required", .integer(minimum: 0, maximum: 30)),
        .required("seniority", .enumeration(Seniority.allCases.map(\.rawValue) + ["unspecified"])),
        .required("domains", .array(of: .string(maxLength: 40), maxItems: 6)),
        .required(
            "flags",
            .object([
                .required("sponsorship", .enumeration(JobAnalysis.Flags.Sponsorship.allCases.map(\.rawValue))),
                .required("clearance", .enumeration(JobAnalysis.Flags.Clearance.allCases.map(\.rawValue))),
                .required("french", .enumeration(JobAnalysis.Flags.French.allCases.map(\.rawValue))),
                .required("remote_scope", .enumeration(RemoteScope.allCases.map(\.rawValue))),
            ])),
    ])

    public init() {}

    public func messages(for input: Input, budget: TokenBudget) -> [ChatMessage] {
        let instructions = PromptLibrary.instructions(for: Self.id, version: Self.promptVersion) ?? ""
        let skills = input.skills.joined(separator: ", ")
        let languages = input.languages.map { "\($0.language) (\($0.proficiency.rawValue))" }.joined(separator: ", ")
        let header = "Title: \(input.title)\nCompany: \(input.company)\nLocation: \(input.location)\n\n"
        // The posting gets what's left of the input budget (characters ÷ 4), with a little headroom.
        let used = TokenBudget.estimate(instructions + skills + languages + header) + 100
        let posting = PostingCleaner.clean(input.description, limit: max(0, (budget.input - used) * 4))
        let data = """
            <skills>
            \(skills)
            </skills>
            <languages>
            \(languages)
            </languages>
            <job_posting>
            \(header)\(posting)
            </job_posting>
            """
        return [.system(instructions), .user(data)]
    }

    /// Rules the schema can't express: no blank requirement, the title isn't one, and a matched skill
    /// is really one of yours.
    public func check(_ output: Output, for input: Input) throws {
        let yours = Set(input.matchable.map(Self.key))
        let title = Self.key(input.title)
        for requirement in output.requirements {
            let text = Self.key(requirement.text)
            if text.isEmpty { throw LLMError.invalidOutput("a requirement is blank") }
            if text == title {
                throw LLMError.invalidOutput("“\(requirement.text)”: the job title isn't a requirement")
            }
            if let skill = requirement.matchedSkill, !Self.key(skill).isEmpty, !yours.contains(Self.key(skill)) {
                throw LLMError.invalidOutput(
                    "“\(skill)” isn't one of your skills; leave matched_skill out when none of them covers it")
            }
        }
    }

    /// Folded and trimmed, for comparing names.
    static func key(_ text: String) -> String {
        TextScan.fold(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
