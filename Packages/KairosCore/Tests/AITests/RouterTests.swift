import AI
import Foundation
import KairosKit
import Secrets
import TestKit
import Testing

/// A small task for the router's tests: names in, a list of names out, every one from the input.
struct EchoTask: AITask {
    struct Output: Decodable, Sendable, Equatable { let names: [String] }
    static let id = TaskID.analyzeJob
    static let promptVersion = 1
    static let outputSchema = JSONSchema.object([.required("names", .array(of: .string(maxLength: 20), maxItems: 3))])

    func messages(for input: [String], budget: TokenBudget) -> [ChatMessage] {
        [.system("List the names."), .user(Prompts.block("names", input.joined(separator: "\n")))]
    }

    func check(_ output: Output, for input: [String]) throws(AIError) {
        if let stranger = output.names.first(where: { !input.contains($0) }) {
            throw .invalidOutput("\(stranger) isn't in the input")
        }
    }
}

@Suite("AI router")
struct RouterTests {
    let input = ["Ada", "Grace"]

    @Test func answersLogsAndCaches() async throws {
        let chat = ScriptedChat([EchoTask.id: [.json(#"{"names":["Ada"]}"#)]])
        let log = MemoryCallLog()
        let router = scriptedRouter(chat, log: log, cache: MemoryResultCache())
        let first = try await router.run(EchoTask(), input: input, context: AIContext(jobID: "job-1"))
        #expect(first.output.names == ["Ada"] && !first.cached && !first.repaired && first.inputTokens == 100)
        let calls = await log.calls
        #expect(calls.map(\.outcome) == [.ok] && calls.first?.jobID == "job-1" && calls.first?.keyName == nil)

        let again = try await router.run(EchoTask(), input: input)
        #expect(again.cached && again.output == first.output && chat.asked.count == 1)
        // Re-evaluating asks again.
        chat.add(EchoTask.id, .json(#"{"names":["Grace"]}"#))
        let fresh = try await router.run(EchoTask(), input: input, context: AIContext(fresh: true))
        #expect(fresh.output.names == ["Grace"] && chat.asked.count == 2)
    }

    @Test func aReplyThatFailsItsChecksGetsOneRepair() async throws {
        let chat = ScriptedChat([
            EchoTask.id: [.json("```json\n{\"names\":[\"Linus\"]}\n```"), .json(#"{"names":["Grace"]}"#)]
        ])
        let result = try await scriptedRouter(chat).run(EchoTask(), input: input)
        #expect(result.output.names == ["Grace"] && result.repaired)
        let repair = try #require(chat.asked.last?.request.messages)
        #expect(repair.count == 4 && repair[3].content.contains("Linus isn't in the input"))
    }

    @Test func twoBadRepliesMoveToTheNextModel() async throws {
        let chat = ScriptedChat([
            EchoTask.id: [.json("not json"), .json(#"{"names":[1]}"#), .json(#"{"names":["Ada"]}"#)]
        ])
        var events: [AIEvent] = []
        let recorder = Locked<[AIEvent]>([])
        let result = try await scriptedRouter(chat, models: ["model-a", "model-b"]).run(
            EchoTask(), input: input, context: AIContext(events: { event in recorder.withLock { $0.append(event) } }))
        events = recorder.value
        #expect(result.model.model == "model-b" && result.fellBack)
        #expect(chat.asked.map(\.request.model) == ["model-a", "model-a", "model-b"])
        #expect(events.contains { if case .failed(_, let ref, _, let detail) = $0 { ref.model == "model-a" && detail != nil } else { false } })
    }

    @Test func aCutOffReplyIsRepairedNotTrusted() async throws {
        let chat = ScriptedChat([EchoTask.id: [.cutOff(#"{"names":["Ada"]}"#), .json(#"{"names":["Ada"]}"#)]])
        let result = try await scriptedRouter(chat).run(EchoTask(), input: input)
        #expect(result.repaired && chat.asked.count == 2)
    }

    /// 2026-10-23: one overloaded Flash cost every section of a build two minutes. With another
    /// model waiting, a 503 gets one quick retry, then the next model; the overloaded one is skipped
    /// for two minutes.
    @Test func anOverloadedModelIsntWaitedOutWhenAnotherCanGo() async throws {
        let chat = ScriptedChat([EchoTask.id: [.error(.server(status: 503)), .error(.server(status: 503))]])
        chat.always(EchoTask.id, .json(#"{"names":["Ada"]}"#))
        let router = scriptedRouter(chat, models: ["flash", "lite"])
        let result = try await router.run(EchoTask(), input: input)
        #expect(result.model.model == "lite")
        #expect(chat.asked.map(\.request.model) == ["flash", "flash", "lite"])
        _ = try await router.run(EchoTask(), input: ["Ada", "Zoe"])
        #expect(chat.asked.map(\.request.model).suffix(1) == ["lite"])  // flash skipped while troubled
    }

    @Test func alone_aServerErrorIsRetriedWithBackoff() async throws {
        let chat = ScriptedChat([EchoTask.id: [.error(.server(status: 500)), .error(.network("reset"))]])
        chat.always(EchoTask.id, .json(#"{"names":["Ada"]}"#))
        let clock = TestClock()
        _ = try await scriptedRouter(chat, clock: clock).run(EchoTask(), input: input)
        #expect(chat.asked.count == 3 && clock.slept == [1, 2])
    }

    @Test func aTimeoutIsTriedOnceMoreAtMost() async throws {
        let chat = ScriptedChat()
        chat.always(EchoTask.id, .error(.timedOut))
        await #expect(throws: AIError.timedOut) { _ = try await scriptedRouter(chat).run(EchoTask(), input: input) }
        #expect(chat.asked.count == 2)
    }

    @Test func refusedKeysAndMissingModelsAreNeverRetried() async throws {
        for error in [AIError.keyRejected(provider: "p"), .modelNotFound("model-a"), .badRequest("no")] {
            let chat = ScriptedChat()
            chat.always(EchoTask.id, .error(error))
            await #expect(throws: error) { _ = try await scriptedRouter(chat).run(EchoTask(), input: input) }
            #expect(chat.asked.count == 1)
        }
    }

    @Test func stoppingStopsTheWholeChain() async throws {
        let chat = ScriptedChat([EchoTask.id: [.error(.cancelled)]])
        chat.always(EchoTask.id, .json(#"{"names":["Ada"]}"#))
        await #expect(throws: AIError.cancelled) {
            _ = try await scriptedRouter(chat, models: ["a", "b"]).run(EchoTask(), input: input)
        }
        #expect(chat.asked.count == 1)
    }

    @Test func theDailyBudgetPausesTasks() async throws {
        let chat = ScriptedChat()
        chat.always(EchoTask.id, .json(#"{"names":["Ada"]}"#))
        let log = MemoryCallLog()
        let router = scriptedRouter(chat, log: log, budget: AISettings.Budget(dailyCalls: 2))
        _ = try await router.run(EchoTask(), input: ["Ada"])
        _ = try await router.run(EchoTask(), input: ["Ada", "x"])
        await #expect(throws: AIError.budgetReached) { _ = try await router.run(EchoTask(), input: ["Ada", "y"]) }
    }

    @Test func aModelThatRefusesSchemaModeIsRemembered() async throws {
        let chat = ScriptedChat()
        chat.always(EchoTask.id, .json(#"{"names":["Ada"]}"#))
        chat.refusesSchema = ["model-a"]
        let settings = AISettings(
            providers: [AISettings.Provider(id: "g", presetID: "gemini", keyNames: ["k1"])],
            routes: [EchoTask.id.rawValue: [ModelRef(provider: "g", model: "model-a")]])
        let router = AIRouter(
            settings: settings, secrets: MemorySecretStore([SecretKey("k1"): "key-1"]), service: chat, clock: TestClock())
        _ = try await router.run(EchoTask(), input: ["Ada"])
        _ = try await router.run(EchoTask(), input: ["Ada", "b"])
        #expect(chat.asked.map(\.mode) == [.jsonMode, .jsonMode])
        #expect(chat.asked.allSatisfy { $0.key == "key-1" })
    }
}

@Suite("AI router: keys")
struct RouterKeyTests {
    static func router(_ chat: ScriptedChat, keys: [String], log: MemoryCallLog? = nil, clock: TestClock = TestClock(),
        models: [String] = ["gemini-flash-latest"]) -> AIRouter
    {
        let names = keys.indices.map { "llm.gemini.k\($0)" }
        let settings = AISettings(
            providers: [AISettings.Provider(id: "gemini", presetID: "gemini", keyNames: names)],
            routes: [EchoTask.id.rawValue: models.map { ModelRef(provider: "gemini", model: $0) }])
        let secrets = MemorySecretStore(Dictionary(uniqueKeysWithValues: zip(names.map(SecretKey.init), keys)))
        return AIRouter(settings: settings, secrets: secrets, service: chat, log: log, clock: clock, jitter: { 1 })
    }

    @Test func aRateLimitedKeyRestsAndTheNextAnswers() async throws {
        let chat = ScriptedChat([EchoTask.id: [.error(.rateLimited(retryAfterSeconds: 30))]])
        chat.always(EchoTask.id, .json(#"{"names":["Ada"]}"#))
        let log = MemoryCallLog()
        let router = Self.router(chat, keys: ["one", "two"], log: log)
        _ = try await router.run(EchoTask(), input: ["Ada"])
        #expect(chat.asked.map(\.key) == ["one", "two"])
        #expect(await log.calls.map(\.outcome) == [.rateLimited, .ok])
        #expect(await router.resting(provider: "gemini")["llm.gemini.k0"]?["gemini-flash-latest"] != nil)
        // The next task starts on the key that worked.
        _ = try await router.run(EchoTask(), input: ["Ada", "b"])
        #expect(chat.asked.last?.key == "two")
    }

    @Test func aKeyUsedUpForTheDayRestsUntilTheQuotaDayEnds() async throws {
        let chat = ScriptedChat([
            EchoTask.id: [.error(.quotaUsedUp(model: "gemini-flash-latest", limit: 20, retryAfterSeconds: nil))]
        ])
        let log = MemoryCallLog()
        let clock = TestClock()
        let router = Self.router(chat, keys: ["only"], log: log, clock: clock)
        await #expect(throws: AIError.self) { _ = try await router.run(EchoTask(), input: ["Ada"]) }
        let refusal = try #require(await log.calls.first)
        #expect(refusal.outcome == .usedUp && refusal.dailyLimit == 20)
        let midnightPacific = QuotaDay.bounds(at: clock.now, zone: "America/Los_Angeles").end
        #expect(refusal.backAt == midnightPacific)
        #expect(chat.asked.count == 1)  // never waited hours for it
    }

    @Test func aModelOffEveryKeysPlanMovesOn() async throws {
        let chat = ScriptedChat([
            EchoTask.id: [.error(.modelNotOnPlan("pro")), .error(.modelNotOnPlan("pro"))]
        ])
        chat.always(EchoTask.id, .json(#"{"names":["Ada"]}"#))
        let router = Self.router(chat, keys: ["a", "b"], models: ["pro", "gemini-flash-lite-latest"])
        let result = try await router.run(EchoTask(), input: ["Ada"])
        #expect(result.model.model == "gemini-flash-lite-latest")
        #expect(chat.asked.map(\.key) == ["a", "b", "a"])
    }

    @Test func withoutAKeyThereIsNothingToRun() async throws {
        let chat = ScriptedChat()
        let router = Self.router(chat, keys: [])
        await #expect(throws: AIError.noKey(provider: "Google Gemini")) { _ = try await router.run(EchoTask(), input: ["Ada"]) }
        #expect(await router.canRun(EchoTask.id) == false)
        #expect(chat.asked.isEmpty)
    }

    @Test func noChainIsNoModel() async throws {
        let router = AIRouter(
            settings: AISettings(providers: [], routes: [:]), secrets: MemorySecretStore(), service: ScriptedChat())
        await #expect(throws: AIError.noModel(EchoTask.id)) { _ = try await router.run(EchoTask(), input: ["Ada"]) }
    }
}
