import Foundation
import LLM
import OSLog
import Observation
import Secrets
import Store

/// The AI providers screen's state: the saved "llm" setting, the keys (in the key store, shown
/// masked), each provider's models, and today's usage.
@MainActor
@Observable
final class AISettingsModel {
    enum Models: Equatable {
        case unknown, loading
        case loaded([String])
        case failed(String)
    }

    /// What "Test" found for one key.
    enum KeyCheck: Equatable {
        case checking, works, rejected
        case failed(String)
    }

    private(set) var settings = LLMSettings.defaults()
    private(set) var models: [String: Models] = [:]
    private(set) var usage: [String: Usage] = [:]
    /// Dollars a paid provider's calls cost since the 1st, from its tokens at the guide's prices.
    private(set) var spentThisMonth: [String: Double] = [:]
    /// How each model has done since midnight: calls, failures and average answer time.
    private(set) var health: [ModelRef: ModelHealth] = [:]
    /// Key name → masked key, for display only. From the hint saved beside the key, so
    /// showing it never unlocks the key; a key saved before hints shows its mask once something
    /// reads it (opening AI providers lists models, which does).
    private(set) var masked: [String: String] = [:]
    @ObservationIgnored private var revealed: [String: String] = [:]
    /// Key name → what the last "Test" found.
    private(set) var keyChecks: [String: KeyCheck] = [:]
    /// Key name → how much it has left: Gemini's from Kairos's own count of the key's calls today,
    /// Ollama Cloud's from its balance (decided 2026-10-23).
    private(set) var allowances: [String: [UsageBar]] = [:]
    /// Key name → why its balance couldn't be read.
    private(set) var allowanceErrors: [String: String] = [:]
    /// Key name → when its balance was last asked for: at most once a minute, as Ollama asks.
    @ObservationIgnored private var balancesAsked: [String: Date] = [:]
    private(set) var error: String?

    @ObservationIgnored private let db: Database
    @ObservationIgnored private let secrets: any SecretStore
    /// Per provider, shared by every router: a model's refusals are learned once (T21), and a key
    /// that used up its quota is skipped by later operations until it's back.
    @ObservationIgnored private var capabilities: [String: ModelCapabilities] = [:]
    @ObservationIgnored private var rests: [String: KeyRests] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.keneepatel.kairos", category: "ai-settings")
    /// Previews keep their sample numbers: refreshing would read an empty database.
    @ObservationIgnored private var isPreview = false

    init(db: Database, secrets: any SecretStore) {
        self.db = db
        self.secrets = secrets
    }

    #if DEBUG
        /// For previews and snapshots.
        init(
            preview settings: LLMSettings, models: [String: Models], usage: [String: Usage], masked: [String: String],
            keyChecks: [String: KeyCheck] = [:], rests: [String: KeyRests] = [:], spent: [String: Double] = [:],
            health: [ModelRef: ModelHealth] = [:], allowances: [String: [UsageBar]] = [:], db: Database
        ) {
            self.db = db
            secrets = InMemorySecretStore()
            self.settings = settings
            self.models = models
            self.usage = usage
            self.masked = masked
            self.keyChecks = keyChecks
            self.rests = rests
            spentThisMonth = spent
            self.health = health
            self.allowances = allowances
            isPreview = true
        }
    #endif

    func load() async {
        settings =
            (try? await SettingsRepository(db).value(LLMSettings.storageKey, as: LLMSettings.self)) ?? .defaults()
        // A task added since you saved these (suggestions, 2026-10-22) follows your route for its kind.
        settings.addMissingRoutes()
        refreshMasks()
        await refreshUsage()
    }

    func refreshUsage() async {
        guard !isPreview else { return }
        let midnight = Calendar.current.startOfDay(for: Date())
        usage = (try? await CallLog(db).usageByProvider(since: midnight)) ?? [:]
        health = (try? await CallLog(db).health(since: midnight)) ?? [:]
        let month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? midnight
        for provider in settings.providers where !provider.preset.plans.isEmpty {
            let tokens = (try? await CallLog(db).tokens(provider: provider.id, since: month)) ?? [:]
            spentThisMonth[provider.id] = tokens.reduce(0) { total, item in
                total + (ModelGuide.entry(for: item.key)?.cost(input: item.value.input, output: item.value.output) ?? 0)
            }
        }
        for provider in settings.providers where provider.preset.balanceURL == nil {
            await refreshAllowances(of: provider, force: false)
        }
    }

