import Foundation

/// How a client treats one provider (SPEC §5.5, Reliability).
public struct ClientPolicy: Sendable, Equatable {
    public var requestsPerMinute: Int
    public var maxConcurrent: Int
    /// Tries for network errors and temporary server errors, the first included.
    public var attempts = 3
    public var backoffBase: Duration = .seconds(1)
    /// No wait is longer, whatever a provider asks (T20 saw a 14-hour retry delay).
    public var maxWait: Duration = .seconds(60)
    /// Used when a request doesn't say. Local models think only when asked (decided 2026-10-19).
    public var defaultReasoningEffort: ReasoningEffort?

    public init(requestsPerMinute: Int, maxConcurrent: Int = 2, defaultReasoningEffort: ReasoningEffort? = nil) {
        self.requestsPerMinute = requestsPerMinute
        self.maxConcurrent = maxConcurrent
        self.defaultReasoningEffort = defaultReasoningEffort
    }

    public init(preset: ProviderPreset) {
        self.init(
            requestsPerMinute: preset.requestsPerMinute,
            defaultReasoningEffort: preset.isLocal ? ReasoningEffort.none : nil)
    }
}

/// What a task run needs besides its input.
public struct RunOptions: Sendable {
    public var model: String
    public var budget: TokenBudget
    public var temperature: Double
    public var reasoningEffort: ReasoningEffort?
    public var timeoutSeconds: Int?

    public init(
        model: String, budget: TokenBudget, temperature: Double, reasoningEffort: ReasoningEffort? = nil,
        timeoutSeconds: Int? = nil
    ) {
        self.model = model
        self.budget = budget
        self.temperature = temperature
        self.reasoningEffort = reasoningEffort
        self.timeoutSeconds = timeoutSeconds
    }
}

/// One model call after retries and key rotation.
public struct Completion: Sendable {
    public let response: ChatResponse
    /// Provider calls made, failed ones included.
    public let attempts: Int
    public let provider: String
}

