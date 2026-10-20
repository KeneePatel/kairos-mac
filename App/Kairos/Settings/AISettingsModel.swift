import Foundation
import LLM
import OSLog
import Observation
import Secrets
import Store

/// The AI providers screen's state: the saved "llm" setting, the keys (in the Keychain, shown
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
    /// Keychain account → masked key, for display only. From the hint saved beside the key, so
    /// showing it never unlocks the key; a key saved before hints shows its mask once something
    /// reads it (opening AI providers lists models, which does).
    private(set) var masked: [String: String] = [:]
    @ObservationIgnored private var revealed: [String: String] = [:]
    /// Keychain account → what the last "Test" found.
    private(set) var keyChecks: [String: KeyCheck] = [:]
    private(set) var error: String?

    @ObservationIgnored private let db: Database
    @ObservationIgnored private let secrets: any SecretStore
    /// Per provider, shared by every router: a model's refusals are learned once (T21), and a key
    /// that used up its quota is skipped by later operations until it's back.
    @ObservationIgnored private var capabilities: [String: ModelCapabilities] = [:]
    @ObservationIgnored private var rests: [String: KeyRests] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.keneepatel.kairos", category: "ai-settings")

    init(db: Database, secrets: any SecretStore) {
        self.db = db
        self.secrets = secrets
    }

    #if DEBUG
        /// For previews and snapshots.
        init(
            preview settings: LLMSettings, models: [String: Models], usage: [String: Usage], masked: [String: String],
            keyChecks: [String: KeyCheck] = [:], rests: [String: KeyRests] = [:], db: Database
        ) {
            self.db = db
            secrets = InMemorySecretStore()
            self.settings = settings
            self.models = models
            self.usage = usage
            self.masked = masked
            self.keyChecks = keyChecks
            self.rests = rests
        }
    #endif

    func load() async {
        settings =
            (try? await SettingsRepository(db).value(LLMSettings.storageKey, as: LLMSettings.self)) ?? .defaults()
        refreshMasks()
        await refreshUsage()
    }

    func refreshUsage() async {
        let midnight = Calendar.current.startOfDay(for: Date())
        usage = (try? await CallLog(db).usageByProvider(since: midnight)) ?? [:]
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
        guard let resting = rests[providerID]?.resting(key: keyName, at: SystemClock().now), !resting.isEmpty
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
            self.error = "Couldn't save the key to your Keychain."
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
            self.error = "Couldn't save the key to your Keychain."
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
        await save()
    }

    // MARK: - GitHub token

    /// Optional; lifts GitHub's 60-requests-an-hour limit for project import. Kept in the Keychain
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
        for case (let name?, let key?) in keys where masked[name] == "Saved in your Keychain" {
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
                let ids = try await OpenAICompatibleProvider(preset: provider.preset, key: key).listModels()
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

    /// Hints only: nothing here reads a key, so opening Kairos never asks for your password.
    private func refreshMasks() {
        var result: [String: String] = [:]
        for name in settings.providers.flatMap(\.keyNames) {
            guard let summary = (try? secrets.summary(SecretKey(name))) ?? nil else { continue }
            result[name] = summary.hint ?? revealed[name] ?? "Saved in your Keychain"
        }
        masked = result
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
