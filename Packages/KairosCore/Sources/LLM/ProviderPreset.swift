import Foundation

/// How a model is asked for JSON, best first. A model that refuses one mode drops to the next (T20).
public enum StructuredOutput: String, Sendable, CaseIterable, Comparable {
    /// `response_format: json_schema`, strict.
    case schema
    /// `response_format: json_object`, with the schema in the system message.
    case jsonMode = "json"
    /// No `response_format`; the schema in the system message only.
    case promptOnly = "prompt"

    /// The next mode to try after this one is refused, if any.
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

    public static func < (lhs: StructuredOutput, rhs: StructuredOutput) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A provider the user can add in Settings (SPEC §5.5, "Setup for each user"). Capability flags
/// are where a model starts; a model that refuses its preset's mode is remembered at a lower one.
public struct ProviderPreset: Sendable, Equatable, Identifiable {
    /// The two model classes tasks ask for (SPEC §5.5: "Flash" and "Flash-Lite").
    public enum ModelClass: String, Sendable, CaseIterable { case flash, flashLite }

    public let id: String
    public let name: String
    /// Ends with "/"; endpoint paths are appended to it.
    public let baseURL: String
    public let needsKey: Bool
    /// On this Mac: plain http is allowed, thinking is off by default, and timeouts are longer.
    public let isLocal: Bool
    public let structuredOutput: StructuredOutput
    /// Whether `reasoning_effort` is understood (Gemini maps it to thinking levels).
    public let acceptsReasoningEffort: Bool
    /// OpenAI's newer models take `max_completion_tokens`; everyone else `max_tokens`.
    public let maxTokensField: String
    /// Starting models; Settings lists the provider's own through `GET /models`.
    public let defaultModels: [ModelClass: String]
    /// The client-side limit (SPEC §5.5: 10 per minute suits free tiers).
    public let requestsPerMinute: Int
    /// Cloud: 120 s. Local thinking models took 92–117 s in T20, so local gets 180 s.
    public let timeoutSeconds: Int
    /// Its model list is public, so listing models proves nothing about a key: a key is checked
    /// with one tiny chat on this model instead (Ollama Cloud's list needs no key; its chat does).
    public var keyCheckModel: String? = nil
    /// Calls a plan runs at once, by plan name, when the provider sells plans (Ollama Cloud, its
    /// pricing page, 2026-10-23). Requests past it queue at the provider, then get refused.
    public var plans: [Plan] = []
    /// The usual free requests a day per model family, where the provider caps a key by the day and
    /// says nothing until it refuses: Kairos counts its own calls against it, and a refusal that names
    /// the real limit replaces it (2026-10-23).
    public var dailyRequests: [DailyRequests] = []
    /// The time zone those days run in, as an identifier.
    public var quotaDayZone: String? = nil
    /// Where a key's credits left can be read (Ollama Cloud's `GET /api/balance`).
    public var balanceURL: String? = nil

    public struct Plan: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let concurrent: Int
    }

    /// Models whose id contains `family` get `requests` a day; the first match wins.
    public struct DailyRequests: Sendable, Equatable {
        public let family: String
        public let requests: Int
    }

    /// How hard models here think unless a task says: not at all on Ollama, on this Mac (decided
    /// 2026-10-19) and in its cloud, where thinking spends the reply's tokens and your credits.
    public var reasoningDefault: ReasoningEffort? {
        isLocal || id == ProviderPreset.ollamaCloud.id ? ReasoningEffort.none : nil
    }