/// Calls one provider through its pool of keys: rate limits, retries with backoff and jitter, key
/// rotation on 429, and, for typed tasks, the output checks with one repair call (SPEC §5.5).
/// Choosing providers and models, the fallback chain, the budget and the cache belong to the router.
public actor LLMClient {
    private let keys: [any LLMProvider]
    private let policy: ClientPolicy
    private let clock: any LLMClock
    private let limiter: RateLimiter
    private let jitter: @Sendable () -> Double
    /// The key that last worked; calls start there.
    private var current = 0
    /// Keys a 429 told to rest, and until when.
    private var restingUntil: [Int: Duration] = [:]

    /// `keys` holds one provider per key, all for the same service.
    public init(
        keys: [any LLMProvider], policy: ClientPolicy, clock: any LLMClock = SystemClock(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1.5) }
    ) {
        self.keys = keys
        self.policy = policy
        self.clock = clock
        self.jitter = jitter
        limiter = RateLimiter(
            requestsPerMinute: policy.requestsPerMinute, maxConcurrent: policy.maxConcurrent, clock: clock)
    }

    public func complete(_ request: ChatRequest) async throws(LLMError) -> Completion {
        guard !keys.isEmpty else { throw .noProvider(request.task) }
        let request = withDefaults(request)
        var attempts = 0
        var failures = 0
        var waits = 0
        var lastDelay: Int?
        var offPlan: Set<Int> = []
        while true {
            if Task.isCancelled { throw .cancelled }
            guard let index = nextKey(skipping: offPlan) else {
                if offPlan.count == keys.count { throw .modelNotOnPlan(request.model) }
                // Every usable key is resting: wait for the first, if that's soon enough.
                let wait = (restingUntil.values.min() ?? clock.now) - clock.now
                waits += 1
                guard wait <= policy.maxWait, waits <= policy.attempts else {
                    throw .rateLimited(retryAfterSeconds: lastDelay)
                }
                try await clock.sleep(for: max(wait, .zero))
                continue
            }
            try await limiter.acquire()
            attempts += 1
            let outcome: Result<ChatResponse, LLMError>
            do {
                outcome = .success(try await keys[index].complete(request))
            } catch {
                outcome = .failure(error)
            }
            await limiter.release()

            switch outcome {
            case .success(let response):
                current = index
                return Completion(response: response, attempts: attempts, provider: keys[index].name)
            case .failure(.rateLimited(let delay)):
                lastDelay = delay
                restingUntil[index] = clock.now + .seconds(delay ?? 60)
            case .failure(.modelNotOnPlan):
                // Another key may be on a plan that has this model.
                offPlan.insert(index)
            case .failure(let error) where Self.isTemporary(error):
                failures += 1
                guard failures < policy.attempts else { throw error }
                try await clock.sleep(for: backoff(after: failures))
            case .failure(let error):
                throw error
            }
        }
    }

    /// Runs a typed task: one call, then the output checks, then at most one repair call that
    /// quotes what was wrong (SPEC §5.5, "Structured output").
    public func run<T: LLMTask>(_ task: T, input: T.Input, options: RunOptions) async throws(LLMError) -> LLMResult<
        T.Output
    > {
        let started = clock.now
        var messages = task.messages(for: input, budget: options.budget)
        let first = try await complete(chat(T.self, messages, options))
        var calls = [first]
        var outcome = LLMOutcome.ok
        var result = OutputPipeline.output(from: first.response, task: task, input: input)
        if case .failure(let problem) = result {
            messages += [.assistant(first.response.text), .user(OutputPipeline.repairNote(problem))]
            let repair = try await complete(chat(T.self, messages, options))
            calls.append(repair)
            outcome = .repaired
            result = OutputPipeline.output(from: repair.response, task: task, input: input)
        }
        switch result {
        case .failure(let problem):
            throw .invalidOutput(problem.description)
        case .success(let output):
            let last = calls[calls.count - 1]
            return LLMResult(
                output: output, provider: last.provider, model: last.response.model,
                inputTokens: Self.sum(calls.map(\.response.inputTokens)),
                outputTokens: Self.sum(calls.map(\.response.outputTokens)), latency: clock.now - started,
                outcome: outcome, attempts: calls.reduce(0) { $0 + $1.attempts },
                json: OutputPipeline.unfenced(last.response.text))
        }
    }

    // MARK: - Helpers

    private func chat<T: LLMTask>(_ type: T.Type, _ messages: [ChatMessage], _ options: RunOptions) -> ChatRequest {
        ChatRequest(
            task: T.id, model: options.model, messages: messages, schema: T.outputSchema,
            temperature: options.temperature, maxOutputTokens: options.budget.output,
            reasoningEffort: options.reasoningEffort, timeoutSeconds: options.timeoutSeconds)
    }

    private func withDefaults(_ request: ChatRequest) -> ChatRequest {
        guard request.reasoningEffort == nil, let effort = policy.defaultReasoningEffort else { return request }
        return ChatRequest(
            task: request.task, model: request.model, messages: request.messages, schema: request.schema,
            temperature: request.temperature, maxOutputTokens: request.maxOutputTokens, reasoningEffort: effort,
            timeoutSeconds: request.timeoutSeconds)
    }

    /// The key to use: the last one that worked, else the next that isn't resting or off this plan.
    private func nextKey(skipping offPlan: Set<Int>) -> Int? {
        let now = clock.now
        for step in 0..<keys.count {
            let index = (current + step) % keys.count
            if offPlan.contains(index) { continue }
            if let until = restingUntil[index], until > now { continue }
            restingUntil[index] = nil
            return index
        }
        return nil
    }

    /// 1 s, 2 s, 4 s … times a jitter factor, never more than `maxWait`.
    private func backoff(after failures: Int) -> Duration {
        let base = Double(RateLimiter.milliseconds(policy.backoffBase))
        let milliseconds = (base * pow(2, Double(failures - 1)) * jitter()).rounded()
        return min(.milliseconds(Int64(milliseconds)), policy.maxWait)
    }

    /// Network trouble and server errors that may pass. 501 never does (T20).
    private static func isTemporary(_ error: LLMError) -> Bool {
        switch error {
        case .network, .timedOut: true
        case .server(let status): status >= 500 && status != 501
        default: false
        }
    }

    private static func sum(_ values: [Int?]) -> Int? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}
