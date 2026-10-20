import Foundation
import LLM

/// A weak section to rewrite: the writer's input, the bullets it has now, and what to fix.
public struct RewriteSectionInput: Sendable {
    public let section: MatchScore.Section
    public let writer: WriteSectionInput
    public let current: [WrittenEntry]
    public let findings: [String]

    public init(section: MatchScore.Section, writer: WriteSectionInput, current: [WrittenEntry], findings: [String]) {
        self.section = section
        self.writer = writer
        self.current = current
        self.findings = findings
    }

    var tag: String { section == .projects ? "project" : "role" }
}

/// `rewriteSection` (SPEC §5.3): one pass over a section scoring under 70, with the score's
/// findings. Its reply passes the same checks as the writer's, the strict verifier included.
public struct RewriteSectionTask: LLMTask {
    public static let id = TaskID.rewriteSection
    public static let promptVersion = 1
    public static let outputSchema = SectionWriter.schema

    public init() {}

    public func messages(for input: RewriteSectionInput, budget: TokenBudget) -> [ChatMessage] {
        let base = SectionWriter.messages(Self.id, tag: input.tag, input: input.writer)
        let current = zip(input.writer.entryOrder, input.writer.entries).compactMap { short, selected -> String? in
            guard let entry = input.current.first(where: { $0.entryID == selected.entry.id }) else { return nil }
            let bullets = entry.bullets.map { bullet in
                let cites = bullet.sourceIDs.compactMap(input.writer.shortID).joined(separator: ", ")
                return "- \(bullet.text) (cites \(cites))"
            }
            return "<\(input.tag) id=\"\(short)\">\n\(bullets.joined(separator: "\n"))\n</\(input.tag)>"
        }
        let extra = """

            <current>
            \(current.joined(separator: "\n"))
            </current>
            <findings>
            \(input.findings.map { "- \($0)" }.joined(separator: "\n"))
            </findings>
            """
        return [base[0], .user(base[1].content + extra)]
    }

    public func check(_ output: SectionOutput, for input: RewriteSectionInput) throws {
        try SectionWriter.check(output, for: input.writer)
    }

    public static func written(_ output: SectionOutput, input: RewriteSectionInput) -> [WrittenEntry] {
        SectionWriter.written(output, input: input.writer)
    }
}
