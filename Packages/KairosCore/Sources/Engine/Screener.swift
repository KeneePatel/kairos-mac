import AI
import Foundation
import Jobs
import KairosKit
import Resume
import Screening
import Store

/// What a screening run has done so far.
public struct ScreeningProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case filtering, analyzing, finished, stopped }

    public var phase = Phase.filtering
    /// Jobs this run looks at.
    public var total = 0
    /// Jobs it's finished with: filtered, judged, or failed.
    public var done = 0
    public var filtered = 0
    /// Analyses made by the AI this run.
    public var analyzed = 0
    /// Analyses that failed; those jobs wait for the next run.
    public var failed = 0
    /// Left waiting for the AI: analysis stopped, or isn't set up.
    public var waiting = 0
    public var yes = 0
    public var maybe = 0
    public var no = 0
    /// Why analysis stopped early, such as the daily budget.
    public var stopped: String?

    public init() {}
}

/// Screens jobs: the prefilter first for all of them (free and instant), then an analysis for each
/// survivor (a stored one is reused while the prompt is the same), two at a time, then the verdict,
/// which code decides from the analysis. A job you brought back skips the prefilter for good.
///
/// `.new` screens jobs with no verdict yet. `.everything` judges again, in place, every job you
/// haven't acted on: each keeps its verdict until it gets a new one, so nothing disappears while
/// the run goes or if it stops (2026-10-26).
public struct Screener: Sendable {
    public enum Scope: Sendable, Equatable { case new, everything }

    /// What re-evaluating one job did.
    public enum Outcome: Sendable, Equatable {
        case filtered(PrefilterRule)
        case judged(Verdict)
        case waiting
        /// The analysis couldn't be made, in words.
        case failed(String)
    }

    let store: KairosStore
    let router: AIRouter?
    let clock: any WallClock
    let width: Int

    /// `router` nil means no AI is set up: the prefilter runs, and stored analyses still decide.
    public init(store: KairosStore, router: AIRouter?, clock: any WallClock = SystemWallClock(), width: Int = 2) {
        self.store = store
        self.router = router
        self.clock = clock
        self.width = max(1, width)
    }

    /// Screens jobs; `analyses` caps the AI's analyses this run (the rest wait for the next).
    @discardableResult
    public func run(
        _ scope: Scope = .new, analyses limit: Int? = nil,
        progress report: @Sendable (ScreeningProgress) -> Void = { _ in }
    ) async throws -> Run {
        var run = try await store.activity.start(.screen, at: clock.now)
        var progress = ScreeningProgress()
        let context = try await loadContext()
        let candidates = try await store.screening.candidates(everything: scope == .everything)
        progress.total = candidates.count
        report(progress)

        // 1. The prefilter, and the verdicts stored analyses decide.
        let prefilter = context.prefilter(now: clock.now)
        let engine = context.verdicts
        let analyses = try await store.screening.analyses(for: candidates.map(\.job.id))
        var states: [String: ScreeningState] = [:]
        var forAI: [Job] = []
        for (job, state) in candidates where !Task.isCancelled {
            if state?.broughtBack != true, let rejection = prefilter.rejection(for: job) {
                states[job.id] = filtered(rejection)
                progress.filtered += 1
                progress.done += 1
            } else if let stored = analyses[job.id], stored.promptVersion == AnalyzeJobTask.promptVersion {
                let judged = judge(stored.analysis, job: job, engine: engine, context: context)
                states[job.id] = judged
                progress.count(judged.verdict)
                progress.done += 1
            } else {
                forAI.append(job)
                // A new job, or one your filters no longer drop, waits for its analysis; a judged
                // one keeps its verdict meanwhile.
                if state == nil || state?.stage == .filtered {
                    states[job.id] = ScreeningState(
                        stage: .waiting, broughtBack: state?.broughtBack ?? false, screenedAt: clock.now)
                }
            }
        }
        try await store.screening.record(states)
        report(progress)

        // 2. The AI's analyses, newest jobs first: the freshest postings are worth deciding soonest.
        progress.phase = .analyzing
        if let router, !forAI.isEmpty {
            let jobs = forAI.sorted { ($0.firstSeenAt, $0.id) > ($1.firstSeenAt, $1.id) }
            let now = Array(jobs.prefix(limit ?? jobs.count))
            progress.waiting += jobs.count - now.count
            await analyze(now, router: router, context: context, engine: engine, progress: &progress, report: report)
        } else if !forAI.isEmpty {
            progress.waiting = forAI.count
            progress.stopped = "AI isn't set up yet, so jobs that passed your filters wait for analysis."
        }

        progress.phase = Task.isCancelled ? .stopped : .finished
        var stats = RunStats()
        stats.screened = progress.done
        stats.filtered = progress.filtered
        stats.judged = progress.yes + progress.maybe + progress.no
        stats.waiting = progress.waiting
        stats.yes = progress.yes
        stats.maybe = progress.maybe
        stats.no = progress.no
        stats.aiCalls = progress.analyzed
        stats.stopped = progress.stopped == nil ? nil : true
        run.stats = stats
        run.finishedAt = clock.now
        run.error = Task.isCancelled ? "Stopped." : progress.stopped
        try await store.activity.finish(run)
        Self.log.info(
            "screening \(run.id.lowercased, privacy: .public): \(progress.total) jobs, \(progress.filtered) filtered, \(progress.analyzed) analysed, \(progress.failed) failed, \(progress.waiting) waiting"
        )
        report(progress)
        return run
    }

