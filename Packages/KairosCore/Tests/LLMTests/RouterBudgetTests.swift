import Foundation
import Secrets
import Store
import Synchronization
import TestSupport
import Testing

@testable import LLM

private let posting = "Go and PostgreSQL required; Kafka is a plus. 3 years."
private let valid = #"{"requirements":[{"text":"Go","kind":"must"},{"text":"Kafka","kind":"nice"}],"years_required":3}"#

/// The same task with a newer prompt: its cache entries must not be reused.
private struct RequirementsTaskV2: LLMTask {
    typealias Output = RequirementsTask.Output
    static let id = RequirementsTask.id
    static let promptVersion = 2
    static let outputSchema = RequirementsTask.outputSchema
    func messages(for input: String, budget: TokenBudget) -> [ChatMessage] {
        RequirementsTask().messages(for: input, budget: budget)
    }
    func check(_ output: Output, for input: String) throws { try RequirementsTask().check(output, for: input) }
}

/// A wall clock tests can move to tomorrow.
private final class Today: Sendable {
    private let date = Mutex(Date(timeIntervalSince1970: 1_760_870_000))  // 2025-10-19, mid-morning UTC
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 += seconds } }
}

private func database() async throws -> Database {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    return db
}

private func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func client(_ provider: FakeProvider) -> LLMClient {
    LLMClient(keys: [provider], policy: ClientPolicy(requestsPerMinute: 6_000), clock: VirtualClock(), jitter: { 1 })
}

private func router(
    _ db: Database, providers: [String: FakeProvider], chain: [ModelRef], budget: Budget = Budget(), cache: Bool = true,
    today: Today = Today()
) -> LLMRouter {
    LLMRouter(
        clients: providers.mapValues(client), routes: [.analyzeJob: chain], budget: budget, log: CallLog(db),
        cache: cache ? ResultCache(db) : nil, now: { today.now }, calendar: utc())
}

private let gemini = ModelRef(provider: "gemini", model: "gemini-flash-lite-latest")
private let ollama = ModelRef(provider: "ollama", model: "qwen3.5:4B")

@Suite("LLM local tables")
struct LLMTablesTests {
    @Test func theyAreLocalOnly() async throws {
        let db = try await database()
        for table in ["llm_call", "llm_cache"] {
            let columns = try await db.query("SELECT name FROM pragma_table_info(?)", [.text(table)]).compactMap {
                $0.string("name")
            }
            #expect(!columns.isEmpty, "\(table) missing")
            #expect(!columns.contains("updated_hlc") && !columns.contains("deleted"), "\(table) would sync")
        }
    }
}

