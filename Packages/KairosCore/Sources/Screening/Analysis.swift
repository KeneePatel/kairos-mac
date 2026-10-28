import AI
import Foundation
import Jobs
import KairosKit
import Resume

/// What `analyzeJob` found in one posting: each requirement, what kind it is, and whether your
/// master resume shows it, plus the facts the verdict needs. Its JSON is the first Kairos's, so
/// stored analyses carry over without spending AI calls again.
public struct JobAnalysis: Codable, Sendable, Equatable {
    public struct Requirement: Codable, Sendable, Equatable, Hashable {
        public enum Kind: String, Codable, Sendable, CaseIterable { case must, nice }

        /// What a requirement is about. Only skills, experience, education and languages count
        /// toward a verdict: soft skills are never judged; location, authorization and availability
        /// are taken as met (Kenee's decision, 2026-10-20) or left to the prefilter; enrolment is
        /// judged against your work profile.
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
        /// The first prompt's field: your skill or language that covers it.
        public var matchedSkill: String?
        public var category: Category?
        public var match: Match?
        /// Ids from the screening profile that show it ("s4", "x1b2").
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

        public var effectiveMatch: Match { match ?? (matchedSkill != nil ? .yes : .no) }

        /// Whether it counts toward the verdict. An analysis from the first prompt has no
        /// categories, so its conditions are told apart by keyword.
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

        public init(
            sponsorship: Sponsorship = .notMentioned, clearance: Clearance = .notMentioned, french: French = .notMentioned,
            remoteScope: RemoteScope = .unknown
        ) {
            self.sponsorship = sponsorship
            self.clearance = clearance
            self.french = french
            self.remoteScope = remoteScope
        }
    }

    public var requirements: [Requirement]
    public var yearsRequired: Int?
    public var seniority: Seniority?
    public var domains: [String]
    public var flags: Flags

    public init(
        requirements: [Requirement], yearsRequired: Int? = nil, seniority: Seniority? = nil, domains: [String] = [],
        flags: Flags = Flags()
    ) {
        self.requirements = requirements
        self.yearsRequired = yearsRequired
        self.seniority = seniority
        self.domains = domains
        self.flags = flags
    }

    /// The analysis in your words: unknown evidence ids dropped, a requirement code judges never
    /// left "not judged", and evidence that's only a Can-discuss skill a partial match at most.
    public init(_ output: AnalyzeJobTask.Output, input: AnalyzeJobTask.Input) {
        requirements = output.requirements.map { requirement in
            var match = requirement.match
            let evidence = requirement.evidence?.filter { input.profile.describe($0) != nil }
            if let category = requirement.category, category.counts, match == .notJudged { match = .no }
            if match == .yes, let evidence, !evidence.isEmpty, evidence.allSatisfy(input.profile.isCanDiscuss) {
                match = .partial
            }
            return Requirement(
                text: requirement.text.trimmingCharacters(in: .whitespacesAndNewlines), kind: requirement.kind,
                category: requirement.category, match: match, evidence: evidence)
        }
        yearsRequired = output.yearsRequired
        seniority = Seniority(rawValue: output.seniority)
        domains = output.domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        flags = output.flags
    }

    /// The analysis with each language requirement you meet counted as shown, citing your language
    /// ("l2"). The model sometimes marks one missing that your master resume lists ("English",
    /// 2026-10-22). Basic level doesn't count, nor does a requirement that also asks for French or to
    /// be bilingual when you don't speak French: the model and the French flag judge those.
    public func recognizingLanguages(_ languages: [EntryFields.Language]) -> JobAnalysis {
        let spoken = languages.enumerated().filter { $0.element.proficiency != .basic }.map { index, language in
            (id: "l\(index + 1)", name: TextScan.fold(language.language).trimmingCharacters(in: .whitespaces))
        }.filter { !$0.name.isEmpty }
        guard !spoken.isEmpty else { return self }
        let french = Prefilter.speaksFrench(languages)
        var recognised = self
        recognised.requirements = requirements.map { requirement in
            let text = TextScan.fold(requirement.text)
            guard requirement.category == .language, requirement.effectiveMatch != .yes,
                french || !TextScan.containsAny(text, ["french", "francais", "bilingual"]),
                let language = spoken.first(where: { TextScan.containsPhrase(text, $0.name) })
            else { return requirement }
            var shown = requirement
            shown.match = .yes
            shown.evidence = [language.id]
            return shown
        }
        return recognised
    }
}

