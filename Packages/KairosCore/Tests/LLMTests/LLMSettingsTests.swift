import Foundation
import Secrets
import Store
import Testing

@testable import LLM

@Suite("LLM settings")
struct LLMSettingsTests {
    @Test func newAccountsStartOnGeminiFlashAndFlashLite() {
        let settings = LLMSettings.defaults()
        #expect(settings.providers.map(\.id) == ["gemini", "ollama-local"])
        #expect(settings.routes["analyzeJob"] == [ModelRef(provider: "gemini", model: "gemini-flash-lite-latest")])
        #expect(settings.routes["writeExperience"] == [ModelRef(provider: "gemini", model: "gemini-flash-latest")])
        #expect(settings.routes["triage"] == nil)  // on device, when available
        #expect(settings.budget == Budget(dailyCalls: 300))
    }

    @Test func savedSettingsHoldKeyNamesNeverKeys() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        var settings = LLMSettings.defaults()
        let name = LLMSettings.newKeyName(for: "gemini")
        let secrets = InMemorySecretStore([SecretKey(name): "AIzaSyDUMMYKEYVALUE1234"])
        settings.providers[0].keyNames = [name]
        try await SettingsRepository(db).save(settings, for: LLMSettings.storageKey)
        #expect(try await SettingsRepository(db).value(LLMSettings.storageKey, as: LLMSettings.self) == settings)
        let stored = try await db.query("SELECT value FROM setting").first?.string("value") ?? ""
        #expect(stored.contains(name) && !stored.contains("AIzaSyDUMMYKEYVALUE1234"))
        _ = settings.router(db: db, secrets: secrets)
    }

    /// Settings saved before a task existed have no route for it, so it would fail with no
    /// provider. It borrows your route for a task of the same kind, or else the default.
    @Test func aTaskAddedLaterBorrowsYourRouteForItsKind() {
        var settings = LLMSettings.defaults()
        let local = ModelRef(provider: "ollama-local", model: "qwen3.5:4B")
        settings.routes["analyzeJob"] = [local]
        settings.routes["suggestEvidence"] = nil
        settings.routes["coverLetter"] = nil
        settings.addMissingRoutes()
        #expect(settings.routes["suggestEvidence"] == [local])  // Flash-Lite's kind, as analyzeJob
        #expect(settings.routes["coverLetter"] == settings.routes["writeExperience"])
        #expect(settings.routes["triage"] == nil)
        // A route you emptied stays empty.
        settings.routes["select"] = []
        settings.addMissingRoutes()
        #expect(settings.routes["select"] == [])
    }

    @Test func keepingEverythingLocalRoutesEveryTaskToOllama() {
        var settings = LLMSettings.defaults()
        settings.routeEverything(to: ModelRef(provider: "ollama-local", model: "qwen3.5:4B"))
        #expect(settings.routes.values.allSatisfy { $0 == [ModelRef(provider: "ollama-local", model: "qwen3.5:4B")] })
        #expect(settings.routes["triage"] == nil)
    }

    @Test func aCustomProviderResolvesToItsOwnPreset() {
        let custom = LLMSettings.Provider(
            id: "custom-1", presetID: "custom", name: "LM Studio", baseURL: "http://localhost:1234/v1")
        #expect(custom.preset.name == "LM Studio" && custom.preset.isLocal && !custom.preset.needsKey)
        #expect(LLMSettings.Provider(id: "x", presetID: "groq").preset == .groq)
    }

    @Test func aRequestsPerMinuteOverrideReachesTheSetup() {
        let provider = LLMSettings.Provider(id: "gemini", presetID: "gemini", keyNames: ["k"], requestsPerMinute: 60)
        #expect(provider.setup.requestsPerMinute == 60 && provider.setup.keyNames == [SecretKey("k")])
    }

    @Test(arguments: [("AIzaSyDUMMYKEYVALUE1234", "AIza••••••••••••1234"), ("short", "•••••"), ("", "••••")])
    func keysAreMasked(key: String, masked: String) {
        #expect(LLMSettings.masked(key) == masked)
    }

    @Test func usageIsCountedPerProvider() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let log = CallLog(db)
        let now = Date()
        for (provider, attempts) in [("gemini", 2), ("gemini", 1), ("ollama-local", 1)] {
            try await log.record(
                CallRecord(
                    at: now, task: .analyzeJob, provider: provider, model: "m", promptVersion: 1, inputTokens: 10,
                    outputTokens: 5, latency: .seconds(1), attempts: attempts, outcome: .ok, errorCode: nil, jobID: nil,
                    buildID: nil))
        }
        let usage = try await log.usageByProvider(since: now.addingTimeInterval(-60))
        #expect(usage == ["gemini": Usage(calls: 3, tokens: 30), "ollama-local": Usage(calls: 1, tokens: 15)])
    }

    /// A build's report card counts its own calls, per task, and nothing from other builds.
    @Test func usageIsCountedPerBuildAndTask() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let log = CallLog(db)
        for (task, build, attempts) in [
            (TaskID.writeExperience, "b1", 1), (.writeExperience, "b1", 2), (.coverLetter, "b1", 1),
            (.writeExperience, "b2", 1),
        ] {
            try await log.record(
                CallRecord(
                    at: Date(), task: task, provider: "gemini", model: "m", promptVersion: 1, inputTokens: 100,
                    outputTokens: 20, latency: .seconds(1), attempts: attempts, outcome: .ok, errorCode: nil,
                    jobID: "j1", buildID: build))
        }
        let usage = try await log.usage(build: "b1")
        #expect(
            usage == [.writeExperience: Usage(calls: 3, tokens: 240), .coverLetter: Usage(calls: 1, tokens: 120)])
        #expect(try await log.usage(build: "b3").isEmpty)
    }
}
