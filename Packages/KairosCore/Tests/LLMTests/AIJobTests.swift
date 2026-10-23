import Foundation
import Store
import Testing

@testable import LLM

private let lite = ModelRef(provider: "gemini", model: "gemini-flash-lite-latest")
private let flash = ModelRef(provider: "gemini", model: "gemini-flash-latest")
private let gemma = ModelRef(provider: "ollama-cloud", model: "gemma4:31b")
private let gptOss = ModelRef(provider: "ollama-cloud", model: "gpt-oss:120b")
private let qwen = ModelRef(provider: "ollama-local", model: "qwen3.5:4B")

private func settings(cloud: Bool) -> LLMSettings {
    var settings = LLMSettings.defaults()
    if cloud {
        settings.providers.append(.init(id: "ollama-cloud", presetID: "ollama-cloud", keyNames: ["k"]))
    }
    return settings
}

private let listed: [String: [String]] = [
    "gemini": ["gemini-flash-latest", "gemini-flash-lite-latest"], "ollama-local": ["qwen3.5:4B"],
    "ollama-cloud": ["gemma4:31b", "gpt-oss:120b", "kimi-k3"],
]

@Suite("AI jobs")
struct AIJobTests {
    /// Every task but on-device triage belongs to exactly one job.
    @Test func everyTaskHasOneJob() {
        let jobbed = AIJob.allCases.flatMap(\.tasks)
        #expect(Set(jobbed) == Set(TaskID.catalog).subtracting([.triage]) && jobbed.count == Set(jobbed).count)
        #expect(AIJob.allCases.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    /// A job's chain is every one of its tasks' chain, without repeats and at most three long; a
    /// task set on its own makes the job's tasks differ.
    @Test func aJobsChainIsItsTasksChain() {
        var routes = LLMSettings.defaults()
        routes.setChain([gemma, lite, gemma, gptOss, flash], for: .writing)
        #expect(routes.chain(for: .writing) == [gemma, lite, gptOss])
        #expect(AIJob.writing.tasks.allSatisfy { routes.routes[$0.rawValue] == [gemma, lite, gptOss] })
        #expect(routes.isUniform(.writing))
        routes.routes[TaskID.shortenBullets.rawValue] = [lite]
        #expect(!routes.isUniform(.writing) && routes.chain(for: .writing) == [gemma, lite, gptOss])
    }

    /// With Ollama Cloud: writing and letters on gemma4 first, Gemini Flash-Lite and gpt-oss behind
    /// it; postings on Flash-Lite. Then Gemini alone, then this Mac alone.
    @Test func theRecommendedSetupsFitYourProviders() throws {
        let setups = AISetup.recommended(for: settings(cloud: true), models: listed)
        #expect(setups.map(\.id) == ["free", "gemini", "private"])
        let free = try #require(setups.first)
        #expect(free.chains[.writing] == [gemma, lite, gptOss] && free.chains[.letters] == [gemma, lite, gptOss])
        #expect(free.chains[.reading] == [lite, gemma, qwen] && free.chains[.importing] == [flash, lite, gemma])
        var applied = settings(cloud: true)
        applied.apply(free)
        #expect(applied.chain(for: .writing) == [gemma, lite, gptOss] && applied.isUniform(.writing))
        #expect(setups[2].chains.values.allSatisfy { $0 == [qwen] })
    }

    /// Without Ollama Cloud, or without its model listed yet, there's no free mix; without
    /// Gemini's models, no Gemini setup.
    @Test func aSetupNamesOnlyModelsThatAreThere() {
        #expect(AISetup.recommended(for: settings(cloud: false), models: listed).map(\.id) == ["gemini", "private"])
        var noGemma = listed
        noGemma["ollama-cloud"] = ["kimi-k3"]
        #expect(AISetup.recommended(for: settings(cloud: true), models: noGemma).map(\.id) == ["gemini", "private"])
        let gemini = AISetup.recommended(for: settings(cloud: false), models: listed).first
        #expect(gemini?.chains[.writing] == [lite, flash])
        #expect(AISetup.recommended(for: settings(cloud: false), models: [:]).isEmpty)
    }

    /// How each model has done today: calls, failures, and how long an answer took.
    @Test func modelHealthCountsFailuresAndTimesAnswers() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let log = CallLog(db)
        let now = Date()
        for (model, outcome, seconds) in [
            ("gemini-flash-latest", LLMOutcome.failed, 120), ("gemini-flash-latest", .ok, 10),
            ("gemini-flash-latest", .fellBack, 20), ("gemini-flash-lite-latest", .rateLimited, 1),
        ] {
            try await log.record(
                CallRecord(
                    at: now, task: .writeExperience, provider: "gemini", model: model, promptVersion: 2,
                    inputTokens: nil, outputTokens: nil, latency: .seconds(seconds), attempts: 1, outcome: outcome,
                    errorCode: nil, jobID: nil, buildID: nil))
        }
        let health = try await log.health(since: now.addingTimeInterval(-60))
        #expect(health[flash] == ModelHealth(calls: 3, failed: 1, averageSeconds: 15))
        #expect(health[lite] == ModelHealth(calls: 1, failed: 1, averageSeconds: nil))
    }
}
