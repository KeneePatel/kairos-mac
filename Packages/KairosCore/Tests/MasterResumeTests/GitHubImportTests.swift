import Foundation
import LLM
import Synchronization
import Testing

@testable import MasterResume

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/github")

private func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appending(path: name)) }

/// Answers GitHub requests from the recorded fixtures and records them; anything else is a 404.
private final class FakeGitHub: Sendable {
    let sent = Mutex<[URLRequest]>([])
    let status: Int
    let headers: [String: String]

    init(status: Int = 200, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
    }

    var send: GitHubClient.Send {
        { [self] request in
            sent.withLock { $0.append(request) }
            let path = request.url?.path() ?? ""
            let body: Data
            var code = status
            switch path {
            case "/users/jrivera/repos": body = try fixture("repos.json")
            case "/repos/jrivera/dockyard/languages": body = Data(#"{"Shell":120,"Go":48210,"Makefile":300}"#.utf8)
            case "/repos/jrivera/dockyard/readme": body = try fixture("readme.md")
            default:
                body = Data(#"{"message":"Not Found"}"#.utf8)
                code = 404
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        }
    }
}

private func jordan() -> ResumeHeader {
    var header = ResumeHeader()
    header.fullName = "Jordan Rivera"
    header.email = "jordan.rivera@example.com"
    header.portfolioURL = "https://jordanrivera.dev"
    header.gitHubURL = "https://github.com/jrivera"
    return header
}

@Suite("GitHub import")
struct GitHubImportTests {
    @Test func findsTheUserFromTheProfileURL() {
        #expect(GitHubClient.user(fromProfile: "github.com/jrivera/") == "jrivera")
        #expect(GitHubClient.user(fromProfile: "https://github.com/jrivera/dockyard") == nil)
        #expect(GitHubClient.user(fromProfile: nil) == nil)
    }

    @Test func listsOwnReposFirstThenForksAndArchived() async throws {
        let github = FakeGitHub()
        let repos = try await GitHubClient(token: nil, send: github.send).repos(of: "jrivera")
        #expect(repos.map(\.name) == ["dockyard", "freightline", "old-fork", "tidewatch"])
        let request = try #require(github.sent.withLock { $0.first })
        #expect(request.url?.query()?.contains("sort=pushed") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Kairos") == true)
    }

    @Test func aTokenIsSentWhenThereIsOne() async throws {
        let github = FakeGitHub()
        _ = try await GitHubClient(token: "ghp_test", send: github.send).repos(of: "jrivera")
        #expect(github.sent.withLock { $0.first?.value(forHTTPHeaderField: "Authorization") } == "Bearer ghp_test")
    }

    @Test func readsLanguagesLargestFirstAndTheReadme() async throws {
        let client = GitHubClient(token: nil, send: FakeGitHub().send)
        let dockyard = try #require(try await client.repos(of: "jrivera").first)
        #expect(try await client.languages(of: dockyard) == ["Go", "Makefile", "Shell"])
        #expect(try await client.readme(of: dockyard)?.hasPrefix("# Dockyard") == true)
        let freightline = try #require(try await client.repos(of: "jrivera").first { $0.name == "freightline" })
        #expect(try await client.readme(of: freightline) == nil)  // no README is fine
    }

    @Test(arguments: [
        (404, [String: String](), GitHubError.userNotFound("nobody")),
        (403, ["x-ratelimit-remaining": "0"], .rateLimited),
        (401, [:], .tokenRejected),
        (500, [:], .http(500)),
    ])
    func mapsGitHubErrors(status: Int, headers: [String: String], expected: GitHubError) async {
        let client = GitHubClient(token: nil, send: FakeGitHub(status: status, headers: headers).send)
        await #expect(throws: expected) { try await client.repos(of: status == 404 ? "nobody" : "jrivera") }
    }

    @Test func nothingPersonalFromTheReadmeIsSent() async throws {
        let client = GitHubClient(token: nil, send: FakeGitHub().send)
        let dockyard = try #require(try await client.repos(of: "jrivera").first)
        let input = ImportGitHubRepoTask.Input(
            repo: dockyard, languages: try await client.languages(of: dockyard),
            readme: try await client.readme(of: dockyard),
            header: jordan())
        let sent = ImportGitHubRepoTask().messages(for: input, budget: TokenBudget(input: 3_000, output: 600))
            .map(\.content).joined()
        for value in ["Jordan", "Rivera", "example.com", "jordanrivera.dev"] {
            #expect(!sent.localizedCaseInsensitiveContains(value), "\(value) would be sent")
        }
        #expect(sent.contains("dangling Docker images") && sent.contains("languages: Go, Makefile, Shell"))
        #expect(PromptLibrary.instructions(for: .importGitHubRepo, version: 1)?.contains("Never invent") == true)
    }

    @Test func aDraftTakesItsDatesAndLinkFromGitHub() async throws {
        let client = GitHubClient(token: nil, send: FakeGitHub().send)
        let repos = try await client.repos(of: "jrivera")
        let output = ImportGitHubRepoTask.Output(
            name: " Dockyard ", role: "Author", tech: ["Go", "Docker"],
            bullets: ["Finds and removes dangling images", " "])
        let now = try Date.ISO8601FormatStyle().parse("2025-10-19T12:00:00Z")
        let active = ImportGitHubRepoTask.entry(from: output, repo: repos[0], now: now)
        #expect(active.isCurrent && active.end == nil && active.start == YearMonth(year: 2023, month: 1))
        guard case .project(let project) = active.fields else { throw LLMError.invalidOutput("not a project") }
        #expect(project.name == "Dockyard" && project.repoURL == "https://github.com/jrivera/dockyard")
        #expect(active.bullets.map(\.text) == ["Finds and removes dangling images"])
        let stale = ImportGitHubRepoTask.entry(from: output, repo: repos[1], now: now)  // last pushed 2022-11
        #expect(!stale.isCurrent && stale.end == YearMonth(year: 2022, month: 11))
    }

    @Test func projectDraftsReviewLikeAnyImport() {
        let entry = ResumeEntry(fields: .project(.init(name: "Dockyard")))
        let draft = ImportDraft(entries: [entry])
        #expect(draft.entries == [entry] && draft.skills.isEmpty && draft.headline == nil && draft.totalYears == nil)
    }

    @Test func aReplyWithContactDetailsIsRefused() async throws {
        let bad = #"{"name":"Dockyard","tech":["Go"],"bullets":["Ask jordan.rivera@example.com"]}"#
        let fake = FakeProvider([.importGitHubRepo: [.reply(bad), .reply(bad)]])
        let client = LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 })
        let repo = try #require(try await GitHubClient(token: nil, send: FakeGitHub().send).repos(of: "jrivera").first)
        let input = ImportGitHubRepoTask.Input(repo: repo, languages: ["Go"], readme: nil, header: jordan())
        await #expect(throws: LLMError.self) {
            try await client.run(
                ImportGitHubRepoTask(), input: input,
                options: RunOptions(
                    model: "flash-lite", budget: TokenBudget(input: 3_000, output: 600), temperature: 0.2))
        }
        #expect(fake.requests.count == 2)
    }
}