    /// Asks each provider that reports a balance, at most once a minute per key: when AI providers
    /// is shown, never at launch.
    func refreshBalances() async {
        guard !isPreview else { return }
        for provider in settings.providers where provider.preset.balanceURL != nil {
            await refreshAllowances(of: provider, force: false)
        }
    }

    /// Each key's bars. A provider that reports a balance is asked once per key, at most once a
    /// minute unless `force`; the others are counted from this Mac's log of the key's calls.
    func refreshAllowances(of provider: LLMSettings.Provider, force: Bool) async {
        let now = Date()
        guard provider.preset.balanceURL != nil else {
            let use =
                (try? await KeyCallLog(db).use(
                    provider: provider.id, since: provider.preset.quotaDay(containing: now).start)) ?? [:]
            for name in provider.keyNames {
                allowances[name] = provider.preset.dailyBars(
                    models: models(on: provider.id), use: use[name] ?? [:], now: now)
            }
            return
        }
        for name in provider.keyNames {
            if !force, let asked = balancesAsked[name], now.timeIntervalSince(asked) < 60 { continue }
            guard let key = (try? secrets.read(SecretKey(name))) ?? nil else { continue }
            balancesAsked[name] = now
            do {
                allowances[name] = try await OpenAICompatibleProvider(preset: provider.preset, key: key).balance().bars
                allowanceErrors[name] = nil
            } catch {
                allowanceErrors[name] = Self.describeBalance(error, provider: provider.preset)
            }
        }
    }

    /// The provider's models your jobs use, in job order, then any other task's.
    private func models(on providerID: String) -> [String] {
        let chains =
            AIJob.allCases.map { settings.chain(for: $0) }
            + settings.routes.keys.sorted().compactMap { settings.routes[$0] }
        return chains.joined().filter { $0.provider == providerID }.map(\.model).reduce(into: []) { models, model in
            if !models.contains(model) { models.append(model) }
        }
    }

    /// The plan you're on, where the provider sells plans: how many calls run at once.
    func setPlan(_ plan: String, for providerID: String) async {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        settings.providers[index].plan = plan
        await save()
    }

    var usedToday: Int { usage.values.reduce(0) { $0 + $1.calls } }

    func router() -> LLMRouter {
        for provider in settings.providers {
            if capabilities[provider.id] == nil { capabilities[provider.id] = ModelCapabilities() }
            if rests[provider.id] == nil { rests[provider.id] = KeyRests() }
        }
        return settings.router(db: db, secrets: secrets, capabilities: capabilities, rests: rests)
    }

    /// The models a key used up, and roughly when each is back, e.g. "gemini-flash-latest, back in
    /// about 7 hours". Nil while it's fine. Kept for this session only: after a relaunch, one quick
    /// refusal finds out again.
    func restLine(for keyName: String, of providerID: String) -> String? {
        // A model whose bar already says it's used up isn't repeated here.
        let shown = Set((allowances[keyName] ?? []).filter(\.usedUp).map(\.label))
        guard
            let resting = rests[providerID]?.resting(key: keyName, at: SystemClock().now)
                .filter({ !shown.contains($0.model) }), !resting.isEmpty
        else { return nil }
        return resting.map { rest in
            let back = rest.remaining.formatted(
                .units(allowed: [.hours, .minutes], width: .wide, maximumUnitCount: 1, fractionalPart: .hide))
            return "\(rest.model), back in about \(rest.remaining < .seconds(60) ? "a minute" : back)"
        }.joined(separator: "; ")
    }

    // MARK: - Keys

    func addKey(_ key: String, to providerID: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = settings.providers.firstIndex(where: { $0.id == providerID }) else {
            return
        }
        let name = LLMSettings.newKeyName(for: providerID)
        do {
            try secrets.write(trimmed, for: SecretKey(name), hint: LLMSettings.masked(trimmed))
        } catch {
            self.error = "Couldn't save the key on this Mac."
            return
        }
        settings.providers[index].keyNames.append(name)
        await save()
        await refreshModels(for: providerID)
    }