/// `analyzeJob`: once per job that passes the prefilter.
public struct AnalyzeJobTask: AITask {
    /// Exactly what's sent: the posting, and your master resume as a screening profile with contact
    /// details redacted. Never work authorization, clearance or where you live.
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
            description = job.description
            self.profile = profile
        }
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
    /// Version 2 is the prompt the first Kairos evaluated (Flash-Lite 100/100/100 over 150 bullets,
    /// 2026-10-20) and stored analyses carry, so they still count as current.
    public static let promptVersion = 2
    /// The most requirements a reply may list; the task's output limit is sized to hold them.
    public static let maxRequirements = 30
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
                ]), maxItems: maxRequirements)),
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
        let instructions = Prompts.text(Self.id, version: Self.promptVersion, in: .module)
        let profile = input.profile.text
        let header = "Title: \(input.title)\nCompany: \(input.company)\nLocation: \(input.location)\n\n"
        // The posting gets what's left of the input budget, with a little headroom.
        let posting = PostingCleaner.clean(
            input.description, limit: budget.characters(after: instructions.count + profile.count + header.count + 400))
        return [.system(instructions), .user(Prompts.block("profile", profile) + "\n" + Prompts.block("job_posting", header + posting))]
    }

    /// No blank requirement, the title isn't one, every evidence id is in the profile, and a yes or
    /// partial cites some.
    public func check(_ output: Output, for input: Input) throws(AIError) {
        let title = Self.key(input.title)
        var problems: [String] = []
        for requirement in output.requirements {
            let text = Self.key(requirement.text)
            if text.isEmpty { throw .invalidOutput("a requirement is blank") }
            if text == title { throw .invalidOutput("“\(requirement.text)”: the job title isn't a requirement") }
            let evidence = requirement.evidence ?? []
            for id in evidence where input.profile.describe(id) == nil {
                problems.append("“\(requirement.text.prefix(40))” cites \(id), which isn't in the profile.")
            }
            if [.yes, .partial].contains(requirement.match), evidence.isEmpty {
                problems.append("“\(requirement.text.prefix(40))” is \(requirement.match?.rawValue ?? "") but cites no evidence id.")
            }
        }
        if !problems.isEmpty { throw .invalidOutput(problems.prefix(6).joined(separator: " ")) }
    }

    static func key(_ text: String) -> String {
        TextScan.fold(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `suggestEvidence`, for Improve: for one thing several postings ask for, which of your roles,
/// projects or bullets might already show it, each as a question for you to answer. It never
/// writes a resume line: you decide what's true and write it.
public struct SuggestEvidenceTask: AITask {
    public struct Input: Sendable, Equatable {
        /// What the postings want, in a few words: "Observability".
        public let fix: String
        /// Each posting's own wording, once each, at most 8.
        public let asks: [String]
        public let profile: ScreeningProfile

        public init(fix: String, asks: [String], profile: ScreeningProfile) {
            self.fix = fix
            var seen: Set<String> = []
            self.asks = Array(
                asks.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }
                    .filter { !$0.isEmpty && seen.insert(TextScan.fold($0)).inserted }.prefix(8))
            self.profile = profile
        }
    }

    public struct Output: Decodable, Sendable, Equatable {
        public struct Suggestion: Decodable, Sendable, Equatable {
            public let evidence: [String]
            public let question: String
            /// What a bullet could show if the answer is yes.
            public let angle: String
        }

        public let suggestions: [Suggestion]
        /// When nothing fits: how to show it with something new.
        public let otherwise: String
    }

    public static let id = TaskID.suggestEvidence
    public static let promptVersion = 1
    public static let outputSchema = JSONSchema.object([
        .required(
            "suggestions",
            .array(
                of: .object([
                    .required("evidence", .array(of: .string(maxLength: 12), maxItems: 3)),
                    .required("question", .string(maxLength: 240)), .required("angle", .string(maxLength: 240)),
                ]), maxItems: 3)),
        .required("otherwise", .string(maxLength: 240)),
    ])

    public init() {}

    public func messages(for input: Input, budget: TokenBudget) -> [ChatMessage] {
        let asks = input.fix + "\n" + input.asks.map { "- \($0)" }.joined(separator: "\n")
        return [
            .system(Prompts.text(Self.id, version: Self.promptVersion, in: .module)),
            .user(Prompts.block("asks", asks) + "\n" + Prompts.block("profile", input.profile.text)),
        ]
    }

    public func check(_ output: Output, for input: Input) throws(AIError) {
        if output.suggestions.isEmpty, output.otherwise.trimmingCharacters(in: .whitespaces).isEmpty {
            throw .invalidOutput("give a suggestion, or say in “otherwise” how to show it")
        }
        for suggestion in output.suggestions {
            if suggestion.evidence.isEmpty { throw .invalidOutput("a suggestion cites no evidence id") }
            for id in suggestion.evidence where input.profile.describe(id) == nil {
                throw .invalidOutput("\(id) isn't in the profile")
            }
            let question = suggestion.question.trimmingCharacters(in: .whitespaces)
            if !question.hasSuffix("?") { throw .invalidOutput("“\(question.prefix(40))” isn't a question") }
            if suggestion.angle.trimmingCharacters(in: .whitespaces).isEmpty { throw .invalidOutput("a suggestion has no angle") }
        }
        let texts = output.suggestions.flatMap { [$0.question, $0.angle] } + [output.otherwise]
        if texts.contains(where: { $0.contains(ContactRedactor.marker) }) {
            throw .invalidOutput("don't repeat “[removed]”: contact details stay out")
        }
    }
}
