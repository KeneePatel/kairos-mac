import Foundation
import KairosKit
import Secrets

/// Time for the router: injected so tests can run its waits instantly.
public protocol AIClock: Sendable {
    var now: Date { get }
    func sleep(seconds: Double) async throws(AIError)
}

public struct SystemAIClock: AIClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(seconds: Double) async throws(AIError) {
        guard seconds > 0 else { return }
        do {
            try await Task.sleep(for: .milliseconds(Int64(seconds * 1_000)))
        } catch {
            throw .cancelled
        }
    }
}

/// Sends one chat to one provider. The real one speaks HTTP; tests script replies by task.
public protocol ChatService: Sendable {
    func complete(_ request: ChatRequest, provider: AISettings.Provider, key: String?, mode: StructuredOutput)
        async throws(AIError) -> (ChatResponse, StructuredOutput)
    func listModels(provider: AISettings.Provider, key: String?) async throws(AIError) -> [String]
}

public struct HTTPChatService: ChatService {
    let http: any HTTPClient

    public init(http: any HTTPClient) { self.http = http }

    public func complete(_ request: ChatRequest, provider: AISettings.Provider, key: String?, mode: StructuredOutput)
        async throws(AIError) -> (ChatResponse, StructuredOutput)
    {
        try await OpenAICompatible(preset: provider.preset, http: http).complete(request, key: key, mode: mode)
    }

    public func listModels(provider: AISettings.Provider, key: String?) async throws(AIError) -> [String] {
        try await OpenAICompatible(preset: provider.preset, http: http).listModels(key: key)
    }
}

/// What happens to a task's calls as it happens, so a build can show it live. Reasons are a few
/// plain words; `detail` is what a check found in a reply, kept in memory only, never logged.
public enum AIEvent: Sendable, Equatable {
    case asking(task: TaskID, model: ModelRef, fallback: Bool)
    case retrying(task: TaskID, model: ModelRef, reason: String)
    case failed(task: TaskID, model: ModelRef, reason: String, detail: String?)
    case answered(task: TaskID, model: ModelRef, seconds: Double, cached: Bool)
}

/// Which job or build a call is for, and who hears its events.
public struct AIContext: Sendable {
    public var jobID: String?
    public var buildID: String?
    /// Ask again rather than reuse a cached answer (re-evaluating a job). The new answer is cached.
    public var fresh: Bool
    public var events: (@Sendable (AIEvent) -> Void)?

    public init(
        jobID: String? = nil, buildID: String? = nil, fresh: Bool = false, events: (@Sendable (AIEvent) -> Void)? = nil
    ) {
        self.jobID = jobID
        self.buildID = buildID
        self.fresh = fresh
        self.events = events
    }
}

/// A task's output and where it came from.
public struct AIResult<Output: Sendable>: Sendable {
    public let output: Output
    public let model: ModelRef
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let seconds: Double
    public let cached: Bool
    public let repaired: Bool
    /// An earlier model in the chain failed.
    public let fellBack: Bool
    /// The validated reply: what the cache keeps.
    public let json: String
}