    /// Verified in T20: strict schema mode works, half the tokens of JSON mode. Free keys get a few
    /// requests a day per model, per Google Cloud project, reset at midnight Pacific
    /// (ai.google.dev/gemini-api/docs/rate-limits). Flash: 20, as its refusals said on 2026-10-19.
    /// Flash-Lite: about 500, from October 2026 reports and a key refused after about 400 calls on
    /// 2026-10-20; checked against Google's own number the first time it refuses a key.
    public static let gemini = ProviderPreset(
        id: "gemini", name: "Google Gemini", baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
        needsKey: true, isLocal: false, structuredOutput: .schema, acceptsReasoningEffort: true,
        maxTokensField: "max_tokens",
        defaultModels: [.flash: "gemini-flash-latest", .flashLite: "gemini-flash-lite-latest"], requestsPerMinute: 10,
        timeoutSeconds: 120,
        dailyRequests: [
            DailyRequests(family: "flash-lite", requests: 500), DailyRequests(family: "flash", requests: 20),
        ],
        quotaDayZone: "America/Los_Angeles")

    /// JSON mode until a model refuses it (T20: `qwen3.5:4B` answers 501 and drops to prompt-only).
    public static let ollamaLocal = ProviderPreset(
        id: "ollama-local", name: "Ollama on this Mac", baseURL: "http://localhost:11434/v1/", needsKey: false,
        isLocal: true, structuredOutput: .jsonMode, acceptsReasoningEffort: true, maxTokensField: "max_tokens",
        defaultModels: [:], requestsPerMinute: 30, timeoutSeconds: 180)

    /// Its cloud ignores a JSON schema whether sent the OpenAI way or its own (`format`), so the
    /// schema goes in the prompt (JSON mode), and the repair call catches the rest (2026-10-23).
    /// gemma4:31b is on the Free plan and passed every call of Kairos's eval, so it's the start.
    public static let ollamaCloud = ProviderPreset(
        id: "ollama-cloud", name: "Ollama Cloud", baseURL: "https://ollama.com/v1/", needsKey: true,
        isLocal: false, structuredOutput: .jsonMode, acceptsReasoningEffort: true, maxTokensField: "max_tokens",
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
        id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1/", needsKey: true,
        isLocal: false, structuredOutput: .schema, acceptsReasoningEffort: false, maxTokensField: "max_tokens",
        defaultModels: [:], requestsPerMinute: 10, timeoutSeconds: 120)

    public static let openAI = ProviderPreset(
        id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1/", needsKey: true, isLocal: false,
        structuredOutput: .schema, acceptsReasoningEffort: true, maxTokensField: "max_completion_tokens",
        defaultModels: [:], requestsPerMinute: 30, timeoutSeconds: 120)

    public static let all: [ProviderPreset] = [.gemini, .ollamaLocal, .ollamaCloud, .groq, .openRouter, .openAI]

    /// The ids worth offering for text tasks: no image, speech, video or embedding models; for
    /// Gemini only its own model families (its list also carries agent products such as
    /// `deep-research-preview`). `-latest` aliases first, previews last (T20: Gemini lists 63).
    public func chatModels(from ids: [String]) -> [String] {
        let skipped = ["tts", "image", "imagen", "embed", "aqa", "live", "audio", "veo", "learnlm", "robotics"]
        var chat = ids.filter { id in !skipped.contains { id.lowercased().contains($0) } }
        if id == "gemini" {
            chat = chat.filter { $0.hasPrefix("gemini-") || $0.hasPrefix("gemma-") }
        }
        let aliases = chat.filter { $0.hasSuffix("-latest") }
        let previews = chat.filter { !$0.hasSuffix("-latest") && $0.contains("preview") }
        let stable = chat.filter { !$0.hasSuffix("-latest") && !$0.contains("preview") }
        return aliases + stable + previews
    }

    /// A provider at your own base URL, such as a self-hosted gateway. Treated as unmeasured.
    public static func custom(name: String, baseURL: URL, needsKey: Bool) -> ProviderPreset {
        let local = ["localhost", "127.0.0.1", "::1"].contains(baseURL.host() ?? "")
        let base = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        return ProviderPreset(
            id: "custom", name: name, baseURL: base, needsKey: needsKey, isLocal: local,
            structuredOutput: .schema, acceptsReasoningEffort: false, maxTokensField: "max_tokens", defaultModels: [:],
            requestsPerMinute: 10, timeoutSeconds: local ? 180 : 120)
    }
}
