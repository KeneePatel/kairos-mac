import Foundation
import Synchronization
import Testing

@testable import LLM

/// Time that passes only when something sleeps: every sleep returns at once and moves `now` on, so
/// waits are recorded exactly and tests never actually wait.
final class VirtualClock: LLMClock {
    private let state = Mutex((now: Duration.zero, sleeps: [Duration]()))

    var now: Duration { state.withLock { $0.now } }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func advance(by duration: Duration) {
        state.withLock { $0.now += duration }
    }

    func sleep(for duration: Duration) async throws(LLMError) {
        guard !Task.isCancelled else { throw .cancelled }
        state.withLock {
            $0.sleeps.append(duration)
            $0.now += duration
        }
    }
}

/// A typed task for the pipeline tests: requirements with a must/nice kind.
struct RequirementsTask: LLMTask {
    struct Requirement: Decodable, Sendable, Equatable {
        let text: String
        let kind: String
    }
    struct Output: Decodable, Sendable, Equatable {
        let requirements: [Requirement]
        let yearsRequired: Int
    }

    static let id = TaskID.analyzeJob
    static let promptVersion = 1
    static let outputSchema = JSONSchema.object([
        .required(
            "requirements",
            .array(
                of: .object([
                    .required("text", .string(maxLength: 80)), .required("kind", .enumeration(["must", "nice"])),
                ]))),
        .required("years_required", .integer(minimum: 0, maximum: 40)),
    ])

    func messages(for input: String, budget: TokenBudget) -> [ChatMessage] {
        [.system("Extract requirements."), .user("<job_posting>\(input)</job_posting>")]
    }

    /// A rule the schema can't express: nothing outside the posting.
    func check(_ output: Output, for input: String) throws {
        for requirement in output.requirements where !input.lowercased().contains(requirement.text.lowercased()) {
            throw LLMError.invalidOutput("\"\(requirement.text)\" isn't in the posting")
        }
    }
}

private let posting = "Go and PostgreSQL required; Kafka is a plus. 3 years."
private let valid = #"{"requirements":[{"text":"Go","kind":"must"},{"text":"Kafka","kind":"nice"}],"years_required":3}"#
private let options = RunOptions(model: "flash", budget: TokenBudget(input: 4_000, output: 1_000), temperature: 0)

private func request(_ effort: ReasoningEffort? = nil) -> ChatRequest {
    ChatRequest(
        task: .analyzeJob, model: "flash", messages: [.user("x")], schema: nil, temperature: 0, maxOutputTokens: 100,
        reasoningEffort: effort)
}

private func client(_ keys: [FakeProvider], rpm: Int = 600, effort: ReasoningEffort? = nil) -> (LLMClient, VirtualClock)
{
    let clock = VirtualClock()
    let policy = ClientPolicy(requestsPerMinute: rpm, maxConcurrent: 2, defaultReasoningEffort: effort)
    return (LLMClient(keys: keys, policy: policy, clock: clock, jitter: { 1.0 }), clock)
}

@Suite("Rate limiter")
struct RateLimiterTests {
    @Test func allowsABurstUpToTheLimitThenSpacesRequestsOut() async throws {
        let clock = VirtualClock()
        let limiter = RateLimiter(requestsPerMinute: 10, maxConcurrent: 100, clock: clock)
        for _ in 0..<12 {
            try await limiter.acquire()
            await limiter.release()
        }
        #expect(clock.sleeps == [.seconds(6), .seconds(6)])  // 10 a minute: one every 6 s once the burst is spent
    }

    @Test func refillsWhileIdle() async throws {
        let clock = VirtualClock()
        let limiter = RateLimiter(requestsPerMinute: 10, maxConcurrent: 100, clock: clock)
        for _ in 0..<10 {
            try await limiter.acquire()
            await limiter.release()
        }
        clock.advance(by: .seconds(60))
        for _ in 0..<10 {
            try await limiter.acquire()
            await limiter.release()
        }
        #expect(clock.sleeps.isEmpty)
    }

    @Test func noMoreThanTheConcurrencyCapRunAtOnce() async throws {
        let limiter = RateLimiter(requestsPerMinute: 10_000, maxConcurrent: 2, clock: VirtualClock())
        let gauge = Mutex((now: 0, peak: 0))
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await limiter.acquire()
                    gauge.withLock {
                        $0.now += 1
                        $0.peak = max($0.peak, $0.now)
                    }
                    try await Task.sleep(for: .milliseconds(15))
                    gauge.withLock { $0.now -= 1 }
                    await limiter.release()
                }
            }
        }
        #expect(gauge.withLock { $0.peak } == 2)
    }

    @Test func aWaiterThatIsCancelledLeavesTheQueue() async throws {
        let limiter = RateLimiter(requestsPerMinute: 10_000, maxConcurrent: 1, clock: VirtualClock())
        try await limiter.acquire()
        let waiter = Task { try await limiter.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: LLMError.cancelled) { try await waiter.value }
        await limiter.release()
        try await limiter.acquire()  // the slot wasn't handed to the cancelled waiter
    }
}

