import Foundation

/// How a model is asked for JSON, best first. A model that refuses one mode drops to the next (T20).
public enum StructuredOutput: String, Sendable, CaseIterable, Comparable, Codable {
    /// `response_format: json_schema`, strict.
    case schema
    /// `response_format: json_object`, with the schema in the system message.
    case jsonMode = "json"
    /// No `response_format`; the schema in the system message only.
    case promptOnly = "prompt"

    public var fallback: StructuredOutput? {
        switch self {
        case .schema: .jsonMode
        case .jsonMode: .promptOnly
        case .promptOnly: nil
        }
    }

    private var rank: Int {
        switch self {
        case .schema: 0
        case .jsonMode: 1
        case .promptOnly: 2
        }
    }

    public static func < (lhs: StructuredOutput, rhs: StructuredOutput) -> Bool { lhs.rank < rhs.rank }
}

/// How hard a thinking model may think. Ollama models default to `.none` (decided 2026-10-19).
public enum ReasoningEffort: String, Sendable, CaseIterable {
    case none, low, medium, high

    /// `effort` as `model` can take it. gpt-oss can't stop reasoning: asked for none it reasons at
    /// length and can spend its whole reply on it (2026-10-23), so it gets low.
    public static func fitting(_ effort: ReasoningEffort?, model: String) -> ReasoningEffort? {
        if effort == ReasoningEffort.none, model.lowercased().hasPrefix("gpt-oss") { return .low }
        return effort
    }
}