    func replaceKey(_ name: String, with key: String, for providerID: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try secrets.write(trimmed, for: SecretKey(name), hint: LLMSettings.masked(trimmed))
            revealed[name] = nil
        } catch {
            self.error = "Couldn't save the key on this Mac."
            return
        }
        refreshMasks()
        await refreshModels(for: providerID)
    }

    func removeKey(_ name: String, from providerID: String) async {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        try? secrets.delete(SecretKey(name))
        settings.providers[index].keyNames.removeAll { $0 == name }
        keyChecks[name] = nil
        allowances[name] = nil
        allowanceErrors[name] = nil
        await save()
    }

    // MARK: - GitHub token

    /// Optional; lifts GitHub's 60-requests-an-hour limit for project import. Kept in the key store
    /// next to the AI keys, since this model already owns that store.
    static let gitHubTokenName = SecretKey("github.token")

    func gitHubToken() -> String? {
        (try? secrets.read(Self.gitHubTokenName)) ?? nil
    }

    func setGitHubToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? secrets.delete(Self.gitHubTokenName)
        } else {
            try? secrets.write(trimmed, for: Self.gitHubTokenName)
        }
    }

    // MARK: - Providers

    /// Presets not added yet.
    var addablePresets: [ProviderPreset] {
        ProviderPreset.all.filter { preset in !settings.providers.contains { $0.presetID == preset.id } }
    }

    func add(_ preset: ProviderPreset) async {
        settings.providers.append(LLMSettings.Provider(id: preset.id, presetID: preset.id))
        await save()
    }

    /// A provider at your own address. It takes keys like any other; one without keys sends none.
    func addCustom(name: String, baseURL: String) async -> String? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base), let host = url.host(), !host.isEmpty else {
            return "That doesn't look like a web address."
        }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard url.scheme == "https" || local else {
            return "Use an https:// address, so your key is never sent in the clear."
        }
        let id = "custom-\(UUID().uuidString.prefix(6).lowercased())"
        let label = name.trimmingCharacters(in: .whitespaces)
        settings.providers.append(
            LLMSettings.Provider(id: id, presetID: "custom", name: label.isEmpty ? host : label, baseURL: base))
        await save()
        return nil
    }

    func remove(_ providerID: String) async {
        guard let provider = settings.provider(providerID) else { return }
        for name in provider.keyNames { try? secrets.delete(SecretKey(name)) }
        settings.providers.removeAll { $0.id == providerID }
        for (task, chain) in settings.routes {
            settings.routes[task] = chain.filter { $0.provider != providerID }
        }
        await save()
    }

    /// Lists the provider's models, checking every key on the way so a mistyped backup shows up now
    /// rather than when the primary runs out. Listing models doesn't use generation quota.
    func refreshModels(for providerID: String) async {
        guard let provider = settings.provider(providerID) else { return }
        let keys: [(name: String?, key: String?)] =
            provider.preset.needsKey
            ? provider.keyNames.compactMap { name in
                ((try? secrets.read(SecretKey(name))) ?? nil).map { (name, $0) }
            } : [(nil, nil)]
        // The keys were read anyway: a key saved before hints shows its mask from now on.
        for case (let name?, let key?) in keys where masked[name] == Self.savedWithoutHint {
            revealed[name] = LLMSettings.masked(key)
            masked[name] = revealed[name]
        }
        if keys.isEmpty {
            models[providerID] = .failed("Add a key first.")
            return
        }
        models[providerID] = .loading
        var result: Models?
        for (name, key) in keys {
            if let name { keyChecks[name] = .checking }
            do {
                let client = OpenAICompatibleProvider(preset: provider.preset, key: key)
                // A public model list says nothing about the key: one tiny chat does (Ollama Cloud).
                if let model = provider.preset.keyCheckModel, key != nil { try await client.checkKey(model: model) }
                let ids = try await client.listModels()
                if let name { keyChecks[name] = .works }
                if case .loaded? = result {} else { result = .loaded(provider.preset.chatModels(from: ids)) }
            } catch {
                let message = Self.describe(error, provider: provider.preset)
                if let name {
                    keyChecks[name] = if case .keyRejected = error { .rejected } else { .failed(message) }
                }
                if result == nil { result = .failed(message) }
            }
        }
        models[providerID] = result
        await refreshAllowances(of: provider, force: true)
    }

    // MARK: - Routing and budget

    func primary(for task: TaskID) -> ModelRef? { settings.routes[task.rawValue]?.first }
    func fallback(for task: TaskID) -> ModelRef? { settings.routes[task.rawValue]?.dropFirst().first }

    func setRoute(_ task: TaskID, primary: ModelRef?, fallback: ModelRef?) async {
        settings.routes[task.rawValue] = [primary, fallback].compactMap { $0 }.reduce(into: []) { chain, ref in
            if !chain.contains(ref) { chain.append(ref) }
        }
        await save()
    }

    /// The provider's limit: the preset's unless you've set your own (a paid plan allows more).
    func requestsPerMinute(for providerID: String) -> Int {
        guard let provider = settings.provider(providerID) else { return 10 }
        return provider.requestsPerMinute ?? provider.preset.requestsPerMinute
    }

    func setRequestsPerMinute(_ value: Int, for providerID: String) async {
        guard let index = settings.providers.firstIndex(where: { $0.id == providerID }) else { return }
        let clamped = min(max(value, 1), 1_000)
        settings.providers[index].requestsPerMinute =
            clamped == settings.providers[index].preset.requestsPerMinute ? nil : clamped
        await save()
    }

    func setDailyCalls(_ calls: Int) async {
        settings.budget.dailyCalls = max(10, calls)
        await save()
    }

    /// "Keep everything on this Mac": every task on one local model.
    func keepEverythingLocal(on model: String, providerID: String) async {
        settings.routeEverything(to: ModelRef(provider: providerID, model: model))
        await save()
    }

    /// Every task of `job` on `chain`, primary first.
    func setChain(_ chain: [ModelRef], for job: AIJob) async {
        settings.setChain(chain, for: job)
        await save()
    }

    /// The setups that fit the providers and models you have.
    var setups: [AISetup] {
        AISetup.recommended(
            for: settings,
            models: models.compactMapValues { state in if case .loaded(let ids) = state { ids } else { nil } })
    }

    /// Whether every job already runs as `setup` says.
    func isInUse(_ setup: AISetup) -> Bool {
        setup.chains.allSatisfy { job, chain in
            chain.isEmpty || (settings.chain(for: job) == chain && settings.isUniform(job))
        }
    }

    func apply(_ setup: AISetup) async {
        settings.apply(setup)
        await save()
    }

    /// Models the pickers offer for each provider: what it listed, plus anything already chosen.
    func choices() -> [(provider: LLMSettings.Provider, models: [String])] {
        settings.providers.map { provider in
            var listed: [String] = if case .loaded(let ids) = models[provider.id] { ids } else { [] }
            let chosen = settings.routes.values.flatMap { $0 }.filter { $0.provider == provider.id }.map(\.model)
            for model in chosen.reversed() where !listed.contains(model) { listed.insert(model, at: 0) }
            return (provider, listed)
        }
    }

    // MARK: - Helpers

    private func save() async {
        do {
            try await SettingsRepository(db).save(settings, for: LLMSettings.storageKey)
            error = nil
        } catch {
            log.error("Saving AI settings failed: \(String(describing: error), privacy: .public)")
            self.error = "Couldn't save your AI settings."
        }
        refreshMasks()
    }

    /// Shown for a key saved before hints existed, until a test reveals its mask.
    static let savedWithoutHint = "Saved on this Mac"

    /// Hints only: nothing here reads a key.
    private func refreshMasks() {
        var result: [String: String] = [:]
        for name in settings.providers.flatMap(\.keyNames) {
            guard let summary = (try? secrets.summary(SecretKey(name))) ?? nil else { continue }
            result[name] = summary.hint ?? revealed[name] ?? Self.savedWithoutHint
        }
        masked = result
    }

    /// Why a key's balance couldn't be read, for the line under it.
    static func describeBalance(_ error: LLMError, provider: ProviderPreset) -> String {
        switch error {
        case .keyRejected: "\(provider.name) rejected this key, so its balance is unknown."
        case .rateLimited: "\(provider.name) asked for fewer balance checks. Try again in a minute."
        case .network, .timedOut: "Couldn't reach \(provider.name) for this key's balance."
        default: "\(provider.name) didn't report this key's balance (\(error.code))."
        }
    }

    static func describe(_ error: LLMError, provider: ProviderPreset) -> String {
        switch error {
        case .keyRejected: "\(provider.name) rejected this key."
        case .network where provider.isLocal: "Not running. Open Ollama, then try again."
        case .network: "Couldn't reach \(provider.name)."
        case .timedOut: "\(provider.name) didn't answer in time."
        case .rateLimited: "\(provider.name) asked us to slow down. Try again in a minute."
        default: "\(provider.name) couldn't list its models (\(error.code))."
        }
    }
}
