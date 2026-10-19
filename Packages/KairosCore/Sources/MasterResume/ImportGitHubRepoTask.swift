import Foundation
import LLM

/// `importGitHubRepo` (SPEC §5.5 catalog): drafts one project entry from a repo's name, languages and
/// README excerpt. Dates and the repo link come from GitHub itself, so the model can't get them wrong.
public struct ImportGitHubRepoTask: LLMTask {
    /// What's sent. Contact details are removed from the description and README first.
    public struct Input: Sendable, Equatable {
        public let name: String
        public let description: String
        public let languages: [String]
        public let topics: [String]
        public let readme: String

        public static let readmeLimit = 6_000

        public init(repo: GitHubRepo, languages: [String], readme: String?, header: ResumeHeader) {
            name = repo.name
            description = ContactRedactor.redact(repo.description ?? "", header: header)
            self.languages = Array(languages.prefix(8))
            topics = repo.topics ?? []
            self.readme = ContactRedactor.redact(String((readme ?? "").prefix(Self.readmeLimit)), header: header)
        }
    }

    public struct Output: Decodable, Sendable, Equatable {
        public var name: String
        public var role: String?
        public var tech: [String]
        public var bullets: [String]
    }

    public static let id = TaskID.importGitHubRepo
    public static let promptVersion = 1
    public static let outputSchema = JSONSchema.object([
        .required("name", .string(maxLength: 120)),
        .optional("role", .string(maxLength: 80)),
        .required("tech", .array(of: .string(maxLength: 40), maxItems: 12)),
        .required("bullets", .array(of: .string(maxLength: 300), maxItems: 4)),
    ])

    public init() {}

    public func messages(for input: Input, budget: TokenBudget) -> [ChatMessage] {
        let instructions = PromptLibrary.instructions(for: Self.id, version: Self.promptVersion) ?? ""
        let data = """
            <repo>
            name: \(input.name)
            description: \(input.description)
            languages: \(input.languages.joined(separator: ", "))
            topics: \(input.topics.joined(separator: ", "))
            </repo>
            <readme>
            \(input.readme)
            </readme>
            """
        return [.system(instructions), .user(data)]
    }

    public func check(_ output: Output, for input: Input) throws {
        if output.name.trimmed.isEmpty { throw LLMError.invalidOutput("the project has no name") }
        let reply = ([output.name, output.role ?? ""] + output.bullets).joined(separator: "\n")
        if ContactRedactor.redact(reply, header: ResumeHeader()) != reply {
            throw LLMError.invalidOutput("the reply contains contact details, which must be left out")
        }
    }

    /// A project entry: the model's words, GitHub's dates and link. A repo pushed in the last three
    /// months counts as current.
    public static func entry(from output: Output, repo: GitHubRepo, now: Date = Date()) -> ResumeEntry {
        let start = YearMonth.containing(repo.createdAt)
        let pushed = repo.pushedAt.map { YearMonth.containing($0) }
        let current = pushed.map { $0.months(until: YearMonth.containing(now)) <= 3 } ?? false
        return ResumeEntry(
            fields: .project(
                .init(
                    name: output.name.trimmed, role: output.role?.trimmed ?? "", tech: output.tech.map(\.trimmed),
                    repoURL: repo.htmlUrl.absoluteString)),
            start: start, end: current ? nil : pushed, isCurrent: current,
            bullets: output.bullets.map(\.trimmed).filter { !$0.isEmpty }.map { ResumeBullet(text: $0) })
    }
}