@Suite("LLM router")
struct LLMRouterTests {
    @Test func runsATaskOnItsModelAndLogsTheCallWithoutAnyText() async throws {
        let db = try await database()
        let fake = FakeProvider(
            [.analyzeJob: [.reply(valid, inputTokens: 120, outputTokens: 40)]], name: "Google Gemini")
        let result = try await router(db, providers: ["gemini": fake], chain: [gemini])
            .run(RequirementsTask(), input: posting, context: CallContext(jobID: "job-1"))
        #expect(result.output.yearsRequired == 3 && result.outcome == .ok)
        let sent = try #require(fake.requests.first)
        #expect(sent.model == "gemini-flash-lite-latest" && sent.temperature == 0 && sent.maxOutputTokens == 1_500)
        #expect(sent.timeoutSeconds == 60)  // extraction

        let rows = try await db.query("SELECT * FROM llm_call")
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.string("task_id") == "analyzeJob" && row.string("provider") == "gemini")  // the setup id
        #expect(row.string("model") == "gemini-flash-lite-latest" && row.int("prompt_version") == 1)
        #expect(row.int("input_tokens") == 120 && row.int("output_tokens") == 40 && row.int("attempt") == 1)
        #expect(row.string("outcome") == "ok" && row["error_code"] == .null && row.string("job_id") == "job-1")
        // SPEC §5.5: no prompt or response text in the log.
        for value in row.values {
            if case .text(let text) = value {
                #expect(!text.contains("PostgreSQL") && !text.contains("Kafka") && !text.contains("requirements"))
            }
        }
    }

    @Test func fallsBackToTheNextModelAndLogsBoth() async throws {
        let db = try await database()
        let primary = FakeProvider([.analyzeJob: [.failure(.keyRejected(provider: "Google Gemini"))]])
        let backup = FakeProvider([.analyzeJob: [.reply(valid)]], name: "Ollama on this Mac")
        let result = try await router(db, providers: ["gemini": primary, "ollama": backup], chain: [gemini, ollama])
            .run(RequirementsTask(), input: posting)
        #expect(result.outcome == .fellBack && result.provider == "Ollama on this Mac" && result.model == "qwen3.5:4B")
        let log = try await db.query("SELECT outcome, error_code FROM llm_call ORDER BY id")
        #expect(log.map { $0.string("outcome") } == ["failed", "fell_back"])
        #expect(log.map { $0.string("error_code") } == ["key_rejected", nil])
    }

    @Test func aRateLimitIsLoggedAsSuch() async throws {
        let db = try await database()
        let limited = FakeProvider([.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: 3_600))]])
        let backup = FakeProvider([.analyzeJob: [.reply(valid)]])
        _ = try await router(db, providers: ["gemini": limited, "ollama": backup], chain: [gemini, ollama])
            .run(RequirementsTask(), input: posting)
        #expect(
            try await db.query("SELECT outcome FROM llm_call ORDER BY id").first?.string("outcome") == "rate_limited")
    }

    @Test func cancellingStopsTheChain() async throws {
        let db = try await database()
        let primary = FakeProvider([.analyzeJob: [.failure(.cancelled)]])
        let backup = FakeProvider([.analyzeJob: [.reply(valid)]])
        await #expect(throws: LLMError.cancelled) {
            try await router(db, providers: ["gemini": primary, "ollama": backup], chain: [gemini, ollama])
                .run(RequirementsTask(), input: posting)
        }
        #expect(backup.requests.isEmpty)
    }

    @Test func anExhaustedChainReportsTheLastError() async throws {
        let db = try await database()
        let first = FakeProvider([.analyzeJob: [.failure(.modelNotFound("a"))]])
        let second = FakeProvider([.analyzeJob: [.failure(.badRequest("b"))]])
        await #expect(throws: LLMError.badRequest("b")) {
            try await router(db, providers: ["gemini": first, "ollama": second], chain: [gemini, ollama])
                .run(RequirementsTask(), input: posting)
        }
        await #expect(throws: LLMError.noProvider(.analyzeJob)) {
            try await router(db, providers: [:], chain: [gemini]).run(RequirementsTask(), input: posting)
        }
        await #expect(throws: LLMError.noProvider(.analyzeJob)) {
            try await router(db, providers: [:], chain: []).run(RequirementsTask(), input: posting)
        }
    }
}

@Suite("LLM budget and cache")
struct BudgetCacheTests {
    @Test func theDailyCallBudgetPausesStepsUntilTomorrow() async throws {
        let db = try await database()
        let today = Today()
        let fake = FakeProvider([.analyzeJob: Array(repeating: .reply(valid), count: 4)])
        let router = router(
            db, providers: ["gemini": fake], chain: [gemini], budget: Budget(dailyCalls: 2), cache: false, today: today)
        _ = try await router.run(RequirementsTask(), input: posting)
        _ = try await router.run(RequirementsTask(), input: posting)
        await #expect(throws: LLMError.budgetReached) { try await router.run(RequirementsTask(), input: posting) }
        #expect(fake.requests.count == 2)
        #expect(try await router.usageToday() == Usage(calls: 2, tokens: 0))
        today.advance(24 * 3_600)
        #expect(try await router.run(RequirementsTask(), input: posting).outcome == .ok)
        #expect(Budget.reachedMessage == "Daily AI budget reached")
    }

    @Test func anOptionalTokenBudgetCountsInputAndOutput() async throws {
        let db = try await database()
        let fake = FakeProvider([.analyzeJob: [.reply(valid, inputTokens: 80, outputTokens: 30), .reply(valid)]])
        let router = router(
            db, providers: ["gemini": fake], chain: [gemini], budget: Budget(dailyTokens: 100), cache: false)
        _ = try await router.run(RequirementsTask(), input: posting)
        await #expect(throws: LLMError.budgetReached) { try await router.run(RequirementsTask(), input: posting) }
    }

    @Test func aRepeatedStepComesFromTheCacheForFree() async throws {
        let db = try await database()
        let fake = FakeProvider([.analyzeJob: [.reply(valid, inputTokens: 50, outputTokens: 20)]])
        let router = router(db, providers: ["gemini": fake], chain: [gemini], budget: Budget(dailyCalls: 1))
        _ = try await router.run(RequirementsTask(), input: posting)
        let again = try await router.run(RequirementsTask(), input: posting)
        #expect(again.outcome == .cached && again.attempts == 0 && again.output.requirements.count == 2)
        #expect(fake.requests.count == 1)
        #expect(try await router.usageToday().calls == 1)  // the cache hit made no call and logged none
    }

