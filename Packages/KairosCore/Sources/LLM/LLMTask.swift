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

    /// Every task in the spec's catalog, in its order.
    public static let catalog: [TaskID] = [
        .importResume, .importGitHubRepo, .triage, .analyzeJob, .select, .writeSummary, .writeSkills,
        .writeExperience, .writeProjects, .rewriteSection, .gapBullets, .coverLetter,
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
    /// 1 for a first-try success; more after retries or a repair.
    public let attempts: Int

    public init(
        output: Output, provider: String, model: String, inputTokens: Int?, outputTokens: Int?, latency: Duration,
        outcome: LLMOutcome, attempts: Int
    ) {
        self.output = output
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latency = latency
        self.outcome = outcome
        self.attempts = attempts
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
    /// A `FakeProvider` was asked for more than its script holds.
    case noScriptedReply(TaskID)
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

    public init(
        task: TaskID, model: String, messages: [ChatMessage], schema: JSONSchema?, temperature: Double,
        maxOutputTokens: Int
    ) {
        self.task = task
        self.model = model
        self.messages = messages
        self.schema = schema
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct ChatResponse: Equatable, Sendable {
    public let text: String
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(text: String, model: String, inputTokens: Int?, outputTokens: Int?) {
        self.text = text
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// An adapter for one provider (OpenAI-compatible, on-device, ...). It only talks to the model; rate
/// limits, retries, repair and fallback live in the client above it.
public protocol LLMProvider: Sendable {
    var name: String { get }
    func complete(_ request: ChatRequest) async throws(LLMError) -> ChatResponse
}
