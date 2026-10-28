import AI
import Foundation
import KairosKit

/// One of your public repositories, as GitHub's REST API describes it.
public struct GitHubRepo: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let fullName: String
    public let description: String?
    public let language: String?
    public let fork: Bool
    public let archived: Bool
    public let stargazersCount: Int
    public let htmlUrl: URL
    public let createdAt: Date
    public let pushedAt: Date?
    public let topics: [String]?

    public var id: String { fullName }
}

public enum GitHubError: Error, Equatable, Sendable {
    case noProfile
    case userNotFound(String)
    /// 60 requests an hour without a token.
    case rateLimited
    case tokenRejected
    case http(Int)
    case network(String)

    public var message: String {
        switch self {
        case .noProfile: "Add your GitHub profile link to your master resume first."
        case .userNotFound(let user): "GitHub has no user \(user)."
        case .rateLimited: "GitHub's hourly limit is used up. Add a token in Settings, or try again later."
        case .tokenRejected: "GitHub didn't accept the token."
        case .http(let status): "GitHub answered with an error (HTTP \(status))."
        case .network(let detail): "GitHub couldn't be reached: \(detail)"
        }
    }
}

/// Reads public repositories through GitHub's REST API. A token is optional; without one GitHub
/// allows 60 requests an hour, enough for a listing and a few READMEs.
public struct GitHubClient: Sendable {
    let token: String?
    let http: any HTTPClient

    public init(token: String?, http: any HTTPClient) {
        self.token = token?.isEmpty == false ? token : nil
        self.http = http
    }

    /// "https://github.com/jrivera" → "jrivera".
    public static func user(fromProfile url: String?) -> String? {
        guard let url, let profile = Validator.gitHubProfile(url) else { return nil }
        return String(profile.dropFirst("https://github.com/".count))
    }

    /// Your own repositories, most recently pushed first, forks and archived ones last.
    public func repos(of user: String) async throws(GitHubError) -> [GitHubRepo] {
        let data = try await get("users/\(user)/repos?per_page=100&sort=pushed&type=owner", user: user)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        guard let repos = try? decoder.decode([GitHubRepo].self, from: data) else { throw .http(200) }
        return repos.filter { !$0.fork && !$0.archived } + repos.filter { $0.fork || $0.archived }
    }

    /// Languages by size, largest first.
    public func languages(of repo: GitHubRepo) async throws(GitHubError) -> [String] {
        let data = try await get("repos/\(repo.fullName)/languages", user: nil)
        guard let bytes = try? JSONDecoder().decode([String: Int].self, from: data) else { return [] }
        return bytes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The README's text, or nil when there is none.
    public func readme(of repo: GitHubRepo) async throws(GitHubError) -> String? {
        do {
            let data = try await get("repos/\(repo.fullName)/readme", user: nil, accept: "application/vnd.github.raw")
            return String(decoding: data, as: UTF8.self)
        } catch .userNotFound {
            return nil
        }
    }

    private func get(_ path: String, user: String?, accept: String = "application/vnd.github+json")
        async throws(GitHubError) -> Data
    {
        guard let url = URL(string: "https://api.github.com/" + path) else { throw .http(0) }
        var headers = ["Accept": accept, "X-GitHub-Api-Version": "2022-11-28"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, headers: headers))
        } catch {
            throw .network("\(error)")
        }
        switch response.status {
        case 200: return response.body
        case 401: throw .tokenRejected
        case 403 where response.header("x-ratelimit-remaining") == "0", 429: throw .rateLimited
        case 404: throw .userNotFound(user ?? path)
        default: throw .http(response.status)
        }
    }
}

/// `importGitHubRepo`: drafts one project entry from a repository's name, languages and README.
/// Dates and the link come from GitHub itself, so the model can't get them wrong.
public struct ImportGitHubRepoTask: AITask {
    /// What's sent: contact details removed from the description and README first.
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
            self.readme = ContactRedactor.redactWorkStatus(
                ContactRedactor.redact(String((readme ?? "").prefix(Self.readmeLimit)), header: header))
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
        .required("name", .string(maxLength: 120)), .optional("role", .string(maxLength: 80)),
        .required("tech", .array(of: .string(maxLength: 40), maxItems: 12)),
        .required("bullets", .array(of: .string(maxLength: 300), maxItems: 4)),
    ])

    public init() {}

    public func messages(for input: Input, budget: TokenBudget) -> [ChatMessage] {
        let repo = """
            name: \(input.name)
            description: \(input.description)
            languages: \(input.languages.joined(separator: ", "))
            topics: \(input.topics.joined(separator: ", "))
            """
        return [
            .system(Prompts.text(Self.id, version: Self.promptVersion, in: .module)),
            .user(Prompts.block("repo", repo) + "\n" + Prompts.block("readme", input.readme)),
        ]
    }

    public func check(_ output: Output, for input: Input) throws(AIError) {
        if output.name.tidied.isEmpty { throw .invalidOutput("the project has no name") }
        if ContactRedactor.containsContactDetails(
            ([output.name, output.role ?? ""] + output.bullets).joined(separator: "\n"))
        {
            throw .invalidOutput("the reply contains contact details, which must be left out")
        }
    }

    /// A project entry: the model's words, GitHub's dates and link. A repository pushed in the last
    /// three months counts as current.
    public static func entry(from output: Output, repo: GitHubRepo, now: Date = Date()) -> ResumeEntry {
        let start = YearMonth.containing(repo.createdAt)
        let pushed = repo.pushedAt.map { YearMonth.containing($0) }
        let current = pushed.map { $0.months(until: YearMonth.containing(now)) <= 3 } ?? false
        return ResumeEntry(
            fields: .project(
                .init(
                    name: output.name.tidied, role: output.role?.tidied ?? "", tech: output.tech.map(\.tidied),
                    repoURL: repo.htmlUrl.absoluteString)),
            start: start, end: current ? nil : pushed, isCurrent: current,
            bullets: output.bullets.map(\.tidied).filter { !$0.isEmpty }.map { ResumeBullet(text: $0) })
    }
}
