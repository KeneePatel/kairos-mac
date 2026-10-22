import Foundation
import LLM

/// `suggestEvidence` (SPEC §5.5 catalog, added 2026-10-22 for Improve): for one thing several
/// postings ask for, which of your roles, projects or bullets might already show it, each as a
/// question for you to answer. It never writes a resume line: you decide what's true and write it.
/// Sent: the postings' wording and your screening profile, which carries no contact details,
/// work authorization or where you live.
public struct SuggestEvidenceTask: LLMTask {
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
                    .filter { !$0.isEmpty && seen.insert(TextScan.fold($0)).inserted }
                    .prefix(8))
            self.profile = profile
        }
    }

    public struct Output: Decodable, Sendable, Equatable {
        public struct Suggestion: Decodable, Sendable, Equatable {
            /// Profile ids: "x1", "p1b2".
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
                    .required("question", .string(maxLength: 240)),
                    .required("angle", .string(maxLength: 240)),
                ]), maxItems: 3)),
        .required("otherwise", .string(maxLength: 240)),
    ])

    public init() {}

    public func messages(for input: Input, budget: TokenBudget) -> [ChatMessage] {
        let instructions = PromptLibrary.instructions(for: Self.id, version: Self.promptVersion) ?? ""
        let data = """
            <asks>
            \(input.fix)
            \(input.asks.map { "- \($0)" }.joined(separator: "\n"))
            </asks>
            <profile>
            \(input.profile.text)
            </profile>
            """
        return [.system(instructions), .user(data)]
    }

    /// Each suggestion cites ids that are in your profile and asks a question; with none, there's
    /// a way to show it instead. Nothing echoes the redaction marker.
    public func check(_ output: Output, for input: Input) throws {
        if output.suggestions.isEmpty, output.otherwise.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LLMError.invalidOutput("give a suggestion, or say in “otherwise” how to show it")
        }
        for suggestion in output.suggestions {
            if suggestion.evidence.isEmpty { throw LLMError.invalidOutput("a suggestion cites no evidence id") }
            for id in suggestion.evidence where input.profile.describe(id) == nil {
                throw LLMError.invalidOutput("\(id) isn't in the profile")
            }
            let question = suggestion.question.trimmingCharacters(in: .whitespaces)
            if !question.hasSuffix("?") {
                throw LLMError.invalidOutput("“\(question.prefix(40))” isn't a question")
            }
            if suggestion.angle.trimmingCharacters(in: .whitespaces).isEmpty {
                throw LLMError.invalidOutput("a suggestion has no angle")
            }
        }
        let texts = output.suggestions.flatMap { [$0.question, $0.angle] } + [output.otherwise]
        if texts.contains(where: { $0.contains("[removed]") }) {
            throw LLMError.invalidOutput("don't repeat “[removed]”: contact details stay out")
        }
    }
}
