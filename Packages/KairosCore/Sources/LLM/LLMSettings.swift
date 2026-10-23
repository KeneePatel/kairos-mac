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
        /// The plan you're on, for a provider that sells them (`ProviderPreset.plans`): how many
        /// calls run at once. Nil: the first, its free one.
        public var plan: String?

        public init(
            id: String, presetID: String, name: String? = nil, baseURL: String? = nil, keyNames: [String] = [],
            requestsPerMinute: Int? = nil, plan: String? = nil
        ) {
            self.id = id
            self.presetID = presetID
            self.name = name
            self.baseURL = baseURL
            self.keyNames = keyNames
            self.requestsPerMinute = requestsPerMinute
            self.plan = plan
        }

        /// Calls at once on your plan; nil where the preset sells none.
        public var concurrent: Int? {
            let plans = preset.plans
            return (plans.first { $0.id == plan } ?? plans.first)?.concurrent
        }

        public var preset: ProviderPreset {
            if presetID == "custom", let baseURL, let url = URL(string: baseURL) {
                return .custom(name: name ?? "Custom provider", baseURL: url, needsKey: !keyNames.isEmpty)
            }
            return ProviderPreset.all.first { $0.id == presetID } ?? .gemini
        }

        public var setup: ProviderSetup {
            ProviderSetup(
                id: id, preset: preset, keyNames: keyNames.map(SecretKey.init), requestsPerMinute: requestsPerMinute,
                concurrent: concurrent)
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

    /// Routes for tasks added since these settings were saved, which would otherwise fail with no
    /// provider. Each follows your own pick: the route of the task that sends the same data
    /// (`routeSources`), else of the first task of the same kind (Flash or Flash-Lite), else the
    /// default. A route you emptied stays empty.
    public mutating func addMissingRoutes() {
        let defaults = Self.defaults().routes
        for task in TaskID.catalog where routes[task.rawValue] == nil {
            guard let modelClass = TaskDefaults.catalog[task]?.modelClass else { continue }
            let saved = routes
            let routed: (TaskID) -> Bool = { other in other != task && !(saved[other.rawValue] ?? []).isEmpty }
            let sibling =
                Self.routeSources[task].flatMap { routed($0) ? $0 : nil }
                ?? TaskID.catalog.first { routed($0) && TaskDefaults.catalog[$0]?.modelClass == modelClass }
            if let route = sibling.flatMap({ routes[$0.rawValue] }) ?? defaults[task.rawValue] {
                routes[task.rawValue] = route
            }
        }
    }

    /// A later task and the one that sends the same data: suggestions send your screening profile,
    /// as reading postings does, so they go wherever you send that; shortening sends written
    /// bullets, as writing experience does.
    static let routeSources: [TaskID: TaskID] = [.suggestEvidence: .analyzeJob, .shortenBullets: .writeExperience]

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
                rests: rests[provider.id] ?? KeyRests(), meter: KeyCallLog(db).meter(provider: provider.id),
                transport: transport)
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