    @Test func theCacheKeyCoversInputPromptVersionAndModel() async throws {
        let db = try await database()
        let fake = FakeProvider([.analyzeJob: Array(repeating: .reply(valid), count: 3)])
        _ = try await router(db, providers: ["gemini": fake], chain: [gemini]).run(RequirementsTask(), input: posting)
        _ = try await router(db, providers: ["gemini": fake], chain: [gemini]).run(
            RequirementsTask(), input: posting + " Remote.")
        _ = try await router(db, providers: ["gemini": fake], chain: [gemini]).run(RequirementsTaskV2(), input: posting)
        let other = ModelRef(provider: "gemini", model: "gemini-flash-latest")
        let fresh = FakeProvider([.analyzeJob: [.reply(valid)]])
        _ = try await router(db, providers: ["gemini": fresh], chain: [other]).run(RequirementsTask(), input: posting)
        #expect(fake.requests.count == 3 && fresh.requests.count == 1)
    }

    @Test func aCachedReplyThatNoLongerPassesTheCheckIsFetchedAgain() async throws {
        let db = try await database()
        let key = ResultCache.Key(
            task: .analyzeJob,
            messages: RequirementsTask().messages(for: posting, budget: TaskDefaults.catalog[.analyzeJob]!.budget),
            promptVersion: 1, model: gemini.model)
        try await ResultCache(db).store(
            #"{"requirements":[{"text":"Rust","kind":"must"}],"years_required":3}"#, for: key, at: Date())
        let fake = FakeProvider([.analyzeJob: [.reply(valid)]])
        #expect(
            try await router(db, providers: ["gemini": fake], chain: [gemini]).run(RequirementsTask(), input: posting)
                .outcome == .ok)
        #expect(fake.requests.count == 1)
    }

    @Test func oldLogRowsAreDeleted() async throws {
        let db = try await database()
        let log = CallLog(db)
        let now = Date(timeIntervalSince1970: 1_760_870_000)
        for daysAgo in [0, 10, 31, 45] {
            try await log.record(
                CallRecord(
                    at: now.addingTimeInterval(Double(-daysAgo) * 86_400), task: .analyzeJob, provider: "p", model: "m",
                    promptVersion: 1, inputTokens: nil, outputTokens: nil, latency: .seconds(1), attempts: 1,
                    outcome: .ok,
                    errorCode: nil, jobID: nil, buildID: nil))
        }
        let removed = try await log.deleteOlder(than: now.addingTimeInterval(-Double(CallLog.retentionDays) * 86_400))
        #expect(removed == 2)
        #expect(try await log.usage(since: .distantPast).calls == 2)
    }
}

@Suite("Provider setup")
struct ProviderSetupTests {
    @Test func keysComeFromTheKeychainOnly() async throws {
        let secrets = InMemorySecretStore([
            SecretKey("llm.gemini.1"): "first-key", SecretKey("llm.gemini.2"): "second-key",
        ])
        let setup = ProviderSetup(
            id: "gemini", preset: .gemini, keyNames: [SecretKey("llm.gemini.1"), SecretKey("llm.gemini.2")])
        let transport = FakeTransport([
            .init(body: try ScriptedURLProtocol.fixture("llm/gemini-json-gemini-flash-latest.json"))
        ])
        let client = try setup.client(secrets: secrets, transport: transport, clock: VirtualClock())
        _ = try await client.complete(
            ChatRequest(
                task: .analyzeJob, model: "m", messages: [.user("x")], schema: nil, temperature: 0, maxOutputTokens: 10)
        )
        #expect(transport.sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer first-key")
        #expect(!String(describing: setup).contains("first-key"))  // the setup holds names, not keys
    }

    @Test func aProviderThatNeedsAKeyWithoutOneIsAnError() {
        let setup = ProviderSetup(id: "gemini", preset: .gemini, keyNames: [SecretKey("llm.gemini.missing")])
        #expect(throws: LLMError.noKey(provider: "Google Gemini")) { try setup.client(secrets: InMemorySecretStore()) }
    }

    @Test func localOllamaNeedsNoKey() throws {
        _ = try ProviderSetup(id: "ollama", preset: .ollamaLocal).client(secrets: InMemorySecretStore())
    }

    @Test func writingTasksGetTwiceTheTime() {
        let writing: [TaskID] = [
            .importResume, .writeSummary, .writeSkills, .writeExperience, .writeProjects, .rewriteSection, .gapBullets,
            .coverLetter,
        ]
        for task in TaskID.catalog {
            #expect(TaskDefaults.catalog[task]?.timeoutSeconds == (writing.contains(task) ? 120 : 60), "\(task)")
        }
    }

