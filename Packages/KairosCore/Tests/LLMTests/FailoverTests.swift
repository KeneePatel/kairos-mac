import Foundation
import Synchronization
import Testing

@testable import LLM

private func request(model: String = "flash") -> ChatRequest {
    ChatRequest(
        task: .analyzeJob, model: model, messages: [.user("x")], schema: nil, temperature: 0, maxOutputTokens: 100)
}

private func client(_ keys: [FakeProvider], effort: ReasoningEffort? = nil) -> (LLMClient, VirtualClock) {
    let clock = VirtualClock()
    let policy = ClientPolicy(requestsPerMinute: 600, maxConcurrent: 2, defaultReasoningEffort: effort)
    return (LLMClient(keys: keys, policy: policy, clock: clock, jitter: { 1.0 }), clock)
}

/// What each try heard, from any thread.
private final class Tries: Sendable {
    private let errors = Mutex<[LLMError]>([])
    var all: [LLMError] { errors.withLock { $0 } }
    func add(_ error: LLMError) { errors.withLock { $0.append(error) } }
}

@Suite("LLM client: failing fast")
struct FailFastTests {
    /// With another model waiting, a timeout isn't tried again: it was slow, the next may not be.
    @Test func aTimeoutGivesUpAtOnce() async throws {
        let key = FakeProvider([.analyzeJob: [.failure(.timedOut), .reply("never")]])
        let (client, clock) = client([key])
        await #expect(throws: LLMError.timedOut) { try await client.complete(request(), failFast: true) }
        #expect(key.requests.count == 1 && clock.sleeps.isEmpty)
    }

    /// Alone in its chain, a model that timed out is asked once more, not twice.
    @Test func aTimeoutIsRetriedOnceAtMost() async throws {
        let key = FakeProvider([.analyzeJob: [.failure(.timedOut), .failure(.timedOut), .reply("never")]])
        let (patient, _) = client([key])
        await #expect(throws: LLMError.timedOut) { try await patient.complete(request()) }
        #expect(key.requests.count == 2)
    }

    /// An overloaded or unreachable model gets one quick retry, and each is heard.
    @Test func anOverloadIsRetriedOnce() async throws {
        let key = FakeProvider([.analyzeJob: Array(repeating: .failure(.server(status: 503)), count: 3)])
        let (client, clock) = client([key])
        let tries = Tries()
        await #expect(throws: LLMError.server(status: 503)) {
            try await client.complete(request(), failFast: true, retrying: tries.add)
        }
        #expect(key.requests.count == 2 && clock.sleeps == [.seconds(1)] && tries.all == [.server(status: 503)])
    }

    /// Every key resting isn't waited out when another model could answer now.
    @Test func aRateLimitOnEveryKeyIsntWaitedOut() async throws {
        let key = FakeProvider([.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: 30)), .reply("later")]])
        let (hasty, clock) = client([key])
        await #expect(throws: LLMError.rateLimited(retryAfterSeconds: 30)) {
            try await hasty.complete(request(), failFast: true)
        }
        #expect(key.requests.count == 1 && clock.sleeps.isEmpty)
        // Alone in its chain, it waits as before, and says so.
        let alone = FakeProvider([.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: 30)), .reply("ok")]])
        let (patient, patientClock) = client([alone])
        let tries = Tries()
        #expect(try await patient.complete(request(), retrying: tries.add).response.text == "ok")
        #expect(patientClock.sleeps == [.seconds(30)] && tries.all == [.rateLimited(retryAfterSeconds: 30)])
    }
}

@Suite("Reasoning effort")
struct ReasoningEffortTests {
    /// gpt-oss can't stop reasoning, so "none" becomes "low"; other models keep what was asked.
    @Test func gptOssReasonsLowWhenAskedForNone() async throws {
        let key = FakeProvider([.analyzeJob: [.reply("a"), .reply("b"), .reply("c")]])
        let (client, _) = client([key], effort: ReasoningEffort.none)
        _ = try await client.complete(request(model: "gpt-oss:120b"))
        _ = try await client.complete(request(model: "gemma4:31b"))
        _ = try await client.complete(request(model: "GPT-OSS:20b-cloud"))
        #expect(key.requests.map(\.reasoningEffort) == [.low, ReasoningEffort.none, .low])
        #expect(ReasoningEffort.fitting(.high, model: "gpt-oss:120b") == .high)
        #expect(ReasoningEffort.fitting(nil, model: "gpt-oss:120b") == nil)
    }

