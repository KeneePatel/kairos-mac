import Foundation
import KairosKit

/// Your AI setup: providers, their keys' names, each task's chain of models, the daily budget. It
/// names keys but never holds them. The JSON shape is the first Kairos's "llm" setting, so a setup
/// made there reads here unchanged.
public struct AISettings: Codable, Sendable, Equatable {
    public struct Provider: Codable, Sendable, Equatable, Identifiable {
        /// Unique among your providers; `ModelRef.provider` points here.
        public var id: String
        public var presetID: String
        /// Custom providers only.
        public var name: String?
        public var baseURL: String?
        /// Secret names, in rotation order: the first is the primary.
        public var keyNames: [String]
        /// Overrides the preset's requests per minute.
        public var requestsPerMinute: Int?
        /// The plan you're on, for a provider that sells them. Nil: the first, its free one.
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

        public var preset: ProviderPreset {
            if presetID == "custom", let baseURL, let url = URL(string: baseURL) {
                return .custom(name: name ?? "Custom provider", baseURL: url, needsKey: !keyNames.isEmpty)
            }
            return ProviderPreset.all.first { $0.id == presetID } ?? .gemini
        }

        /// Calls at once on your plan.
        public var concurrent: Int {
            let plans = preset.plans
            return (plans.first { $0.id == plan } ?? plans.first)?.concurrent ?? (preset.isLocal ? 1 : 2)
        }

        public var displayName: String { name ?? preset.name }
    }

    public struct Budget: Codable, Sendable, Equatable {
        public var dailyCalls: Int
        public var dailyTokens: Int?

        public init(dailyCalls: Int = 300, dailyTokens: Int? = nil) {
            self.dailyCalls = dailyCalls
            self.dailyTokens = dailyTokens
        }

        public func allows(calls: Int, tokens: Int) -> Bool {
            calls < dailyCalls && (dailyTokens.map { tokens < $0 } ?? true)
        }
    }

    public var providers: [Provider]
    /// Task id → its models, primary first.
    public var routes: [String: [ModelRef]]
    public var budget: Budget

    public init(providers: [Provider], routes: [String: [ModelRef]], budget: Budget = Budget()) {
        self.providers = providers
        self.routes = routes
        self.budget = budget
    }

    public static let storageKey = "llm"

    /// New setups start with Gemini: writing on its newest Flash, extraction on Flash-Lite. Ollama
    /// on this Mac is listed as the private option.
    public static func defaults() -> AISettings {
        let gemini = ProviderPreset.gemini
        var routes: [String: [ModelRef]] = [:]
        for task in TaskID.catalog {
            if let model = gemini.defaultModels[TaskProfile.of(task).modelClass] {
                routes[task.rawValue] = [ModelRef(provider: gemini.id, model: model)]
            }
        }
        return AISettings(
            providers: [
                Provider(id: gemini.id, presetID: gemini.id), Provider(id: "ollama-local", presetID: "ollama-local"),
            ],
            routes: routes)
    }

    public func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    public func chain(for task: TaskID) -> [ModelRef] { routes[task.rawValue] ?? [] }

    /// Routes for tasks added since these settings were saved: each follows the task that sends the
    /// same data, else the first task of the same model class, else the default. A route you
    /// emptied stays empty.
    public mutating func addMissingRoutes() {
        let defaults = Self.defaults().routes
        for task in TaskID.catalog where routes[task.rawValue] == nil {
            let saved = routes
            let routed: (TaskID) -> Bool = { other in other != task && !(saved[other.rawValue] ?? []).isEmpty }
            let sibling =
                Self.sameData[task].flatMap { routed($0) ? $0 : nil }
                ?? TaskID.catalog.first {
                    routed($0) && TaskProfile.of($0).modelClass == TaskProfile.of(task).modelClass
                }
            if let route = sibling.flatMap({ routes[$0.rawValue] }) ?? defaults[task.rawValue] {
                routes[task.rawValue] = route
            }
        }
    }

    /// A task and the one that sends the same data: suggestions send your screening profile, as
    /// reading postings does; shortening sends written bullets, as writing experience does.
    static let sameData: [TaskID: TaskID] = [.suggestEvidence: .analyzeJob, .shortenBullets: .writeExperience]

    /// "llm.gemini.ab12cd34": the secret name for a new key of `provider`.
    public static func newKeyName(for provider: String) -> String {
        "llm.\(provider).\(UUID().uuidString.prefix(8).lowercased())"
    }
}

/// The jobs the AI does, each a group of tasks sharing one chain of models: how Settings asks for
/// models (decided 2026-10-23). A task can still be set on its own.
public enum AIJob: String, CaseIterable, Sendable, Identifiable {
    case reading, writing, letters, importing

