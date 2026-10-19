import Foundation
import Secrets
import Store

/// The user's AI setup, stored as the "llm" setting (synced). It names keys but never holds them:
/// keys stay in this Mac's Keychain, so another device shows the provider and asks for its own key.
public struct LLMSettings: Codable, Sendable, Equatable {
    public struct Provider: Codable, Sendable, Equatable, Identifiable {
        /// Unique among the user's providers; `ModelRef.provider` points here.
        public var id: String
        public var presetID: String
        /// Custom providers only.
        public var name: String?
        public var baseURL: String?
        /// Keychain accounts, in rotation order: the first is the primary.
        public var keyNames: [String]
        /// Overrides the preset's requests per minute.
        public var requestsPerMinute: Int?

        public init(
            id: String, presetID: String, name: String? = nil, baseURL: String? = nil, keyNames: [String] = [],
            requestsPerMinute: Int? = nil
        ) {
            self.id = id
            self.presetID = presetID
            self.name = name
            self.baseURL = baseURL
            self.keyNames = keyNames
            self.requestsPerMinute = requestsPerMinute
        }

        public var preset: ProviderPreset {
            if presetID == "custom", let baseURL, let url = URL(string: baseURL) {
                return .custom(name: name ?? "Custom provider", baseURL: url, needsKey: !keyNames.isEmpty)
            }
            return ProviderPreset.all.first { $0.id == presetID } ?? .gemini
        }

        public var setup: ProviderSetup {
            ProviderSetup(
                id: id, preset: preset, keyNames: keyNames.map(SecretKey.init), requestsPerMinute: requestsPerMinute)
        }
    }

    public var providers: [Provider]
    /// Task id → its models, primary first.
    public var routes: [String: [ModelRef]]
    public var budget: Budget

    public static let storageKey = "llm"

    public init(providers: [Provider], routes: [String: [ModelRef]], budget: Budget) {
        self.providers = providers
        self.routes = routes
        self.budget = budget
    }

    /// New accounts start with Gemini (SPEC §5.5, Setup): writing tasks on its newest Flash,
    /// extraction on Flash-Lite. Ollama is listed so it can be turned on as the private option.
    public static func defaults() -> LLMSettings {
        let gemini = ProviderPreset.gemini
        var routes: [String: [ModelRef]] = [:]
        for task in TaskID.catalog {
            guard let modelClass = TaskDefaults.catalog[task]?.modelClass, let model = gemini.defaultModels[modelClass]
            else {
                continue
            }
            routes[task.rawValue] = [ModelRef(provider: gemini.id, model: model)]
        }
        return LLMSettings(
            providers: [
                Provider(id: gemini.id, presetID: gemini.id), Provider(id: "ollama-local", presetID: "ollama-local"),
            ],
            routes: routes, budget: Budget())
    }

    public func provider(_ id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    /// Every task on one provider's model, e.g. "Keep everything on this Mac" with Ollama.
    public mutating func routeEverything(to ref: ModelRef) {
        for task in TaskID.catalog where task != .triage {
            routes[task.rawValue] = [ref]
        }
    }

    /// A router over the providers that can run: those needing a key and lacking one are left out,
    /// and tasks routed only to them fail with `.noProvider` until a key is added.
    /// `capabilities` and `rests` are per provider id; pass the same ones to every router so what one
    /// operation learned (a refused mode, a used-up key) holds for the next.
    public func router(
        db: Database, secrets: any SecretStore, capabilities: [String: ModelCapabilities] = [:],
        rests: [String: KeyRests] = [:], transport: any LLMTransport = URLSessionTransport()
    ) -> LLMRouter {
        var clients: [String: LLMClient] = [:]
        for provider in providers {
            if let client = try? provider.setup.client(
                secrets: secrets, capabilities: capabilities[provider.id] ?? ModelCapabilities(),
                rests: rests[provider.id] ?? KeyRests(), transport: transport)
            {
                clients[provider.id] = client
            }
        }
        let taskRoutes = Dictionary(uniqueKeysWithValues: routes.map { (TaskID($0.key), $0.value) })
        return LLMRouter(
            clients: clients, routes: taskRoutes, budget: budget, log: CallLog(db), cache: ResultCache(db))
    }

    /// A Keychain account name for a new key of `provider`.
    public static func newKeyName(for provider: String) -> String {
        "llm.\(provider).\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// "AIza••••••••Q2xk": enough to tell keys apart, never enough to use one.
    public static func masked(_ key: String) -> String {
        guard key.count > 10 else { return String(repeating: "•", count: max(key.count, 4)) }
        return key.prefix(4) + String(repeating: "•", count: 12) + key.suffix(4)
    }
}