    /// Ollama, here or in its cloud, thinks only when asked; Gemini decides for itself.
    @Test func ollamaThinksOnlyWhenAsked() {
        #expect(ProviderPreset.ollamaCloud.reasoningDefault == ReasoningEffort.none)
        #expect(ProviderPreset.ollamaLocal.reasoningDefault == ReasoningEffort.none)
        #expect(ProviderPreset.gemini.reasoningDefault == nil)
        #expect(ClientPolicy(preset: .ollamaCloud).defaultReasoningEffort == ReasoningEffort.none)
    }
}

@Suite("Provider errors")
struct ProviderErrorTests {
    private func error(_ status: Int, _ message: String) -> LLMError {
        let response = HTTPURLResponse(
            url: URL(string: "https://ollama.com/v1/chat/completions")!, statusCode: status, httpVersion: nil,
            headerFields: nil)!
        return OpenAICompatibleProvider.error(
            status: status, message: message, response: response, data: Data(), model: "deepseek-v4.1-flash",
            provider: "Ollama Cloud")
    }

    /// Ollama's 402 and its 403 for a model still rolling out are about the model, in its words;
    /// any other 401 or 403 is the key.
    @Test func ollamasPaymentAndRolloutAnswersAreAboutTheModel() {
        let credits =
            "this model is not included in your free usage, add usage credits to pay as you go: https://ollama.com/settings or upgrade for included usage. Try gemma4:31b-cloud, which is in the Free plan. (ref: 7b3a794e-1f7e)"
        #expect(
            error(402, credits)
                == .modelUnavailable(
                    model: "deepseek-v4.1-flash", reason: "said: this model is not included in your free usage"))
        let rollout =
            "This model is currently being rolled out and is not yet available to you. Please check back later. (ref: ae86fe82)"
        #expect(
            error(403, rollout)
                == .modelUnavailable(
                    model: "deepseek-v4.1-flash",
                    reason: "said: this model is currently being rolled out and is not yet available to you"))
        #expect(error(403, "Forbidden: invalid API key") == .keyRejected(provider: "Ollama Cloud"))
        #expect(error(401, "") == .keyRejected(provider: "Ollama Cloud"))
        #expect(
            error(402, "") == .modelUnavailable(model: "deepseek-v4.1-flash", reason: "wants payment for this model"))
    }

    @Test func everyErrorHasAPlainReasonAndOnlyTwoStopEverything() {
        #expect(LLMError.server(status: 503).reason == "was overloaded (503)")
        #expect(LLMError.server(status: 500).reason == "had a server error (500)")
        #expect(LLMError.timedOut.reason == "didn't answer in time")
        #expect(LLMError.modelUnavailable(model: "m", reason: "said: no").reason == "said: no")
        #expect(LLMError.modelUnavailable(model: "m", reason: "x").code == "model_unavailable")
        let all: [LLMError] = [
            .keyRejected(provider: "p"), .modelNotFound("m"), .badRequest("b"), .rateLimited(retryAfterSeconds: 1),
            .modelNotOnPlan("m"), .modelUnavailable(model: "m", reason: "r"), .server(status: 502), .network("n"),
            .timedOut, .cancelled, .invalidJSON("j"), .invalidOutput("o"), .budgetReached, .noProvider(.analyzeJob),
            .noKey(provider: "p"), .noScriptedReply(.analyzeJob),
        ]
        #expect(all.allSatisfy { !$0.reason.isEmpty })
        #expect(all.filter(\.stopsEverything) == [.cancelled, .budgetReached])
    }
}