/// Runs typed tasks through each one's chain of models. Every reliability rule lives here, each
/// from a real failure:
/// - keys rotate on a 429, and a key told to wait rests from that model only (Gemini counts quota
///   per model); a 429 with "limit: 0" skips the key for the model (T20 saw a 14-hour retry delay);
/// - network errors and 5xx retry with backoff, but a timeout is tried once more at most, and with
///   another model waiting in the chain a slow or overloaded one isn't waited out (2026-10-23: a
///   Flash call hung 243 s and sank a build);
/// - a model that just failed that way is skipped for two minutes while another can go first;
/// - a reply that fails its checks gets one repair call quoting what was wrong;
/// - a model that refuses a structured-output mode is remembered at the next (T20);
/// - a daily call budget, a cache of validated outputs, and a call log with codes, never text.
public actor AIRouter {
    private var settings: AISettings
    private let secrets: any SecretStore
    private let service: any ChatService
    private let log: (any AICallLog)?
    private let cache: (any AIResultCache)?
    private let clock: any AIClock
    private let jitter: @Sendable () -> Double

    private var keys: [String: [(name: String, value: String?)]] = [:]
    private var current: [String: Int] = [:]
    private var rests: [String: Date] = [:]
    private var modes: [String: StructuredOutput] = [:]
    private var troubled: [ModelRef: Date] = [:]
    private var gates: [String: RateGate] = [:]

    static let troubledFor: TimeInterval = 120
    static let maxWait: Double = 60

    public init(
        settings: AISettings, secrets: any SecretStore, service: any ChatService, log: (any AICallLog)? = nil,
        cache: (any AIResultCache)? = nil, clock: any AIClock = SystemAIClock(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1.5) }
    ) {
        self.settings = settings
        self.secrets = secrets
        self.service = service
        self.log = log
        self.cache = cache
        self.clock = clock
        self.jitter = jitter
    }

    /// New settings; what was learned about models and keys stays.
    public func update(_ settings: AISettings) {
        self.settings = settings
        keys = [:]
        gates = [:]
    }

    /// Reads keys again on next use: after one is added or removed.
    public func forgetKeys() { keys = [:] }

    public var currentSettings: AISettings { settings }

    /// The models a task's chain names that can run now (a provider needing a key has one).
    public func canRun(_ task: TaskID) -> Bool {
        settings.chain(for: task).contains { ref in
            guard let provider = settings.provider(ref.provider) else { return false }
            return !provider.preset.needsKey || !((try? loadKeys(provider)) ?? []).isEmpty
        }
    }

    public func run<T: AITask>(_ task: T, input: T.Input, context: AIContext = AIContext()) async throws(AIError)
        -> AIResult<T.Output>
    {
        let chain = settings.chain(for: T.id)
        guard !chain.isEmpty else { throw .noModel(T.id) }
        let profile = TaskProfile.of(T.id)
        let messages = task.messages(for: input, budget: profile.budget)
        let inputHash = StableID.sha256(
            Data(messages.map { "\($0.role.rawValue):\($0.content)" }.joined(separator: "\u{1E}").utf8))
        var lastError = AIError.noModel(T.id)

        for (position, ref) in chain.enumerated() {
            let isLast = position == chain.count - 1
            if !context.fresh, let cache,
                let json = await cache.output(
                    task: T.id, inputHash: inputHash, promptVersion: T.promptVersion, model: ref.model),
                case .success(let output) = OutputCheck.output(from: json, task: task, input: input)
            {
                context.events?(.answered(task: T.id, model: ref, seconds: 0, cached: true))
                return AIResult(
                    output: output, model: ref, inputTokens: nil, outputTokens: nil, seconds: 0, cached: true,
                    repaired: false, fellBack: position > 0, json: json)
            }
            if let log {
                let usage = await log.usage(since: Calendar.current.startOfDay(for: clock.now))
                guard settings.budget.allows(calls: usage.calls, tokens: usage.tokens) else { throw .budgetReached }
            }
            guard let provider = settings.provider(ref.provider) else {
                lastError = .noModel(T.id)
                continue
            }
            if !isLast, let until = troubled[ref], until > clock.now {
                context.events?(.failed(task: T.id, model: ref, reason: "was skipped after failing a moment ago", detail: nil))
                continue
            }
            context.events?(.asking(task: T.id, model: ref, fallback: position > 0))
            let started = clock.now
            do {
                let (output, json, tokens, repaired) = try await run(
                    task, input: input, messages: messages, on: ref, provider: provider, profile: profile,
                    failFast: !isLast, fellBack: position > 0, context: context)
                troubled[ref] = nil
                await cache?.store(json, task: T.id, inputHash: inputHash, promptVersion: T.promptVersion, model: ref.model)
                let seconds = clock.now.timeIntervalSince(started)
                context.events?(.answered(task: T.id, model: ref, seconds: seconds, cached: false))
                return AIResult(
                    output: output, model: ref, inputTokens: tokens.input, outputTokens: tokens.output, seconds: seconds,
                    cached: false, repaired: repaired, fellBack: position > 0, json: json)
            } catch {
                if error.stopsEverything { throw error }
                if error.isTemporary { troubled[ref] = clock.now.addingTimeInterval(Self.troubledFor) }
                let detail: String? =
                    switch error {
                    case .invalidOutput(let problem), .invalidJSON(let problem), .badRequest(let problem): problem
                    default: nil
                    }
                context.events?(.failed(task: T.id, model: ref, reason: error.reason, detail: detail))
                lastError = error
            }
        }
        throw lastError
    }

    /// The provider's models (with its first key), for Settings.
    public func listModels(provider id: String) async throws(AIError) -> [String] {
        guard let provider = settings.provider(id) else { throw .noModel(TaskID("listModels")) }
        let key = try loadKeys(provider).first?.value
        return try await service.listModels(provider: provider, key: key)
    }

    // MARK: - One model

    private func run<T: AITask>(
        _ task: T, input: T.Input, messages: [ChatMessage], on ref: ModelRef, provider: AISettings.Provider,
        profile: TaskProfile, failFast: Bool, fellBack: Bool, context: AIContext
    ) async throws(AIError) -> (T.Output, String, (input: Int?, output: Int?), Bool) {
        var messages = messages
        var tokens: (input: Int?, output: Int?) = (nil, nil)
        for attempt in 0..<2 {
            let request = ChatRequest(
                task: T.id, model: ref.model, messages: messages, schema: T.outputSchema, temperature: profile.temperature,
                maxOutputTokens: profile.budget.output, timeoutSeconds: profile.timeoutSeconds)
            let (response, keyName, milliseconds) = try await call(
                request, provider: provider, ref: ref, failFast: failFast, fellBack: fellBack, context: context)
            tokens.input = Self.sum(tokens.input, response.inputTokens)
            tokens.output = Self.sum(tokens.output, response.outputTokens)
            let checked = OutputCheck.output(
                from: response.text, cutOff: response.finishReason == "length", task: task, input: input)
            await log?.record(
                AICall(
                    at: clock.now, task: T.id, provider: provider.id, keyName: keyName, model: ref.model,
                    promptVersion: T.promptVersion, outcome: checked.isSuccess ? .ok : .invalid,
                    errorCode: checked.isSuccess ? nil : "invalid_output", inputTokens: response.inputTokens,
                    outputTokens: response.outputTokens, milliseconds: milliseconds, fellBack: fellBack,
                    jobID: context.jobID, buildID: context.buildID))
            switch checked {
            case .success(let output):
                return (output, OutputCheck.unfenced(response.text), tokens, attempt > 0)
            case .failure(let problem):
                if attempt == 1 { throw .invalidOutput(problem.description) }
                context.events?(.retrying(task: T.id, model: ref, reason: "sent a reply that failed its checks"))
                messages += [.assistant(response.text), .user(OutputCheck.repairNote(problem))]
            }
        }
        throw .invalidOutput("no reply passed its checks")
    }

    /// One model call through the provider's keys, with retries.
    private func call(
        _ request: ChatRequest, provider: AISettings.Provider, ref: ModelRef, failFast: Bool, fellBack: Bool,
        context: AIContext
    ) async throws(AIError) -> (ChatResponse, String?, Int) {
        let pool = try loadKeys(provider)
        guard !pool.isEmpty else { throw .noKey(provider: provider.displayName) }
        var failures = 0
        var waits = 0
        var offPlan: Set<Int> = []
        while true {
            if Task.isCancelled { throw .cancelled }
            guard let index = nextKey(provider.id, pool: pool, model: request.model, skipping: offPlan) else {
                if offPlan.count == pool.count { throw .modelNotOnPlan(request.model) }
                let back = pool.indices.filter { !offPlan.contains($0) }
                    .compactMap { rests[Self.restKey(provider.id, pool[$0].name, request.model)] }.min()
                let wait = max(0, (back ?? clock.now).timeIntervalSince(clock.now))
                waits += 1
                guard !failFast, wait <= Self.maxWait, waits <= 3 else {
                    throw .rateLimited(retryAfterSeconds: Int(wait.rounded(.up)))
                }
                context.events?(.retrying(task: request.task, model: ref, reason: "waits for its rate limit"))
                try await clock.sleep(seconds: wait)
                continue
            }
            let gate = gate(for: provider)
            try await gate.acquire()
            let started = clock.now
            let modeKey = "\(provider.id)|\(request.model)"
            let mode = max(modes[modeKey] ?? provider.preset.structuredOutput, provider.preset.structuredOutput)
            let result: Result<(ChatResponse, StructuredOutput), AIError>
            do {
                result = .success(try await service.complete(request, provider: provider, key: pool[index].value, mode: mode))
            } catch {
                result = .failure(error)
            }
            await gate.release()
            let milliseconds = Int(clock.now.timeIntervalSince(started) * 1_000)
            let keyName = provider.preset.needsKey ? pool[index].name : nil

            switch result {
            case .success(let (response, usedMode)):
                if usedMode > mode { modes[modeKey] = usedMode }
                current[provider.id] = index
                return (response, keyName, milliseconds)
            case .failure(let error):
                var call = AICall(
                    at: clock.now, task: request.task, provider: provider.id, keyName: keyName, model: request.model,
                    promptVersion: 0, outcome: .failed, errorCode: error.code, milliseconds: milliseconds,
                    fellBack: fellBack, jobID: context.jobID, buildID: context.buildID)
                switch error {
                case .rateLimited(let delay):
                    call.outcome = .rateLimited
                    rests[Self.restKey(provider.id, pool[index].name, request.model)] =
                        clock.now.addingTimeInterval(Double(delay ?? 60))
                case .quotaUsedUp(_, let limit, let delay):
                    let dayEnds = QuotaDay.bounds(at: clock.now, zone: provider.preset.quotaDayZone).end
                    let back = delay.map { clock.now.addingTimeInterval(Double($0)) } ?? dayEnds
                    call.outcome = .usedUp
                    call.dailyLimit = limit
                    call.backAt = back
                    rests[Self.restKey(provider.id, pool[index].name, request.model)] = back
                case .modelNotOnPlan:
                    offPlan.insert(index)
                default:
                    break
                }
                await log?.record(call)
                switch error {
                case .rateLimited, .quotaUsedUp, .modelNotOnPlan:
                    continue
                case let error where error.isTemporary:
                    failures += 1
                    let allowed = error == .timedOut ? (failFast ? 1 : 2) : (failFast ? 2 : 3)
                    guard failures < allowed else { throw error }
                    context.events?(.retrying(task: request.task, model: ref, reason: error.reason))
                    try await clock.sleep(seconds: min(Self.maxWait, pow(2, Double(failures - 1)) * jitter()))
                default:
                    throw error
                }
            }
        }
    }

    // MARK: - Keys, rests and gates

    private func loadKeys(_ provider: AISettings.Provider) throws(AIError) -> [(name: String, value: String?)] {
        if let loaded = keys[provider.id] { return loaded }
        let loaded: [(name: String, value: String?)]
        if provider.preset.needsKey {
            loaded = provider.keyNames.compactMap { name in
                guard let value = (try? secrets.read(SecretKey(name))) ?? nil, !value.isEmpty else { return nil }
                return (name, value)
            }
        } else {
            loaded = [("no-key", nil)]
        }
        keys[provider.id] = loaded
        return loaded
    }

    /// The key to use: the last one that worked, else the next not resting from `model` or off-plan.
    private func nextKey(_ provider: String, pool: [(name: String, value: String?)], model: String, skipping: Set<Int>)
        -> Int?
    {
        let start = current[provider] ?? 0
        let now = clock.now
        for step in 0..<pool.count {
            let index = (start + step) % pool.count
            if skipping.contains(index) { continue }
            if let until = rests[Self.restKey(provider, pool[index].name, model)], until > now { continue }
            return index
        }
        return nil
    }

    /// When each key of a provider is back for each model it's resting from.
    public func resting(provider: String) -> [String: [String: Date]] {
        let now = clock.now
        var result: [String: [String: Date]] = [:]
        for (slot, until) in rests where until > now {
            let parts = slot.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == provider else { continue }
            result[parts[1], default: [:]][parts[2]] = until
        }
        return result
    }

    private func gate(for provider: AISettings.Provider) -> RateGate {
        if let gate = gates[provider.id] { return gate }
        let gate = RateGate(
            perMinute: provider.requestsPerMinute ?? provider.preset.requestsPerMinute, concurrent: provider.concurrent,
            clock: clock)
        gates[provider.id] = gate
        return gate
    }

    private static func restKey(_ provider: String, _ key: String, _ model: String) -> String {
        "\(provider)|\(key)|\(model)"
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, nil): nil
        default: (a ?? 0) + (b ?? 0)
        }
    }
}

/// Requests per minute and calls at once for one provider, so runs don't trigger 429 storms.
actor RateGate {
    let perMinute: Int
    let concurrent: Int
    let clock: any AIClock
    private var starts: [Date] = []
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(perMinute: Int, concurrent: Int, clock: any AIClock) {
        self.perMinute = max(1, perMinute)
        self.concurrent = max(1, concurrent)
        self.clock = clock
    }

    func acquire() async throws(AIError) {
        while true {
            if Task.isCancelled { throw .cancelled }
            let now = clock.now
            starts.removeAll { now.timeIntervalSince($0) >= 60 }
            if running >= concurrent {
                await withCheckedContinuation { waiting.append($0) }
                continue
            }
            if starts.count >= perMinute, let oldest = starts.first {
                try await clock.sleep(seconds: max(0.05, 60 - now.timeIntervalSince(oldest)))
                continue
            }
            running += 1
            starts.append(now)
            return
        }
    }

    func release() {
        running = max(0, running - 1)
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
