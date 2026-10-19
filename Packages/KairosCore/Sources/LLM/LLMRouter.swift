import Foundation
import Secrets

/// A model at a configured provider: one link in a task's chain.
public struct ModelRef: Hashable, Sendable {
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// Which job or build a call was for, so the log can link them.
public struct CallContext: Sendable, Equatable {
    public var jobID: String?
    public var buildID: String?

    public init(jobID: String? = nil, buildID: String? = nil) {
        self.jobID = jobID
        self.buildID = buildID
    }
}

/// A provider the user added: its preset and the names of its keys. The keys themselves are read
/// from the Keychain only when a client is built, and never stored anywhere else.
public struct ProviderSetup: Sendable, Equatable {
    public let id: String
    public let preset: ProviderPreset
    public let keyNames: [SecretKey]

    public init(id: String, preset: ProviderPreset, keyNames: [SecretKey] = []) {
        self.id = id
        self.preset = preset
        self.keyNames = keyNames
    }

    /// A client over every key found, which together form the rotation pool.
    public func client(
        secrets: any SecretStore, capabilities: ModelCapabilities = ModelCapabilities(),
        transport: any LLMTransport = URLSessionTransport(), clock: any LLMClock = SystemClock()
    ) throws(LLMError) -> LLMClient {
        let keys: [String?]
        if preset.needsKey {
            keys = keyNames.compactMap { name in (try? secrets.read(name)) ?? nil }.filter { !$0.isEmpty }
            guard !keys.isEmpty else { throw .noKey(provider: preset.name) }
        } else {
            keys = [nil]
        }
        let providers: [any LLMProvider] = keys.map {
            OpenAICompatibleProvider(preset: preset, key: $0, transport: transport, capabilities: capabilities)
        }
        return LLMClient(keys: providers, policy: ClientPolicy(preset: preset), clock: clock)
    }
}

/// Picks a provider and model for each task and walks its fallback chain, within the daily budget,
/// through the cache, logging every call (SPEC §5.5, Layers).
public actor LLMRouter {
    private let clients: [String: LLMClient]
    private let routes: [TaskID: [ModelRef]]
    private let budget: Budget
    private let log: CallLog
    private let cache: ResultCache?
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// `routes` lists each task's models, primary first; `clients` is keyed by provider id.
    public init(
        clients: [String: LLMClient], routes: [TaskID: [ModelRef]], budget: Budget, log: CallLog, cache: ResultCache?,
        now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current
    ) {
        self.clients = clients
        self.routes = routes
        self.budget = budget
        self.log = log
        self.cache = cache
        self.now = now
        self.calendar = calendar
    }

    public func run<T: LLMTask>(_ task: T, input: T.Input, context: CallContext = CallContext()) async throws(LLMError)
        -> LLMResult<T.Output>
    {
        guard let chain = routes[T.id], !chain.isEmpty else { throw .noProvider(T.id) }
        let defaults = TaskDefaults.catalog[T.id] ?? .fallback
        let messages = task.messages(for: input, budget: defaults.budget)
        var lastError = LLMError.noProvider(T.id)

        for (position, ref) in chain.enumerated() {
            let key = ResultCache.Key(task: T.id, messages: messages, promptVersion: T.promptVersion, model: ref.model)
            if let cached = await cachedOutput(task, input: input, key: key, ref: ref) { return cached }
            try await checkBudget()
            guard let client = clients[ref.provider] else {
                lastError = .noProvider(T.id)
                continue
            }
            let started = now()
            do {
                let options = RunOptions(
                    model: ref.model, budget: defaults.budget, temperature: defaults.temperature,
                    timeoutSeconds: defaults.timeoutSeconds)
                let result = try await client.run(task, input: input, options: options)
                let outcome = position == 0 ? result.outcome : .fellBack
                await record(
                    T.self, ref: ref, result: result, outcome: outcome, error: nil, started: started, context: context)
                if let cache { try? await cache.store(result.json, for: key, at: now()) }
                return LLMResult(
                    output: result.output, provider: result.provider, model: result.model,
                    inputTokens: result.inputTokens,
                    outputTokens: result.outputTokens, latency: result.latency, outcome: outcome,
                    attempts: result.attempts,
                    json: result.json)
            } catch {
                let outcome: LLMOutcome = if case .rateLimited = error { .rateLimited } else { .failed }
                await record(
                    T.self, ref: ref, result: nil, outcome: outcome, error: error, started: started, context: context)
                // Stopping is the user's call; everything else may work on the next provider.
                if error == .cancelled || error == .budgetReached { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// Provider calls and tokens so far today, for Settings and the Activity screen.
    public func usageToday() async throws -> Usage {
        try await log.usage(since: calendar.startOfDay(for: now()))
    }

    // MARK: - Helpers

    private func cachedOutput<T: LLMTask>(_ task: T, input: T.Input, key: ResultCache.Key, ref: ModelRef) async
        -> LLMResult<T.Output>?
    {
        guard let cache, let text = try? await cache.output(for: key) else { return nil }
        let response = ChatResponse(text: text, model: ref.model, inputTokens: nil, outputTokens: nil)
        // A cached reply passes the same checks as a fresh one; a task whose check changed refetches.
        guard case .success(let output) = OutputPipeline.output(from: response, task: task, input: input) else {
            return nil
        }
        return LLMResult(
            output: output, provider: ref.provider, model: ref.model, inputTokens: nil, outputTokens: nil,
            latency: .zero,
            outcome: .cached, attempts: 0, json: text)
    }

    private func checkBudget() async throws(LLMError) {
        guard let usage = try? await usageToday() else { return }
        if !budget.allows(usage) { throw .budgetReached }
    }

    private func record<T: LLMTask>(
        _ type: T.Type, ref: ModelRef, result: LLMResult<T.Output>?, outcome: LLMOutcome, error: LLMError?,
        started: Date,
        context: CallContext
    ) async {
        let elapsed = now().timeIntervalSince(started)
        let call = CallRecord(
            at: started, task: T.id, provider: ref.provider, model: result?.model ?? ref.model,
            promptVersion: T.promptVersion, inputTokens: result?.inputTokens, outputTokens: result?.outputTokens,
            latency: result?.latency ?? .milliseconds(Int64(max(0, elapsed * 1_000))), attempts: result?.attempts ?? 1,
            outcome: outcome, errorCode: error?.code, jobID: context.jobID, buildID: context.buildID)
        // Losing a log row must never fail the task itself.
        try? await log.record(call)
    }
}