    static let log = Log.logger("screening")

    /// Screens one job again from scratch: the prefilter (unless you brought it back), then a fresh
    /// analysis, never a stored or cached one.
    public func reevaluate(_ id: String) async throws -> Outcome {
        guard let job = try await store.jobs.job(id) else { return .failed("This job is gone.") }
        let context = try await loadContext()
        let state = try await store.screening.state(for: id)
        if state?.broughtBack != true, let rejection = context.prefilter(now: clock.now).rejection(for: job) {
            try await store.screening.record(filtered(rejection), for: id)
            return .filtered(rejection.rule)
        }
        return try await analyzeOne(job, context: context, fresh: true)
    }

    /// "Bring back" from Filtered out: the filters never drop it again, and it's judged now from its
    /// stored analysis or the AI's, or waits for the AI.
    public func bringBack(_ id: String) async throws -> Outcome {
        guard try await store.screening.bringBack(id, at: clock.now), let job = try await store.jobs.job(id) else {
            return .failed("This job isn't in Filtered out.")
        }
        let context = try await loadContext()
        if let stored = try await store.screening.analysis(for: id),
            stored.promptVersion == AnalyzeJobTask.promptVersion
        {
            var judged = judge(stored.analysis, job: job, engine: context.verdicts, context: context)
            judged.broughtBack = true
            try await store.screening.record(judged, for: id)
            return .judged(judged.verdict ?? .maybe)
        }
        return try await analyzeOne(job, context: context, fresh: false)
    }

    /// When you apply to a job, its copies still in your lists leave them: the same posting under a
    /// slightly different title, or the same title and text under another company name. Each is
    /// filtered as "already applied", with Bring back like any rule. Returns how many.
    @discardableResult
    public func retireCopies(of appliedID: String) async throws -> Int {
        guard let applied = try await store.jobs.job(appliedID) else { return 0 }
        let reason = Rejection(
            rule: .alreadyApplied, reason: "You applied to “\(applied.title)” at \(applied.company).")
        var states: [String: ScreeningState] = [:]
        for (job, state) in try await store.screening.candidates(everything: true)
        where job.id != appliedID && state?.stage != .filtered && state?.broughtBack != true
            && Prefilter.isCopy(job, of: applied)
        {
            states[job.id] = filtered(reason)
        }
        try await store.screening.record(states)
        return states.count
    }

    // MARK: - Steps

    private func loadContext() async throws -> ScreeningContext {
        ScreeningContext(
            preferences: try await store.settings.preferences(), profile: try await store.settings.workProfile(),
            resume: try await store.resume.load(), applied: try await store.screening.appliedJobs())
    }

    private func filtered(_ rejection: Rejection) -> ScreeningState {
        ScreeningState(
            stage: .filtered, rule: rejection.rule.rawValue, reasons: [rejection.reason], screenedAt: clock.now)
    }

