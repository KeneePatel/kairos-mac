import Foundation

/// The jobs the AI does in Kairos, each a group of tasks that share one chain of models: the way
/// Settings asks for models, instead of task by task (decided 2026-10-23). A task can still be set
/// on its own; its job then shows that its tasks differ.
public enum AIJob: String, CaseIterable, Sendable, Identifiable {
    case reading, writing, letters, importing

    public var id: String { rawValue }

    public var tasks: [TaskID] {
        switch self {
        case .reading: [.analyzeJob, .select, .suggestEvidence]
        case .writing:
            [
                .writeExperience, .writeProjects, .writeSkills, .writeSummary, .rewriteSection, .shortenBullets,
                .gapBullets,
            ]
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
        case .writing: "Writes, rewrites and shortens your resume's lines. Quality shows here."
        case .letters: "Writes the cover letter for a build."
        case .importing: "Reads a resume or a GitHub project into your master resume."
        }
    }

    /// The most models a chain holds: a primary and two to fall back on.
    public static let maxChain = 3
}

extension LLMSettings {
    /// The job's chain, as its first task has it.
    public func chain(for job: AIJob) -> [ModelRef] {
        job.tasks.lazy.compactMap { routes[$0.rawValue] }.first ?? []
    }

    /// Whether every task in the job runs on the same chain: false once one is set on its own.
    public func isUniform(_ job: AIJob) -> Bool {
        let chains = job.tasks.compactMap { routes[$0.rawValue] }
        return chains.allSatisfy { $0 == chains.first }
    }

    /// Every task in the job on `chain`, without repeats, at most `AIJob.maxChain` long.
    public mutating func setChain(_ chain: [ModelRef], for job: AIJob) {
        let kept = chain.reduce(into: [ModelRef]()) { kept, ref in
            if !kept.contains(ref), kept.count < AIJob.maxChain { kept.append(ref) }
        }
        for task in job.tasks { routes[task.rawValue] = kept }
    }
}

/// A whole set of chains, one per job, applied in one go from Settings.
public struct AISetup: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let chains: [AIJob: [ModelRef]]

    /// The setups that fit the providers you have, best first. `models` is what each provider
    /// lists (by provider id), so a setup names only models that are there.
    public static func recommended(for settings: LLMSettings, models: [String: [String]]) -> [AISetup] {
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

extension LLMSettings {
    /// Each job on the setup's chain.
    public mutating func apply(_ setup: AISetup) {
        for (job, chain) in setup.chains where !chain.isEmpty { setChain(chain, for: job) }
    }
}