    @Test func everyCatalogTaskHasDefaults() {
        #expect(Set(TaskDefaults.catalog.keys) == Set(TaskID.catalog))
        #expect(
            TaskDefaults.catalog[.analyzeJob]
                == TaskDefaults(
                    budget: TokenBudget(input: 7_000, output: 1_500), temperature: 0, modelClass: .flashLite))
        #expect(TaskDefaults.catalog[.coverLetter]?.temperature == 0.6)
    }

    @Test(arguments: [
        (LLMError.server(status: 503), "server_503"), (.rateLimited(retryAfterSeconds: 1), "rate_limited"),
        (.invalidOutput("\"Rust\" isn't in the posting"), "invalid_output"), (.noKey(provider: "p"), "no_key"),
    ])
    func errorCodesCarryNoText(error: LLMError, code: String) {
        #expect(error.code == code)
    }
}

/// Who hears a call: every event in order, from any thread.
private final class Heard: Sendable {
    private let events = Mutex<[CallEvent]>([])
    var all: [CallEvent] { events.withLock { $0 } }
    func add(_ event: CallEvent) { events.withLock { $0.append(event) } }
}

@Suite("LLM router: failover events")
struct RouterFailoverTests {
    /// Gemini overloaded twice (one quick retry, since another model waits), then the fallback
    /// answers: the build hears each step, and a slow model isn't waited out.
    @Test func anOverloadedModelHandsOverToTheNextAndSaysSo() async throws {
        let db = try await database()
        let busy = FakeProvider([.analyzeJob: [.failure(.server(status: 503)), .failure(.server(status: 503))]])
        let spare = FakeProvider([.analyzeJob: [.reply(valid)]])
        let heard = Heard()
        let result = try await router(db, providers: ["gemini": busy, "ollama": spare], chain: [gemini, ollama])
            .run(RequirementsTask(), input: posting, context: CallContext(buildID: "b1", events: heard.add))
        #expect(result.outcome == .fellBack && busy.requests.count == 2)
        guard case .answered(.analyzeJob, ollama, _, false)? = heard.all.last else {
            Issue.record("\(heard.all)")
            return
        }
        #expect(
            Array(heard.all.dropLast()) == [
                .asking(task: .analyzeJob, model: gemini, fallback: false),
                .retrying(task: .analyzeJob, model: gemini, reason: "was overloaded (503)"),
                .failed(task: .analyzeJob, model: gemini, reason: "was overloaded (503)", detail: nil),
                .asking(task: .analyzeJob, model: ollama, fallback: true),
            ])
    }

    /// The last model in a chain keeps its full retries, and a cached answer is heard as one.
    @Test func theLastModelRetriesInFullAndACachedAnswerIsHeard() async throws {
        let db = try await database()
        let flaky = FakeProvider([
            .analyzeJob: [.failure(.server(status: 503)), .failure(.server(status: 503)), .reply(valid)]
        ])
        let route = router(db, providers: ["gemini": flaky], chain: [gemini])
        let first = Heard()
        _ = try await route.run(RequirementsTask(), input: posting, context: CallContext(events: first.add))
        #expect(flaky.requests.count == 3 && first.all.count { if case .retrying = $0 { true } else { false } } == 2)
        let again = Heard()
        _ = try await route.run(RequirementsTask(), input: posting, context: CallContext(events: again.add))
        #expect(again.all == [.answered(task: .analyzeJob, model: gemini, seconds: 0, cached: true)])
    }

    /// A reply that fails its checks twice moves on too, and the check's finding goes with it.
    @Test func aFailedCheckMovesOnWithWhatItFound() async throws {
        let db = try await database()
        let wrong = FakeProvider([.analyzeJob: [.reply("{}"), .reply("{}")]])
        let spare = FakeProvider([.analyzeJob: [.reply(valid)]])
        let heard = Heard()
        _ = try await router(db, providers: ["gemini": wrong, "ollama": spare], chain: [gemini, ollama])
            .run(RequirementsTask(), input: posting, context: CallContext(events: heard.add))
        let failure = heard.all.first { if case .failed = $0 { true } else { false } }
        guard case .failed(_, gemini, let reason, let detail?)? = failure else {
            Issue.record("\(heard.all)")
            return
        }
        #expect(reason == "replied in a form that failed its checks" && !detail.isEmpty)
    }

    /// Two contexts for the same calls are equal whoever listens.
    @Test func whoListensDoesntChangeTheContext() {
        #expect(CallContext(jobID: "j", events: { _ in }) == CallContext(jobID: "j"))
        #expect(CallContext(jobID: "j") != CallContext(jobID: "k"))
    }
}
