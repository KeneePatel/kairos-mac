import Foundation
import LLM
import Screening
import Store

/// Screens new jobs (SPEC §5.2, steps 4–7): the prefilter first, for all of them; then one
/// analysis per survivor (a stored one is reused while the prompt is the same), a few at a time;
/// then the verdict and rank. By default it screens the jobs with no verdict yet; `.everything`
/// judges every job again in place (Re-screen all). Progress arrives as an `AsyncStream`; stopping
/// the stream cancels the run. Jobs it can't analyse now keep the verdict they had, or none, and
/// wait for the next run.
public struct ScreeningRun: Sendable {
    /// Which jobs a run screens.
    public enum Scope: Sendable, Equatable {
        /// New jobs with no verdict yet: just fetched, or left waiting for the AI.
        case waiting
        /// Every new job your filters or the AI judged, judged again with your current settings
        /// (never one you judged yourself). Each keeps its verdict until it gets a new one, so
        /// nothing disappears while the run goes, or if it stops (2026-10-26).
        case everything
    }

    public struct Progress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable { case running, finished, cancelled }
        public var phase: Phase = .running
        /// Jobs to screen in this run.
        public var total = 0
        /// Jobs that got a verdict, or failed, so far.
        public var done = 0
        /// Dropped by the prefilter, before any AI call.
        public var prefiltered = 0
        /// Analyses made or reused.
        public var analyzed = 0
        /// Analyses that failed; those jobs wait for the next run.
        public var failed = 0
        /// Left without a verdict because analysis stopped (see `stopped`).
        public var waiting = 0
        /// Re-screen all only: kept the verdict they had, because the AI couldn't judge them again.
        public var kept = 0
        public var yes = 0
        public var maybe = 0
        /// Includes the prefiltered.
        public var no = 0
        /// Why analysis stopped early, such as the daily budget.
        public var stopped: String?