    public var id: String { rawValue }

    public var tasks: [TaskID] {
        switch self {
        case .reading: [.analyzeJob, .suggestEvidence]
        case .writing: [.writeExperience, .writeProjects, .writeSkills, .writeSummary, .shortenBullets, .gapBullets]
        case .letters: [.coverLetter]
        case .importing: [.importResume, .importGitHubRepo]
        }
    }

    public var title: String {
        switch self {
        case .reading: "Reading postings"
        case .writing: "Writing resumes"
        case .letters: "Cover letters"
        case .importing: "Importing"
        }
    }

    public var detail: String {
        switch self {
        case .reading: "Screens each new posting against your resume. Runs most often, so a fast free model suits it."
        case .writing: "Writes and shortens your resume's lines. Quality shows here."
        case .letters: "Writes the cover letter for a build."
        case .importing: "Reads a resume or a GitHub project into your master resume."
        }
    }

    /// A primary and two to fall back on.
    public static let maxChain = 3
}

extension AISettings {
    public func chain(for job: AIJob) -> [ModelRef] {
        job.tasks.lazy.compactMap { routes[$0.rawValue] }.first ?? []
    }

    /// Whether every task in the job runs on the same chain.
    public func isUniform(_ job: AIJob) -> Bool {
        let chains = job.tasks.compactMap { routes[$0.rawValue] }
        return chains.allSatisfy { $0 == chains.first }
    }

    /// Every task in the job on `chain`, without repeats, at most `AIJob.maxChain` long.
    public mutating func setChain(_ chain: [ModelRef], for job: AIJob) {
        let kept = Array(chain.uniqued().prefix(AIJob.maxChain))
        for task in job.tasks { routes[task.rawValue] = kept }
    }

    public mutating func apply(_ setup: AISetup) {
        for (job, chain) in setup.chains where !chain.isEmpty { setChain(chain, for: job) }
    }
}

/// A whole set of chains, one per job, applied in one go from Settings.
public struct AISetup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let chains: [AIJob: [ModelRef]]

    /// The setups that fit your providers, best first. `models` is what each provider lists, so a
    /// setup names only models that are there.
    public static func recommended(for settings: AISettings, models: [String: [String]]) -> [AISetup] {
        func ref(_ preset: ProviderPreset, _ model: String) -> ModelRef? {
            guard let provider = settings.providers.first(where: { $0.presetID == preset.id }),
                (models[provider.id] ?? []).contains(model)
            else { return nil }
            return ModelRef(provider: provider.id, model: model)
        }
        let flash = ref(.gemini, "gemini-flash-latest")
        let lite = ref(.gemini, "gemini-flash-lite-latest")
        let gemma = ref(.ollamaCloud, "gemma4:31b")
        let gptOss = ref(.ollamaCloud, "gpt-oss:120b")
        let local = settings.providers.first { $0.preset.isLocal }.flatMap { provider in
            (models[provider.id] ?? []).first.map { ModelRef(provider: provider.id, model: $0) }
        }
        var setups: [AISetup] = []
        if let gemma, lite != nil || gptOss != nil {
            setups.append(
                AISetup(
                    id: "free", title: "Free: Gemini and Ollama",
                    detail:
                        "Resumes and letters on Ollama's gemma4:31b, the best free writer in Kairos's tests, falling back to Gemini Flash-Lite. Postings on Flash-Lite.",
                    chains: [
                        .reading: [lite, gemma, local].compactMap { $0 },
                        .writing: [gemma, lite, gptOss].compactMap { $0 },
                        .letters: [gemma, lite, gptOss].compactMap { $0 },
                        .importing: [flash, lite, gemma].compactMap { $0 },
                    ]))
        }
        if let lite {
            setups.append(
                AISetup(
                    id: "gemini", title: "Gemini only",
                    detail:
                        "Everything on Gemini Flash-Lite, with Flash to fall back on. Flash is often overloaded on the free tier, so it isn't first.",
                    chains: [
                        .reading: [lite, local].compactMap { $0 }, .writing: [lite, flash].compactMap { $0 },
                        .letters: [lite, flash].compactMap { $0 }, .importing: [flash, lite].compactMap { $0 },
                    ]))
        }
        if let local {
            setups.append(
                AISetup(
                    id: "private", title: "Private: this Mac only",
                    detail: "Everything on \(local.model) in Ollama. Nothing leaves this Mac; slower, no daily caps.",
                    chains: Dictionary(uniqueKeysWithValues: AIJob.allCases.map { ($0, [local]) })))
        }
        return setups
    }
}
