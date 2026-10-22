import Foundation
import LLM
import MasterResume
import Store
import Testing

@testable import Screening

/// A new graduate's master resume (fictional).
private func resume() -> MasterResume {
    var header = ResumeHeader()
    header.fullName = "Sam Okafor"
    header.email = "sam.okafor@example.com"
    header.totalYears = 1
    return MasterResume(
        header: header,
        entries: [
            ResumeEntry(
                fields: .experience(.init(employer: "Harbour Labs", title: "Software Developer")),
                start: YearMonth(year: 2025, month: 1), isCurrent: true,
                bullets: [ResumeBullet(text: "Built Flask REST APIs backed by PostgreSQL for 3 internal tools.")]),
            ResumeEntry(
                fields: .project(.init(name: "Cluster Lab", tech: ["Kubernetes", "Prometheus"])),
                bullets: [ResumeBullet(text: "Deployed 2 Node.js services to GKE with Terraform.")]),
        ],
        skills: [Skill(name: "Python"), Skill(name: "Prometheus")])
}

private let input = SuggestEvidenceTask.Input(
    fix: "Observability",
    asks: [
        "Knowledge of DataDog or similar observability tools for monitoring and alerting",
        "Knowledge of DataDog or similar observability tools for monitoring and alerting",
        "Best practices around monitoring and observability",
    ], profile: ScreeningProfile(resume()))

private func output(_ json: String) throws -> SuggestEvidenceTask.Output {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(SuggestEvidenceTask.Output.self, from: Data(json.utf8))
}

@Suite struct SuggestEvidenceTaskTests {
    /// The asks once each, then the profile with its ids; never contact details.
    @Test func itSendsTheAsksAndYourNumberedResume() throws {
        #expect(input.asks.count == 2)
        let messages = SuggestEvidenceTask().messages(for: input, budget: TokenBudget(input: 4_000, output: 800))
        #expect(messages.count == 2 && !messages[0].content.isEmpty)
        let data = messages[1].content
        #expect(data.contains("<asks>\nObservability\n- Knowledge of DataDog"))
        #expect(data.contains("[p1] Project: Cluster Lab · Kubernetes, Prometheus"))
        #expect(!data.contains("Sam Okafor") && !data.contains("sam.okafor@example.com"))
    }

    @Test func aSuggestionPointsAtYourEntriesAndAsks() throws {
        let task = SuggestEvidenceTask()
        let good = try output(
            #"{"suggestions":[{"evidence":["p1","p1b1"],"question":"Did the GKE services in Cluster Lab have alerts on Prometheus metrics?","angle":"Which metrics you watched and what an alert caught."}],"otherwise":""}"#
        )
        try task.check(good, for: input)

        let unknown = try output(
            #"{"suggestions":[{"evidence":["x9"],"question":"Did you monitor anything?","angle":"What you watched."}],"otherwise":""}"#
        )
        #expect(throws: LLMError.self) { try task.check(unknown, for: input) }
        let statement = try output(
            #"{"suggestions":[{"evidence":["p1"],"question":"You monitored the cluster.","angle":"Metrics."}],"otherwise":""}"#
        )
        #expect(throws: LLMError.self) { try task.check(statement, for: input) }
        let nothing = try output(#"{"suggestions":[],"otherwise":""}"#)
        #expect(throws: LLMError.self) { try task.check(nothing, for: input) }
        let redacted = try output(
            #"{"suggestions":[{"evidence":["x1"],"question":"Did [removed] review your APIs?","angle":"Who used them."}],"otherwise":""}"#
        )
        #expect(throws: LLMError.self) { try task.check(redacted, for: input) }
        // No entry fits: one sentence on how to show it with something new.
        try task.check(
            try output(#"{"suggestions":[],"otherwise":"A small project with alerts would show it."}"#), for: input)
    }

    @Test func itRunsThroughTheRouter() async throws {
        let reply =
            #"{"suggestions":[{"evidence":["p1"],"question":"Did Cluster Lab include dashboards or alerts?","angle":"The dashboards and what they showed."}],"otherwise":""}"#
        let fake = FakeProvider([.suggestEvidence: [.reply(reply)]])
        let client = LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 })
        let router = LLMRouter(
            clients: ["fake": client], routes: [.suggestEvidence: [ModelRef(provider: "fake", model: "flash-lite")]],
            budget: Budget(), log: CallLog(try Database(path: ":memory:")), cache: nil)
        let result = try await router.run(SuggestEvidenceTask(), input: input)
        #expect(result.output.suggestions.map(\.evidence) == [["p1"]])
        #expect(TaskID.catalog.contains(.suggestEvidence))
    }
}