/// A service the user can add in Settings. Capabilities are where a model starts; a model that
/// refuses its preset's mode is remembered at a lower one.
public struct ProviderPreset: Sendable, Equatable, Identifiable {
    public struct Plan: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// Calls the plan runs at once.
        public let concurrent: Int
    }

    /// Models whose id contains `family` get `requests` a day; the first match wins.
    public struct DailyRequests: Sendable, Equatable {
        public let family: String
        public let requests: Int
    }

    public let id: String
    public let name: String
    /// Ends with "/"; endpoint paths are appended.
    public let baseURL: String
    public let needsKey: Bool
    /// On this Mac: plain http allowed, thinking off by default, longer timeouts.
    public let isLocal: Bool
    public let structuredOutput: StructuredOutput
    /// Whether `reasoning_effort` is understood (Gemini maps it to thinking levels).
    public let acceptsReasoningEffort: Bool
    /// OpenAI's newer models take `max_completion_tokens`; everyone else `max_tokens`.
    public let maxTokensField: String
    public let defaultModels: [ModelClass: String]
    /// The client-side limit: 10 a minute suits free tiers.
    public let requestsPerMinute: Int
    /// Cloud: 120 s. Local thinking models took 92 to 117 s in T20, so local gets 180 s.
    public let timeoutSeconds: Int
    /// Its model list is public, so listing models proves nothing about a key: a key is checked
    /// with one tiny chat on this model instead (Ollama Cloud).
    public var keyCheckModel: String? = nil
    public var plans: [Plan] = []
    /// The usual free requests a day per model family, where the provider caps a key by the day and
    /// says nothing until it refuses. A refusal that names the real limit replaces it.
    public var dailyRequests: [DailyRequests] = []
    /// The time zone those days run in.
    public var quotaDayZone: String? = nil
    /// Where a key's credits left can be read (Ollama Cloud's `GET /api/balance`).
    public var balanceURL: String? = nil

    /// Ollama models, local and cloud, don't think unless asked (decided 2026-10-19): thinking spends
    /// the reply's tokens, and in the cloud your credits.
    public var reasoningDefault: ReasoningEffort? {
        isLocal || id == ProviderPreset.ollamaCloud.id ? ReasoningEffort.none : nil
    }

    public func dailyLimit(for model: String) -> Int? {
        dailyRequests.first { model.lowercased().contains($0.family) }?.requests
    }

    /// Strict schema mode works, half the tokens of JSON mode (T20). Free keys get a few requests a
    /// day per model per Google Cloud project, reset at midnight Pacific: Flash 20 (its refusals said
    /// so, 2026-10-19), Flash-Lite about 500 (a key refused after about 400 calls, 2026-10-20).
    public static let gemini = ProviderPreset(
        id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
        needsKey: true, isLocal: false, structuredOutput: .schema, acceptsReasoningEffort: true,
        maxTokensField: "max_tokens",
        defaultModels: [.flash: "gemini-flash-latest", .flashLite: "gemini-flash-lite-latest"], requestsPerMinute: 10,
        timeoutSeconds: 120,
        dailyRequests: [DailyRequests(family: "flash-lite", requests: 500), DailyRequests(family: "flash", requests: 20)],
        quotaDayZone: "America/Los_Angeles")

    /// JSON mode until a model refuses it (T20: `qwen3.5:4B` answers 501 and drops to prompt-only).
    public static let ollamaLocal = ProviderPreset(
        id: "ollama-local", name: "Ollama on this Mac", baseURL: "http://localhost:11434/v1/", needsKey: false,
        isLocal: true, structuredOutput: .jsonMode, acceptsReasoningEffort: true, maxTokensField: "max_tokens",
        defaultModels: [:], requestsPerMinute: 30, timeoutSeconds: 180)

    /// Its cloud ignores a JSON schema whichever way it's sent, so the schema goes in the prompt and
    /// the repair call catches the rest (2026-10-23). gemma4:31b is on the Free plan and passed every
    /// call of Kairos's eval.
    public static let ollamaCloud = ProviderPreset(
        id: "ollama-cloud", name: "Ollama Cloud", baseURL: "https://ollama.com/v1/", needsKey: true, isLocal: false,
        structuredOutput: .jsonMode, acceptsReasoningEffort: true, maxTokensField: "max_tokens",
        defaultModels: [.flash: "gemma4:31b", .flashLite: "gemma4:31b"], requestsPerMinute: 30, timeoutSeconds: 120,
        keyCheckModel: "gemma4:31b",
        plans: [
            Plan(id: "free", name: "Free", concurrent: 1), Plan(id: "pro", name: "Pro", concurrent: 3),
            Plan(id: "max", name: "Max", concurrent: 10),
        ],
        balanceURL: "https://ollama.com/api/balance")

    // Not measured yet: they start at schema mode and drop like any other on refusal.

    public static let groq = ProviderPreset(
        id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1/", needsKey: true, isLocal: false,
        structuredOutput: .schema, acceptsReasoningEffort: false, maxTokensField: "max_tokens", defaultModels: [:],
        requestsPerMinute: 10, timeoutSeconds: 120)

    public static let openRouter = ProviderPreset(
        id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1/", needsKey: true, isLocal: false,
        structuredOutput: .schema, acceptsReasoningEffort: false, maxTokensField: "max_tokens", defaultModels: [:],
        requestsPerMinute: 10, timeoutSeconds: 120)

    public static let openAI = ProviderPreset(
        id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1/", needsKey: true, isLocal: false,
        structuredOutput: .schema, acceptsReasoningEffort: true, maxTokensField: "max_completion_tokens",
        defaultModels: [:], requestsPerMinute: 30, timeoutSeconds: 120)

    public static let all: [ProviderPreset] = [.gemini, .ollamaLocal, .ollamaCloud, .groq, .openRouter, .openAI]

    /// A provider at your own base URL, such as a self-hosted gateway.
    public static func custom(name: String, baseURL: URL, needsKey: Bool) -> ProviderPreset {
        let local = ["localhost", "127.0.0.1", "::1"].contains(baseURL.host() ?? "")
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        return ProviderPreset(
            id: "custom", name: name, baseURL: base, needsKey: needsKey, isLocal: local, structuredOutput: .schema,
            acceptsReasoningEffort: false, maxTokensField: "max_tokens", defaultModels: [:], requestsPerMinute: 10,
            timeoutSeconds: local ? 180 : 120)
    }

    /// The ids worth offering for text tasks: no image, speech, video or embedding models; for
    /// Gemini only its own families. `-latest` aliases first, previews last (T20: Gemini lists 63).
    public func chatModels(from ids: [String]) -> [String] {
        let skipped = ["tts", "image", "imagen", "embed", "aqa", "live", "audio", "veo", "learnlm", "robotics"]
        var chat = ids.filter { id in !skipped.contains { id.lowercased().contains($0) } }
        if id == "gemini" { chat = chat.filter { $0.hasPrefix("gemini-") || $0.hasPrefix("gemma-") } }
        let aliases = chat.filter { $0.hasSuffix("-latest") }
        let previews = chat.filter { !$0.hasSuffix("-latest") && $0.contains("preview") }
        let stable = chat.filter { !$0.hasSuffix("-latest") && !$0.contains("preview") }
        return aliases + stable + previews
    }
}

/// A model at one of your providers: one link in a task's chain.
public struct ModelRef: Hashable, Sendable, Codable, CustomStringConvertible {
    /// The provider's id in your settings.
    public let provider: String
    public let model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    public var description: String { "\(provider)/\(model)" }
}