@Suite("LLM client: retries and keys")
struct LLMClientRetryTests {
    @Test func retriesNetworkAndServerErrorsWithBackoff() async throws {
        let key = FakeProvider([
            .analyzeJob: [.failure(.network("offline")), .failure(.server(status: 503)), .reply("ok")]
        ])
        let (client, clock) = client([key])
        let completion = try await client.complete(request())
        #expect(completion.response.text == "ok" && completion.attempts == 3)
        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
    }

    @Test func givesUpAfterThreeAttempts() async throws {
        let key = FakeProvider([.analyzeJob: Array(repeating: .failure(.server(status: 500)), count: 4)])
        let (client, clock) = client([key])
        await #expect(throws: LLMError.server(status: 500)) { try await client.complete(request()) }
        #expect(key.requests.count == 3 && clock.sleeps == [.seconds(1), .seconds(2)])
    }

    @Test(arguments: [
        LLMError.badRequest("bad"), .keyRejected(provider: "p"), .modelNotFound("m"), .server(status: 501),
        .invalidJSON("x"), .invalidOutput("y"), .budgetReached,
    ])
    func neverRetries(_ error: LLMError) async throws {
        let key = FakeProvider([.analyzeJob: [.failure(error), .reply("ok")]])
        let (client, clock) = client([key])
        await #expect(throws: error) { try await client.complete(request()) }
        #expect(key.requests.count == 1 && clock.sleeps.isEmpty)
    }

    @Test func aRateLimitedKeyHandsOverToTheNextAtOnce() async throws {
        let first = FakeProvider([.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: 30))]], name: "key-1")
        let second = FakeProvider([.analyzeJob: [.reply("ok"), .reply("again")]], name: "key-2")
        let (client, clock) = client([first, second])
        #expect(try await client.complete(request()).response.text == "ok")
        #expect(try await client.complete(request()).response.text == "again")  // key-1 is still resting
        #expect(first.requests.count == 1 && clock.sleeps.isEmpty)
    }

    @Test func whenEveryKeyIsLimitedItWaitsForTheFirstToRecover() async throws {
        let first = FakeProvider(
            [.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: 20)), .reply("ok")]], name: "key-1")
        let second = FakeProvider([.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: 45))]], name: "key-2")
        let (client, clock) = client([first, second])
        #expect(try await client.complete(request()).response.text == "ok")
        #expect(clock.sleeps == [.seconds(20)])
    }

    @Test func neverWaitsMoreThanAMinute() async throws {
        // T20: a free-tier 429 asked for 51,393 s.
        let key = FakeProvider([.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: 51_393)), .reply("never")]])
        let (client, clock) = client([key])
        await #expect(throws: LLMError.rateLimited(retryAfterSeconds: 51_393)) { try await client.complete(request()) }
        #expect(clock.sleeps.isEmpty && key.requests.count == 1)
    }

    @Test func aRateLimitWithoutADelayWaitsAMinuteAtMost() async throws {
        let key = FakeProvider([.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: nil)), .reply("ok")]])
        let (client, clock) = client([key])
        #expect(try await client.complete(request()).response.text == "ok")
        #expect(clock.sleeps == [.seconds(60)])
    }

    @Test func aModelOffOnePlanTriesTheOtherKeysOnly() async throws {
        let free = FakeProvider([.analyzeJob: [.failure(.modelNotOnPlan("flash"))]], name: "free")
        let paid = FakeProvider([.analyzeJob: [.reply("ok")]], name: "paid")
        let (pooled, clock) = client([free, paid])
        #expect(try await pooled.complete(request()).response.text == "ok")
        let (lonely, _) = client([FakeProvider([.analyzeJob: [.failure(.modelNotOnPlan("flash"))]])])
        await #expect(throws: LLMError.modelNotOnPlan("flash")) { try await lonely.complete(request()) }
        #expect(clock.sleeps.isEmpty)
    }

    @Test func cancellingStopsTheCallAndTheBackoff() async throws {
        let slow = SlowProvider()
        let busy = LLMClient(keys: [slow], policy: ClientPolicy(requestsPerMinute: 600), clock: VirtualClock())
        let call = Task { try await busy.complete(request()) }
        try await Task.sleep(for: .milliseconds(30))
        call.cancel()
        await #expect(throws: LLMError.cancelled) { try await call.value }
        #expect(slow.sawCancellation)
    }

    @Test func localModelsThinkOnlyWhenAsked() async throws {
        let key = FakeProvider([.analyzeJob: [.reply("a"), .reply("b")]])
        let (client, _) = client([key], effort: ReasoningEffort.none)
        _ = try await client.complete(request())
        _ = try await client.complete(request(.high))
        #expect(key.requests.map(\.reasoningEffort) == [ReasoningEffort.none, .high])
    }

    @Test func policyFollowsThePreset() {
        let local = ClientPolicy(preset: .ollamaLocal)
        #expect(local.defaultReasoningEffort == ReasoningEffort.none && local.requestsPerMinute == 30)
        let cloud = ClientPolicy(preset: .gemini)
        #expect(cloud.defaultReasoningEffort == nil && cloud.requestsPerMinute == 10 && cloud.maxConcurrent == 2)
    }

    @Test func anEmptyKeyPoolIsAnError() async {
        let (client, _) = client([])
        await #expect(throws: LLMError.noProvider(.analyzeJob)) { try await client.complete(request()) }
    }
}