        public init() {}
    }

    /// The `run.stats` JSON for a screening run.
    public struct Stats: Codable, Equatable, Sendable {
        public let screened: Int
        public let prefiltered: Int
        public let analyzed: Int
        public let failed: Int
        public let yes: Int
        public let maybe: Int
        public let no: Int
        /// Left without a verdict until a later run (analysis stopped or isn't set up).
        public var waiting = 0
        public var budgetReached = false

        /// Share of the jobs the prefilter dropped (success criterion S6 wants at least half).
        public var dropRate: Double { screened == 0 ? 0 : Double(prefiltered) / Double(screened) }

        public static func decode(_ json: String) -> Stats? {
            try? JSONDecoder().decode(Stats.self, from: Data(json.utf8))
        }
    }

    let db: Database
    let router: LLMRouter?
    let scope: Scope
    let maxConcurrent: Int
    let now: @Sendable () -> Date

    /// `router` nil means no AI is set up: only the prefilter runs, and stored analyses still decide.
    /// Two analyses at a time matches the client's concurrency cap (SPEC §5.5).
    public init(
        db: Database, router: LLMRouter?, scope: Scope = .waiting, maxConcurrent: Int = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = db
        self.router = router
        self.scope = scope
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
    }

    public func start() -> AsyncStream<Progress> {
        AsyncStream { continuation in
            let task = Task { await perform(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What became of one job's analysis.
    enum Outcome: Sendable {
        case verdict(Verdict)
        case failed
        /// Every later analysis would fail the same way, so analysis stops.
        case stop(String)
        /// No stored analysis and no AI to make one: this job waits; the others go on.
        case waiting
    }

    private func perform(_ continuation: AsyncStream<Progress>.Continuation) async {
        var progress = Progress()
        let runs = RunRepository(db)
        let runID = try? await runs.begin(kind: "screen")
        let context = (try? await ScreeningContext.load(from: db)) ?? ScreeningContext()
        // A job no longer posted anywhere isn't worth an AI call (job collection v2).
        let jobs = ((try? await JobRepository(db).jobs(matching: JobFilter(states: [.new], openOnly: true))) ?? [])
            .filter { scope == .everything ? $0.verdictSource != .user : $0.verdict == nil }
            .sorted { ($0.firstSeenAt, $0.title, $0.id.rawValue) < ($1.firstSeenAt, $1.title, $1.id.rawValue) }
        progress.total = jobs.count
        continuation.yield(progress)

        // 1. The prefilter: free and instant, so every job goes through it first.
        let prefilter = context.prefilter(now: now())
        var survivors: [Job] = []
        for job in jobs where !Task.isCancelled {
            // A job you brought back from Filtered out skips the filters for good.
            guard !context.broughtBack.contains(job.id), let rejection = prefilter.rejection(for: job) else {
                // Your filters no longer drop it: it leaves Filtered out and waits for its analysis.
                if job.verdictSource == .prefilter,
                    (try? await JobRepository(db).clearPrefilterVerdict(for: job.id)) == true
                {
                    var cleared = job
                    cleared.verdict = nil
                    cleared.verdictSource = nil
                    survivors.append(cleared)
                } else {
                    survivors.append(job)
                }
                continue
            }
            try? await ScreeningRepository(db).record(rejection, for: job.id)
            _ = try? await JobRepository(db).setVerdict(
                .no, source: .prefilter, rank: context.rank(.no, for: job, match: 0), for: job.id)
            progress.prefiltered += 1
            progress.no += 1
            progress.done += 1
            continuation.yield(progress)
        }

        // 2. Analysis and verdict for the rest, a few at a time. A stored analysis decides even
        // without the AI ("Re-check filters"); a job without one waits for it.
        await analyze(survivors, with: router, context: context, progress: &progress, continuation)
        if router == nil, progress.waiting > 0 {
            progress.stopped = "AI isn't set up yet, so jobs that passed the prefilter wait for analysis."
        }

        progress.phase = Task.isCancelled ? .cancelled : .finished
        if let runID {
            var stats = Stats(
                screened: progress.done + progress.waiting + progress.kept, prefiltered: progress.prefiltered,
                analyzed: progress.analyzed, failed: progress.failed, yes: progress.yes, maybe: progress.maybe,
                no: progress.no)
            stats.waiting = progress.waiting
            stats.budgetReached = progress.stopped == Self.budgetStop
            let json = (try? JSONEncoder().encode(stats)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            try? await runs.finish(runID, stats: json, error: progress.phase == .cancelled ? "cancelled" : nil)
        }
        continuation.yield(progress)
        continuation.finish()
    }

    /// What Re-evaluate did to one job.
    public enum Reevaluation: Sendable, Equatable {
        case verdict(Verdict)
        /// The analysis failed; the job keeps its verdict.
        case failed
        /// Nothing could be asked, in words: no AI set up, a used-up budget or quota.
        case stopped(String)
    }

    /// Screens one job again from scratch with your current settings: the prefilter first, then,
    /// if it passes, a fresh analysis (never the stored one, never a cached reply) and its verdict.
    public func reevaluate(_ id: JobID) async -> Reevaluation {
        let context = (try? await ScreeningContext.load(from: db)) ?? ScreeningContext()
        guard let job = try? await JobRepository(db).job(id) else { return .failed }
        if !context.broughtBack.contains(job.id), let rejection = context.prefilter(now: now()).rejection(for: job) {
            try? await ScreeningRepository(db).record(rejection, for: job.id)
            _ = try? await JobRepository(db).setVerdict(
                .no, source: .prefilter, rank: context.rank(.no, for: job, match: 0), for: job.id)
            return .verdict(.no)
        }
        guard let router else { return .stopped("AI isn't set up yet. Add a key in Settings, AI providers.") }
        return Self.reevaluation(
            await screen(job, with: router, context: context, engine: context.verdictEngine(), fresh: true))
    }

    /// "Bring back" from Filtered out: the job leaves the filters' reach for good and is judged
    /// like any job that passed them (its stored analysis, or the AI's), or waits for the AI.
    public func bringBack(_ id: JobID) async -> Reevaluation {
        let settings = SettingsRepository(db)
        var kept = (try? await settings.value(ScreeningContext.broughtBackKey, as: [String].self)) ?? []
        if !kept.contains(id.rawValue) {
            kept.append(id.rawValue)
            try? await settings.save(kept, for: ScreeningContext.broughtBackKey)
        }
        _ = try? await JobRepository(db).clearPrefilterVerdict(for: id)
        let context = (try? await ScreeningContext.load(from: db)) ?? ScreeningContext()
        guard let job = try? await JobRepository(db).job(id) else { return .failed }
        return Self.reevaluation(await screen(job, with: router, context: context, engine: context.verdictEngine()))
    }

    private static func reevaluation(_ outcome: Outcome) -> Reevaluation {
        switch outcome {
        case .verdict(let verdict): .verdict(verdict)
        case .failed: .failed
        case .stop(let reason): .stopped(reason.replacing(Self.waitNote, with: "."))
        case .waiting: .stopped("AI isn't set up yet. Add a key in Settings, AI providers.")
        }
    }

    private func analyze(
        _ jobs: [Job], with router: LLMRouter?, context: ScreeningContext, progress: inout Progress,
        _ continuation: AsyncStream<Progress>.Continuation
    ) async {
        let engine = context.verdictEngine()
        await withTaskGroup(of: (Job, Outcome).self) { group in
            var pending = jobs[...]
            func startNext() {
                guard progress.stopped == nil, let job = pending.popFirst() else { return }
                group.addTask { (job, await screen(job, with: router, context: context, engine: engine)) }
            }
            for _ in 0..<maxConcurrent { startNext() }
            for await (job, outcome) in group {
                guard !Task.isCancelled else { break }
                switch outcome {
                case .verdict(let verdict):
                    progress.analyzed += 1
                    progress.done += 1
                    switch verdict {
                    case .yes: progress.yes += 1
                    case .maybe: progress.maybe += 1
                    case .no: progress.no += 1
                    }
                case .failed:
                    progress.failed += 1
                    progress.done += 1
                case .stop(let reason):
                    progress.stopped = progress.stopped ?? reason
                    if job.verdict == nil { progress.waiting += 1 } else { progress.kept += 1 }
                case .waiting:
                    if job.verdict == nil { progress.waiting += 1 } else { progress.kept += 1 }
                }
                continuation.yield(progress)
                startNext()
            }
            if progress.stopped != nil {
                let left = pending.count { $0.verdict == nil }
                progress.waiting += left
                progress.kept += pending.count - left
            }
        }
    }

    /// One job: its analysis (stored or new; always new when `fresh`), then its verdict and rank.
    /// Without a router only a stored analysis can decide; otherwise the job waits.
    private func screen(
        _ job: Job, with router: LLMRouter?, context: ScreeningContext, engine: VerdictEngine, fresh: Bool = false
    ) async -> Outcome {
        let analyses = AnalysisRepository(db)
        let analysis: JobAnalysis
        if !fresh, let stored = try? await analyses.analysis(for: job.id, promptVersion: AnalyzeJobTask.promptVersion) {
            analysis = stored.analysis
        } else {
            guard let router else { return .waiting }
            let input = context.analysisInput(for: job)
            do {
                let result = try await router.run(
                    AnalyzeJobTask(), input: input, context: CallContext(jobID: job.id.rawValue, fresh: fresh))
                analysis = JobAnalysis(result.output, input: input)
                try? await analyses.save(
                    analysis, for: job.id, model: result.model, promptVersion: AnalyzeJobTask.promptVersion)
            } catch {
                return Self.outcome(of: error)
            }
        }
        let decision = engine.decide(analysis, for: job, snippetOnly: context.isSnippet(job))
        try? await ScreeningRepository(db).record(decision, for: job.id)
        _ = try? await JobRepository(db).setVerdict(
            decision.verdict, source: .analysis,
            rank: context.rank(decision.verdict, for: job, match: decision.coverage.match),
            for: job.id)
        return .verdict(decision.verdict)
    }

    private static let waitNote = "; the rest wait for the next run."
    private static let budgetStop = Budget.reachedMessage + waitNote

    /// A missing key, a used-up budget or quota, or a stop affects every job alike, so analysis
    /// stops; anything else fails just this job. The client already waited out short rate limits, so
    /// one that reaches here lasts longer than a minute (a free tier's daily quota, say).
    static func outcome(of error: LLMError) -> Outcome {
        switch error {
        case .budgetReached: .stop(budgetStop)
        case .noProvider, .noKey: .stop("AI isn't set up yet, so jobs that passed the prefilter wait for analysis.")
        case .keyRejected: .stop("Your AI key was rejected (check Settings, AI providers)" + waitNote)
        case .rateLimited, .modelNotOnPlan: .stop("Your AI provider's limit is reached for now" + waitNote)
        case .cancelled: .stop("Stopped.")
        default: .failed
        }
    }
}