    private func judge(_ analysis: JobAnalysis, job: Job, engine: VerdictEngine, context: ScreeningContext)
        -> ScreeningState
    {
        let decision = engine.decide(analysis, for: job)
        return ScreeningState(
            stage: .judged, verdict: decision.verdict, rule: decision.rule.rawValue, reasons: decision.reasons,
            coverage: decision.coverage, match: decision.coverage.match,
            rank: context.rank(decision.verdict, for: job, match: decision.coverage.match), screenedAt: clock.now)
    }

    /// What became of one job's analysis in a run.
    private enum Analyzed: Sendable {
        case judged(Verdict)
        case failed
        /// Every later analysis would fail the same way, so analysis stops.
        case stop(String)
    }

    private func analyze(
        _ jobs: [Job], router: AIRouter, context: ScreeningContext, engine: VerdictEngine,
        progress: inout ScreeningProgress, report: @Sendable (ScreeningProgress) -> Void
    ) async {
        await withTaskGroup(of: Analyzed.self) { group in
            var pending = jobs[...]
            func startNext() {
                guard progress.stopped == nil, !Task.isCancelled, let job = pending.popFirst() else { return }
                group.addTask { await self.screen(job, router: router, context: context, engine: engine, fresh: false) }
            }
            for _ in 0..<width { startNext() }
            for await result in group {
                switch result {
                case .judged(let verdict):
                    progress.analyzed += 1
                    progress.done += 1
                    progress.count(verdict)
                case .failed:
                    progress.failed += 1
                    progress.waiting += 1
                case .stop(let reason):
                    progress.stopped = progress.stopped ?? reason
                    progress.waiting += 1
                }
                report(progress)
                startNext()
            }
            // Jobs never started, once analysis stopped, wait for the next run.
            progress.waiting += pending.count
        }
    }

    private func screen(_ job: Job, router: AIRouter, context: ScreeningContext, engine: VerdictEngine, fresh: Bool)
        async -> Analyzed
    {
        let input = context.analysisInput(for: job)
        do {
            let result = try await router.run(
                AnalyzeJobTask(), input: input, context: AIContext(jobID: job.id, fresh: fresh))
            let analysis = JobAnalysis(result.output, input: input)
            let state = judge(analysis, job: job, engine: engine, context: context)
            try await store.screening.save(
                StoredAnalysis(
                    analysis: analysis, model: result.model.description, promptVersion: AnalyzeJobTask.promptVersion,
                    analyzedAt: clock.now), state: state, for: job.id)
            return .judged(state.verdict ?? .maybe)
        } catch let error as AIError {
            return Self.result(of: error)
        } catch {
            return .failed
        }
    }

    private func analyzeOne(_ job: Job, context: ScreeningContext, fresh: Bool) async throws -> Outcome {
        guard let router else { return .waiting }
        switch await screen(job, router: router, context: context, engine: context.verdicts, fresh: fresh) {
        case .judged(let verdict): return .judged(verdict)
        case .failed: return .failed("The analysis failed. Try again in a minute.")
        case .stop(let reason): return .failed(reason)
        }
    }

    /// A missing key, a spent budget or quota, or a stop affects every job alike, so analysis
    /// stops; anything else fails just this job. The router already waited out short rate limits,
    /// so one that reaches here lasts longer.
    private static func result(of error: AIError) -> Analyzed {
        switch error {
        case .budgetReached: .stop("Today's AI budget is spent; the rest wait for tomorrow or a higher budget.")
        case .noModel, .noKey: .stop("AI isn't set up yet, so jobs that passed your filters wait for analysis.")
        case .keyRejected: .stop("Your AI key was rejected (check Settings, AI); the rest wait.")
        case .rateLimited, .quotaUsedUp, .modelNotOnPlan:
            .stop("Your AI provider's limit is reached for now; the rest wait for the next run.")
        case .cancelled: .stop("Stopped.")
        default: .failed
        }
    }
}

extension ScreeningProgress {
    mutating func count(_ verdict: Verdict?) {
        switch verdict {
        case .yes?: yes += 1
        case .maybe?: maybe += 1
        case .no?: no += 1
        case nil: break
        }
    }
}
