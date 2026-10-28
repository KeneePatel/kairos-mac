import AI
import Foundation
import KairosKit
import Secrets

/// A `ChatService` that answers each task from a script, in order, and records what it was asked:
/// the whole AI stack runs in tests without a network.
public final class ScriptedChat: ChatService, @unchecked Sendable {
    public enum Reply: Sendable {
        case json(String)
        /// A reply cut off at the output limit.
        case cutOff(String)
        case error(AIError)
    }

    public struct Asked: Sendable {
        public let request: ChatRequest
        public let provider: String
        public let key: String?
        public let mode: StructuredOutput
    }

    private let lock = NSLock()
    private var replies: [TaskID: [Reply]]
    private var fallback: [TaskID: Reply] = [:]
    private var seen: [Asked] = []
    /// Models that refuse schema mode, as `qwen3.5:4B` did in T20.
    public var refusesSchema: Set<String> = []
    public var models: [String] = ["model-a", "model-b"]

    public init(_ replies: [TaskID: [Reply]] = [:]) {
        self.replies = replies
    }

    /// Queues `reply` for the next call of `task`.
    public func add(_ task: TaskID, _ reply: Reply) {
        lock.withLock { replies[task, default: []].append(reply) }
    }

    /// Answers every call of `task` that has nothing queued.
    public func always(_ task: TaskID, _ reply: Reply) {
        lock.withLock { fallback[task] = reply }
    }

    public var asked: [Asked] { lock.withLock { seen } }

    public func calls(_ task: TaskID) -> [Asked] { asked.filter { $0.request.task == task } }

    public func complete(_ request: ChatRequest, provider: AISettings.Provider, key: String?, mode: StructuredOutput)
        async throws(AIError) -> (ChatResponse, StructuredOutput)
    {
        let used = mode == .schema && refusesSchema.contains(request.model) ? StructuredOutput.jsonMode : mode
        let reply: Reply? = lock.withLock {
            seen.append(Asked(request: request, provider: provider.id, key: key, mode: used))
            if var queue = replies[request.task], !queue.isEmpty {
                let next = queue.removeFirst()
                replies[request.task] = queue
                return next
            }
            return fallback[request.task]
        }
        switch reply {
        case .json(let text):
            return (ChatResponse(text: text, model: request.model, inputTokens: 100, outputTokens: 50), used)
        case .cutOff(let text):
            return (ChatResponse(text: text, model: request.model, finishReason: "length"), used)
        case .error(let error):
            throw error
        case nil:
            throw .network("no scripted reply for \(request.task)")
        }
    }

    public func listModels(provider: AISettings.Provider, key: String?) async throws(AIError) -> [String] {
        models
    }
}

/// A clock whose sleeps return at once and move time on, so retries and waits run instantly.
public final class TestClock: AIClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public private(set) var slept: [Double] = []

    public init(_ start: Date = Date(timeIntervalSince1970: 1_793_000_000)) { current = start }

    public var now: Date { lock.withLock { current } }

    public func sleep(seconds: Double) async throws(AIError) {
        if Task.isCancelled { throw .cancelled }
        lock.withLock {
            slept.append(seconds)
            current += seconds
        }
    }

    public func advance(_ seconds: Double) { lock.withLock { current += seconds } }
}

/// The call log in memory.
public actor MemoryCallLog: AICallLog {
    public private(set) var calls: [AICall] = []

    public init() {}

    public func record(_ call: AICall) { calls.append(call) }

    public func usage(since start: Date) -> (calls: Int, tokens: Int) {
        let today = calls.filter { $0.at >= start && $0.reachedProvider }
        return (today.count, today.reduce(0) { $0 + ($1.inputTokens ?? 0) + ($1.outputTokens ?? 0) })
    }
}

/// The result cache in memory.
public actor MemoryResultCache: AIResultCache {
    private var outputs: [String: String] = [:]

    public init() {}

    public func output(task: TaskID, inputHash: String, promptVersion: Int, model: String) -> String? {
        outputs["\(task)|\(inputHash)|\(promptVersion)|\(model)"]
    }

    public func store(_ json: String, task: TaskID, inputHash: String, promptVersion: Int, model: String) {
        outputs["\(task)|\(inputHash)|\(promptVersion)|\(model)"] = json
    }
}

/// A router over scripted replies: one provider ("p", no key needed) whose chain for every task is
/// `models`, or a custom chain.
public func scriptedRouter(
    _ chat: ScriptedChat, models: [String] = ["model-a"], log: (any AICallLog)? = nil,
    cache: (any AIResultCache)? = nil,
    clock: TestClock = TestClock(), budget: AISettings.Budget = AISettings.Budget()
) -> AIRouter {
    let routes = Dictionary(
        uniqueKeysWithValues: TaskID.catalog.map { task in
            (task.rawValue, models.map { ModelRef(provider: "p", model: $0) })
        })
    let settings = AISettings(
        providers: [AISettings.Provider(id: "p", presetID: "ollama-local")], routes: routes, budget: budget)
    return AIRouter(
        settings: settings, secrets: MemorySecretStore(), service: chat, log: log, cache: cache, clock: clock,
        jitter: { 1 })
}
