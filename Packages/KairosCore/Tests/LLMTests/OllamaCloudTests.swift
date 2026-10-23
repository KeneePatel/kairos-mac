import Foundation
import Store
import Testing

@testable import LLM

private func reply(_ status: Int, _ json: String) -> FakeTransport.Reply {
    FakeTransport.Reply(status: status, body: Data(json.utf8))
}

@Suite("Ollama Cloud")
struct OllamaCloudTests {
    /// Its model list needs no key, so a key is checked with one tiny chat on a free model. A
    /// model the account can't use (402) still proves the key; 401 doesn't.
    @Test func aKeyIsCheckedWithOneTinyChat() async throws {
        let transport = FakeTransport([
            reply(200, #"{"choices":[{"message":{"content":"ok"}}]}"#),
            reply(402, #"{"error":{"message":"this model is not included in your free usage"}}"#),
            reply(401, #"{"error":"unauthorized"}"#),
        ])
        let cloud = OpenAICompatibleProvider(preset: .ollamaCloud, key: "secret-key", transport: transport)
        try await cloud.checkKey(model: "gemma4:31b")
        try await cloud.checkKey(model: "deepseek-v4.1-flash")
        await #expect(throws: LLMError.keyRejected(provider: "Ollama Cloud")) {
            try await cloud.checkKey(model: "gemma4:31b")
        }
        let sent = try #require(transport.sent.first)
        #expect(sent.url?.absoluteString == "https://ollama.com/v1/chat/completions" && sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        let body = String(decoding: sent.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains(#""model":"gemma4:31b""#) && body.contains(#""max_tokens":5"#))
    }

    /// It starts on gemma4:31b, the free model that passed every eval call, checks keys on it, and
    /// sells three plans by how many calls run at once.
    @Test func itStartsOnTheBestFreeModelAndKnowsItsPlans() {
        let cloud = ProviderPreset.ollamaCloud
        #expect(cloud.defaultModels[.flash] == "gemma4:31b" && cloud.defaultModels[.flashLite] == "gemma4:31b")
        #expect(cloud.keyCheckModel == "gemma4:31b" && cloud.structuredOutput == .jsonMode)
        #expect(cloud.plans.map(\.id) == ["free", "pro", "max"] && cloud.plans.map(\.concurrent) == [1, 3, 10])
        #expect(ProviderPreset.gemini.keyCheckModel == nil && ProviderPreset.gemini.plans.isEmpty)
    }

    /// The plan sets how many calls run at once; none chosen is the free one, and a provider that
    /// sells no plans keeps the client's own limit.
    @Test func thePlanSetsCallsAtOnce() {
        var provider = LLMSettings.Provider(id: "ollama-cloud", presetID: "ollama-cloud", keyNames: ["k1"])
        #expect(provider.concurrent == 1 && provider.setup.concurrent == 1)
        provider.plan = "pro"
        #expect(provider.concurrent == 3 && provider.setup.concurrent == 3)
        provider.plan = "max"
        #expect(provider.setup.concurrent == 10)
        #expect(LLMSettings.Provider(id: "gemini", presetID: "gemini").concurrent == nil)
    }

    /// A plan saved by an older Kairos is just missing: it reads as the free one.
    @Test func settingsWithoutAPlanStillRead() throws {
        let json = #"{"id":"ollama-cloud","presetID":"ollama-cloud","keyNames":["k1"]}"#
        let provider = try JSONDecoder().decode(LLMSettings.Provider.self, from: Data(json.utf8))
        #expect(provider.plan == nil && provider.concurrent == 1)
    }
}

@Suite("Model guide")
struct ModelGuideTests {
    /// A model as a provider names it finds its entry: a tag, a dated build, or a "-cloud" suffix
    /// through a signed-in Ollama.
    @Test func modelsAreFoundByTheirNamesAsListed() {
        #expect(ModelGuide.entry(for: "gemma4:31b")?.advice == .recommended)
        #expect(ModelGuide.entry(for: "gemma4:31b-cloud")?.model == "gemma4:31b")
        #expect(ModelGuide.entry(for: "gpt-oss:120b-cloud")?.advice == .fallback)
        #expect(ModelGuide.entry(for: "deepseek-v4.1-flash:1017")?.model == "deepseek-v4.1-flash")
        #expect(ModelGuide.entry(for: "deepseek-v4-pro:0813")?.advice == .skip)
        #expect(ModelGuide.entry(for: "mistral-large-3:675b")?.model == "mistral-large-3")
        #expect(ModelGuide.entry(for: "gpt-oss:20b")?.advice == .skip)
        #expect(ModelGuide.entry(for: "something-new") == nil)
    }

    /// A free model says so; a paid one says what a resume costs on it.
    @Test func eachSaysWhatAResumeCosts() throws {
        let gemma = try #require(ModelGuide.entry(for: "gemma4:31b"))
        #expect(gemma.costLine == "free on Ollama's Free plan" && abs(gemma.costPerBuild - 0.0052) < 0.0001)
        #expect(ModelGuide.entry(for: "deepseek-v4.1-flash")?.costLine == "about 1¢ a resume, needs credits")
        #expect(ModelGuide.entry(for: "kimi-k3")?.costLine == "about 15¢ a resume, needs credits")
        #expect(abs(gemma.cost(input: 1_000_000, output: 1_000_000) - 0.54) < 0.000_001)
        // Every model worth using has a price and a reason.
        for entry in ModelGuide.ollamaCloud where entry.advice != .skip {
            #expect(entry.inputPrice > 0 && entry.outputPrice > 0 && !entry.note.isEmpty, "\(entry.model)")
        }
        #expect(Set(ModelGuide.ollamaCloud.map(\.model)).count == ModelGuide.ollamaCloud.count)
    }

    /// Tokens per model at one provider this month: what Ollama credits went on.
    @Test func tokensAreCountedPerModelForOneProvider() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let log = CallLog(db)
        let now = Date()
        for (provider, model, input) in [
            ("ollama-cloud", "gemma4:31b", 1_000), ("ollama-cloud", "gemma4:31b", 500),
            ("ollama-cloud", "gpt-oss:120b", 200),
            ("gemini", "gemini-flash-lite-latest", 9_000),
        ] {
            try await log.record(
                CallRecord(
                    at: now, task: .writeExperience, provider: provider, model: model, promptVersion: 2,
                    inputTokens: input, outputTokens: input / 10, latency: .seconds(1), attempts: 1, outcome: .ok,
                    errorCode: nil, jobID: nil, buildID: nil))
        }
        let tokens = try await log.tokens(provider: "ollama-cloud", since: now.addingTimeInterval(-60))
        #expect(
            tokens == [
                "gemma4:31b": TokenCount(input: 1_500, output: 150), "gpt-oss:120b": TokenCount(input: 200, output: 20),
            ])
    }
}