/// Suspends until cancelled, like a request still in flight.
private final class SlowProvider: LLMProvider {
    let name = "slow"
    private let cancelled = Mutex(false)
    var sawCancellation: Bool { cancelled.withLock { $0 } }

    func complete(_ request: ChatRequest) async throws(LLMError) -> ChatResponse {
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancelled.withLock { $0 = true }
            throw .cancelled
        }
        return ChatResponse(text: "late", model: request.model, inputTokens: nil, outputTokens: nil)
    }
}

@Suite("LLM client: output pipeline and repair")
struct LLMClientPipelineTests {
    @Test func returnsTheTypedOutput() async throws {
        let key = FakeProvider([.analyzeJob: [.reply(valid, inputTokens: 40, outputTokens: 30)]])
        let (client, _) = client([key])
        let result = try await client.run(RequirementsTask(), input: posting, options: options)
        #expect(result.output.requirements.map(\.text) == ["Go", "Kafka"] && result.output.yearsRequired == 3)
        #expect(result.outcome == .ok && result.attempts == 1)
        #expect(result.inputTokens == 40 && result.outputTokens == 30 && result.provider == "fake")
        let sent = try #require(key.requests.first)
        #expect(sent.schema == RequirementsTask.outputSchema && sent.maxOutputTokens == 1_000)
        #expect(sent.messages.last?.content == "<job_posting>\(posting)</job_posting>")
    }

    @Test func toleratesACodeFence() async throws {
        let (client, _) = client([FakeProvider([.analyzeJob: [.reply("```json\n\(valid)\n```")]])])
        #expect(try await client.run(RequirementsTask(), input: posting, options: options).outcome == .ok)
    }

    @Test func aSchemaProblemGetsOneRepairCallThatQuotesIt() async throws {
        let broken = #"{"requirements":[{"text":"Go","kind":"required"}]}"#
        let key = FakeProvider([
            .analyzeJob: [
                .reply(broken, inputTokens: 40, outputTokens: 20), .reply(valid, inputTokens: 90, outputTokens: 30),
            ]
        ])
        let (client, _) = client([key])
        let result = try await client.run(RequirementsTask(), input: posting, options: options)
        #expect(result.outcome == .repaired && result.attempts == 2)
        #expect(result.inputTokens == 130 && result.outputTokens == 50)  // both calls count toward the budget
        let repair = try #require(key.requests.last)
        #expect(repair.messages.count == 4)
        #expect(repair.messages[2] == .assistant(broken))
        let note = repair.messages[3].content
        #expect(note.contains("requirements[0].kind: expected one of must, nice"))
        #expect(note.contains("years_required: missing"))
    }

    @Test func aFailedCheckIsRepairedToo() async throws {
        let invented = #"{"requirements":[{"text":"Rust","kind":"must"}],"years_required":3}"#
        let key = FakeProvider([.analyzeJob: [.reply(invented), .reply(valid)]])
        let (client, _) = client([key])
        #expect(try await client.run(RequirementsTask(), input: posting, options: options).outcome == .repaired)
        #expect(key.requests.last?.messages.last?.content.contains(#""Rust" isn't in the posting"#) == true)
    }

    @Test(arguments: [
        ("not json at all", nil as String?, "isn't valid JSON"),
        (#"{"requirements":["#, "length", "cut off at the output limit"),
    ])
    func unreadableRepliesAreRepaired(reply: String, finish: String?, problem: String) async throws {
        let key = FakeProvider([.analyzeJob: [.reply(reply, finishReason: finish), .reply(valid)]])
        let (client, _) = client([key])
        #expect(try await client.run(RequirementsTask(), input: posting, options: options).outcome == .repaired)
        #expect(key.requests.last?.messages.last?.content.contains(problem) == true)
    }

    @Test func onlyOneRepairIsTried() async throws {
        let key = FakeProvider([.analyzeJob: [.reply("nope"), .reply(#"{"requirements":[]}"#), .reply(valid)]])
        let (client, _) = client([key])
        await #expect(throws: LLMError.invalidOutput("The reply doesn't match the schema: years_required: missing.")) {
            try await client.run(RequirementsTask(), input: posting, options: options)
        }
        #expect(key.requests.count == 2)
    }

    @Test func latencyIsMeasuredOnTheClock() async throws {
        let key = FakeProvider([.analyzeJob: [.failure(.server(status: 503)), .reply(valid)]])
        let (client, _) = client([key])
        let result = try await client.run(RequirementsTask(), input: posting, options: options)
        #expect(result.latency == .seconds(1) && result.attempts == 2)
    }
}
