import Foundation

/// Names a typed task (SPEC §5.5, task catalog). Part of cache keys and call-log rows.
public struct TaskID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let importResume = TaskID("importResume")
    public static let importGitHubRepo = TaskID("importGitHubRepo")
    public static let triage = TaskID("triage")
    public static let analyzeJob = TaskID("analyzeJob")
    public static let select = TaskID("select")
    public static let writeSummary = TaskID("writeSummary")
    public static let writeSkills = TaskID("writeSkills")
    public static let writeExperience = TaskID("writeExperience")
    public static let writeProjects = TaskID("writeProjects")
    public static let rewriteSection = TaskID("rewriteSection")
    public static let gapBullets = TaskID("gapBullets")
    public static let coverLetter = TaskID("coverLetter")
    public static let suggestEvidence = TaskID("suggestEvidence")
    public static let shortenBullets = TaskID("shortenBullets")

    /// Every task in the spec's catalog, in its order.
    public static let catalog: [TaskID] = [
        .importResume, .importGitHubRepo, .triage, .analyzeJob, .select, .writeSummary, .writeSkills,
        .writeExperience, .writeProjects, .rewriteSection, .gapBullets, .coverLetter, .suggestEvidence,
        .shortenBullets,
    ]
}

/// How many tokens a task may send and receive. Estimates are characters ÷ 4 until a provider's
/// `usage` numbers say otherwise (SPEC §5.5, "Token estimates").
public struct TokenBudget: Equatable, Sendable {
    public let input: Int
    public let output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    public static func estimate(_ text: String) -> Int {
        (text.count + 3) / 4
    }

    public func fits(_ text: String) -> Bool {
        Self.estimate(text) <= input
    }
}

public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    /// Role, rules and the output contract. Rarely changes, so providers can cache it as a prefix.
    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: .system, content: content) }
    /// Data in tagged blocks (`<job_posting>`, `<entries>`); the rules say it's data, never instructions.
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: .user, content: content) }
    public static func assistant(_ content: String) -> ChatMessage { ChatMessage(role: .assistant, content: content) }
}

/// Every LLM use is a typed task, so calling code never handles raw text (SPEC §5.5).
public protocol LLMTask: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Decodable & Sendable
    /// For example `.analyzeJob`.
    static var id: TaskID { get }
    /// Bumped on every prompt change; part of cache keys.
    static var promptVersion: Int { get }
    /// Sent to providers that accept schemas; always checked locally.
    static var outputSchema: JSONSchema { get }
    func messages(for input: Input, budget: TokenBudget) -> [ChatMessage]
    /// Rules a schema can't express, such as "every source id exists".
    func check(_ output: Output, for input: Input) throws
}

/// How a call ended, as the call log records it.
public enum LLMOutcome: String, Sendable, CaseIterable {
    case ok, repaired
    /// Served from `llm_cache`; no call was made.
    case cached
    case rateLimited = "rate_limited"
    case fellBack = "fell_back"
    case failed
}

/// A task's output plus where it came from and what it cost.
public struct LLMResult<Output: Sendable>: Sendable {
    public let output: Output
    public let provider: String
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let latency: Duration
    public let outcome: LLMOutcome
    /// 1 for a first-try success; more after retries or a repair; 0 from the cache.
    public let attempts: Int
    /// The validated reply, fences removed: what the cache keeps.
    public let json: String

    public init(
        output: Output, provider: String, model: String, inputTokens: Int?, outputTokens: Int?, latency: Duration,
        outcome: LLMOutcome, attempts: Int, json: String = ""
    ) {
        self.output = output
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latency = latency
        self.outcome = outcome
        self.attempts = attempts
        self.json = json
    }
}

public enum LLMError: Error, Equatable, Sendable {
    /// 401 or 403. Never retried.
    case keyRejected(provider: String)
    /// 404. Never retried.
    case modelNotFound(String)
    /// 400. Never retried.
    case badRequest(String)
    case rateLimited(retryAfterSeconds: Int?)
    /// A 429 whose quota limit is 0: the model isn't on this key's plan, so waiting won't help (T20).
    case modelNotOnPlan(String)
    case server(status: Int)
    case network(String)
    case timedOut
    case cancelled
    /// The reply wasn't JSON.
    case invalidJSON(String)
    /// The reply broke the schema or the task's own check.
    case invalidOutput(String)
    /// "Daily AI budget reached" (SPEC §5.5, Budget).
    case budgetReached
    case noProvider(TaskID)
    /// The provider needs a key and none is saved in the Keychain.
    case noKey(provider: String)
    /// A `FakeProvider` was asked for more than its script holds.
    case noScriptedReply(TaskID)
}

/// How hard a thinking model may think. Local models default to `.none` (decided 2026-10-19, T20).
public enum ReasoningEffort: String, Sendable, CaseIterable {
    case none, low, medium, high
}

extension LLMError {
    /// A short code for the call log. Never carries prompt or reply text.
    public var code: String {
        switch self {
        case .keyRejected: "key_rejected"
        case .modelNotFound: "model_not_found"
        case .badRequest: "bad_request"
        case .rateLimited: "rate_limited"
        case .modelNotOnPlan: "model_not_on_plan"
        case .server(let status): "server_\(status)"
        case .network: "network"
        case .timedOut: "timed_out"
        case .cancelled: "cancelled"
        case .invalidJSON: "invalid_json"
        case .invalidOutput: "invalid_output"
        case .budgetReached: "budget_reached"
        case .noProvider: "no_provider"
        case .noKey: "no_key"
        case .noScriptedReply: "no_scripted_reply"
        }
    }
}

/// One model call, as every adapter sees it.
public struct ChatRequest: Sendable {
    public let task: TaskID
    public let model: String
    public let messages: [ChatMessage]
    /// Sent where the provider accepts a schema; otherwise JSON mode with the schema in the prompt.
    public let schema: JSONSchema?
    public let temperature: Double
    public let maxOutputTokens: Int
    /// Sent only to presets that accept `reasoning_effort`.
    public let reasoningEffort: ReasoningEffort?
    /// The task's own limit (SPEC §5.5: 60 s extraction, 120 s writing). Local providers keep their
    /// longer one, since a thinking model on a laptop can't meet it (T20).
    public let timeoutSeconds: Int?

    public init(
        task: TaskID, model: String, messages: [ChatMessage], schema: JSONSchema?, temperature: Double,
        maxOutputTokens: Int, reasoningEffort: ReasoningEffort? = nil, timeoutSeconds: Int? = nil
    ) {
        self.task = task
        self.model = model
        self.messages = messages
        self.schema = schema
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ChatResponse: Equatable, Sendable {
    public let text: String
    public let model: String
    public let inputTokens: Int?
    /// Includes thinking the provider didn't show (T20: Gemini Flash counts it only in the total).
    public let outputTokens: Int?
    /// "stop", or "length" when the reply hit the output limit and is probably cut off.
    public let finishReason: String?

    public init(text: String, model: String, inputTokens: Int?, outputTokens: Int?, finishReason: String? = nil) {
        self.text = text
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.finishReason = finishReason
    }
}

/// An adapter for one provider (OpenAI-compatible, on-device, ...). It only talks to the model; rate
/// limits, retries, repair and fallback live in the client above it.
public protocol LLMProvider: Sendable {
    var name: String { get }
    func complete(_ request: ChatRequest) async throws(LLMError) -> ChatResponse
}
