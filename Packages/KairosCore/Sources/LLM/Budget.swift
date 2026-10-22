import Foundation

/// The user's daily limits (SPEC §5.5, Budget). When one is reached, LLM steps pause with "Daily AI
/// budget reached" and the rest of the pipeline carries on.
public struct Budget: Sendable, Equatable, Codable {
    public var dailyCalls: Int
    public var dailyTokens: Int?

    public init(dailyCalls: Int = 300, dailyTokens: Int? = nil) {
        self.dailyCalls = dailyCalls
        self.dailyTokens = dailyTokens
    }

    public func allows(_ usage: Usage) -> Bool {
        usage.calls < dailyCalls && (dailyTokens.map { usage.tokens < $0 } ?? true)
    }

    /// The words the UI shows when a step pauses.
    public static let reachedMessage = "Daily AI budget reached"
}

/// Per-task settings from the task catalog (SPEC §5.5): token budget, temperature, timeout, and
/// which model class the task uses by default.
public struct TaskDefaults: Sendable, Equatable {
    public let budget: TokenBudget
    public let temperature: Double
    /// Nil for `triage`, which runs on device when it runs at all.
    public let modelClass: ProviderPreset.ModelClass?
    /// SPEC §5.5, Reliability: 60 s for extraction, 120 s for writing. `importResume` counts as
    /// writing here: it drafts a whole resume, up to 6,000 tokens.
    public let timeoutSeconds: Int

    public init(
        budget: TokenBudget, temperature: Double, modelClass: ProviderPreset.ModelClass?, timeoutSeconds: Int = 60
    ) {
        self.budget = budget
        self.temperature = temperature
        self.modelClass = modelClass
        self.timeoutSeconds = timeoutSeconds
    }

    public static let catalog: [TaskID: TaskDefaults] = [
        .importResume: TaskDefaults(
            budget: TokenBudget(input: 10_000, output: 6_000), temperature: 0, modelClass: .flash, timeoutSeconds: 120),
        .importGitHubRepo: TaskDefaults(
            budget: TokenBudget(input: 3_000, output: 600), temperature: 0.2, modelClass: .flashLite),
        .triage: TaskDefaults(budget: TokenBudget(input: 3_000, output: 500), temperature: 0, modelClass: nil),
        .analyzeJob: TaskDefaults(
            budget: TokenBudget(input: 7_000, output: 1_500), temperature: 0, modelClass: .flashLite),
        .select: TaskDefaults(budget: TokenBudget(input: 4_000, output: 500), temperature: 0, modelClass: .flashLite),
        .writeSummary: writer, .writeSkills: writer, .writeExperience: writer, .writeProjects: writer,
        .rewriteSection: TaskDefaults(
            budget: TokenBudget(input: 3_000, output: 1_500), temperature: 0.4, modelClass: .flash, timeoutSeconds: 120),
        .gapBullets: TaskDefaults(
            budget: TokenBudget(input: 3_000, output: 800), temperature: 0.5, modelClass: .flash, timeoutSeconds: 120),
        .coverLetter: TaskDefaults(
            budget: TokenBudget(input: 4_000, output: 1_000), temperature: 0.6, modelClass: .flash, timeoutSeconds: 120),
        .suggestEvidence: TaskDefaults(
            budget: TokenBudget(input: 4_000, output: 800), temperature: 0.3, modelClass: .flashLite),
    ]

    private static let writer = TaskDefaults(
        budget: TokenBudget(input: 4_000, output: 1_500), temperature: 0.4, modelClass: .flash, timeoutSeconds: 120)

    /// For a task outside the catalog (tests, future tasks).
    public static let fallback = TaskDefaults(
        budget: TokenBudget(input: 4_000, output: 1_000), temperature: 0, modelClass: .flash)
}
