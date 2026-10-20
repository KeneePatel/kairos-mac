import Foundation
import LLM
import MasterResume
import Store

/// What `analyzeJob` found in one posting (SPEC §5.2, step 5): each requirement, what kind it is,
/// and whether your master resume shows it, plus the facts the verdict needs. Stored in
/// `job_analysis`.
public struct JobAnalysis: Codable, Sendable, Equatable {
    public struct Requirement: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable, CaseIterable { case must, nice }

        /// What a requirement is about. Only skills, experience, education and languages count
        /// toward a verdict: soft skills are never judged, location, authorization and
        /// availability are taken as met (your decision, 2026-10-20) or left to the prefilter, and
        /// enrolment (being a student now) is judged against your work profile.
        public enum Category: String, Codable, Sendable, CaseIterable {
            case skill, experience, education, location, authorization, language, availability, enrolment, soft

            public var counts: Bool { [.skill, .experience, .education, .language].contains(self) }
        }

        public enum Match: String, Codable, Sendable, CaseIterable {
            case yes, partial, no
            case notJudged = "not_judged"

            /// A yes is worth 1, a partial ½.
            public var credit: Double {
                switch self {
                case .yes: 1
                case .partial: 0.5
                case .no, .notJudged: 0
                }
            }
        }

        public var text: String
        public var kind: Kind
        /// Prompt v1 only: your skill or language that covers it, spelled as in your master resume.
        public var matchedSkill: String?
        /// Prompt v2 on.
        public var category: Category?
        public var match: Match?
        /// Ids from the screening profile that show it ("s4", "x1b2"): see `ScreeningProfile.describe`.
        public var evidence: [String]?

        public init(
            text: String, kind: Kind, matchedSkill: String? = nil, category: Category? = nil, match: Match? = nil,
            evidence: [String]? = nil
        ) {
            self.text = text
            self.kind = kind
            self.matchedSkill = matchedSkill
            self.category = category
            self.match = match
            self.evidence = evidence
        }

        /// v2's match, or for a v1 analysis: matched to a skill or not.
        public var effectiveMatch: Match { match ?? (matchedSkill != nil ? .yes : .no) }

        /// Whether it counts toward the verdict. A v1 analysis has no categories, so its conditions
        /// are told apart by keyword as they always were.
        public var counts: Bool { category.map(\.counts) ?? !Coverage.isCondition(text) }
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
    /// A requirement code judges is never left "not judged", and evidence that's only a Can-discuss
    /// skill is a partial match at most.
    public init(_ output: AnalyzeJobTask.Output, input: AnalyzeJobTask.Input) {
        let yours = Dictionary(
            input.matchable.map { (AnalyzeJobTask.key($0), $0) }, uniquingKeysWith: { first, _ in first })
        requirements = output.requirements.map { requirement in
            var match = requirement.match
            let evidence = requirement.evidence?.filter { input.profile.describe($0) != nil }
            if let category = requirement.category, category.counts, match == .notJudged { match = .no }
            if match == .yes, let evidence, !evidence.isEmpty, evidence.allSatisfy(input.profile.isCanDiscuss) {
                match = .partial
            }
            return Requirement(
                text: requirement.text.trimmingCharacters(in: .whitespacesAndNewlines), kind: requirement.kind,
                matchedSkill: requirement.matchedSkill.flatMap { yours[AnalyzeJobTask.key($0)] },
                category: requirement.category, match: match, evidence: evidence)
        }
        yearsRequired = output.yearsRequired
        seniority = Seniority(rawValue: output.seniority)
        domains = output.domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        flags = output.flags
    }

    /// Must-haves your master resume shows.
    public var coveredMusts: Int { requirements.filter { $0.kind == .must && $0.effectiveMatch == .yes }.count }
}

/// `analyzeJob` (SPEC §5.5 catalog): once per job that passes the prefilter.
public struct AnalyzeJobTask: LLMTask {
    /// Exactly what's sent (SPEC §5.5, "Least context", as changed 2026-10-20): the posting, and
    /// your master resume as a screening profile: skills, degrees, languages, roles, projects and
    /// bullets, with contact details redacted. Never work authorization, clearance or where you live.
    public struct Input: Sendable, Equatable {
        public let title: String
        public let company: String
        public let location: String
        public let description: String
        public let profile: ScreeningProfile

        public init(job: Job, profile: ScreeningProfile) {
            title = job.title
            company = job.company
            location = job.location
            description = job.descriptionMarkdown ?? ""
            self.profile = profile
        }

        /// Skill names and languages only, with no resume behind them.
        public init(job: Job, skills: [Skill], languages: [EntryFields.Language]) {
            self.init(job: job, profile: ScreeningProfile(skills: skills, languages: languages))
        }

        /// What a v1 `matched_skill` may name.
        var matchable: [String] { profile.names }
    }

    public struct Output: Decodable, Sendable, Equatable {
        /// v2 fields; a v1 reply has `matched_skill` instead.
        public var requirements: [JobAnalysis.Requirement]
        public var yearsRequired: Int?
        /// A `Seniority` raw value, or "unspecified".
        public var seniority: String
        public var domains: [String]
        public var flags: JobAnalysis.Flags
    }

    public static let id = TaskID.analyzeJob
    public static let promptVersion = 2
    public static let outputSchema = JSONSchema.object([
        .required(
            "requirements",
            .array(
                of: .object([
                    .required("text", .string(maxLength: 200)),
                    .required("kind", .enumeration(JobAnalysis.Requirement.Kind.allCases.map(\.rawValue))),
                    .required("category", .enumeration(JobAnalysis.Requirement.Category.allCases.map(\.rawValue))),
                    .required("match", .enumeration(JobAnalysis.Requirement.Match.allCases.map(\.rawValue))),
                    .optional("evidence", .array(of: .string(maxLength: 12), maxItems: 4)),
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
        let profile = input.profile.text
        let header = "Title: \(input.title)\nCompany: \(input.company)\nLocation: \(input.location)\n\n"
        // The posting gets what's left of the input budget (characters ÷ 4), with a little headroom.
        let used = TokenBudget.estimate(instructions + profile + header) + 100
        let posting = PostingCleaner.clean(input.description, limit: max(0, (budget.input - used) * 4))
        let data = """
            <profile>
            \(profile)
            </profile>
            <job_posting>
            \(header)\(posting)
            </job_posting>
            """
        return [.system(instructions), .user(data)]
    }

    /// Rules the schema can't express: no blank requirement, the title isn't one, every evidence id
    /// is in the profile, a yes or partial cites some, and a v1 matched skill is really one of yours.
    public func check(_ output: Output, for input: Input) throws {
        let yours = Set(input.matchable.map(Self.key))
        let title = Self.key(input.title)
        var problems: [String] = []
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
            let evidence = requirement.evidence ?? []
            for id in evidence where input.profile.describe(id) == nil {
                problems.append("“\(requirement.text.prefix(40))” cites \(id), which isn't in the profile.")
            }
            if [.yes, .partial].contains(requirement.match), evidence.isEmpty {
                problems.append(
                    "“\(requirement.text.prefix(40))” is \(requirement.match?.rawValue ?? "") but cites no evidence id."
                )
            }
        }
        if !problems.isEmpty { throw LLMError.invalidOutput(problems.prefix(6).joined(separator: " ")) }
    }

    /// Folded and trimmed, for comparing names.
    static func key(_ text: String) -> String {
        TextScan.fold(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
