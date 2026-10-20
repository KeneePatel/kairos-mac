import Foundation
import JobSources
import LLM
import OSLog
import Observation
import Pipeline
import Render
import Screening
import Secrets
import Store
import Tailoring

/// What the screens show for the open account, and the actions they call. One per window scene.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case opening, ready
        case failed(String)
    }

    struct JobSection: Identifiable {
        let id: String
        let title: String
        let jobs: [Job]
    }

    private(set) var phase: Phase = .opening
    /// The sidebar's selection; a build switches it to Builds.
    var section: AppSection = .today
    private(set) var sources: [Source] = []
    private(set) var jobs: [Job] = []
    private(set) var lastFetch: Run?
    private(set) var lastScreening: Run?
    /// The fetch in flight, or the last one this session; it holds per-source failures.
    private(set) var progress: FetchRun.Progress?
    /// Screening after the fetch: prefilter, analysis, verdicts (T30).
    private(set) var screening: ScreeningRun.Progress?
    /// Each job's latest decision (screening's or yours), keyed by job id.
    private(set) var screenings: [String: ScreeningRecord] = [:]
    /// What you're looking for (synced) and where you may work (this Mac only).
    private(set) var searchPreferences = SearchPreferences()
    private(set) var workProfile = WorkProfile()
    /// Off until you turn it on (SPEC §5.3).
    private(set) var stretch = StretchSettings()
    /// Every job's builds, newest first, and where each running one is.
    private(set) var builds: [BuildRecord] = []
    private(set) var buildSteps: [UUID: BuildStep] = [:]
    var selectedBuild: UUID?
    private(set) var isFetching = false
    /// The master resume editor's state; there once the database is open.
    private(set) var resume: ResumeModel?
    /// AI providers, keys (in the Keychain) and routing; there once the database is open.
    private(set) var ai: AISettingsModel?

    init() {}

    #if DEBUG
        /// For snapshots: an open model with sample jobs and their screening.
        init(
            preview jobs: [Job], screenings: [String: ScreeningRecord], sources: [Source],
            preferences: SearchPreferences = SearchPreferences(), profile: WorkProfile = WorkProfile(),
            stretch: StretchSettings = StretchSettings(), resume: ResumeModel? = nil
        ) {
            self.resume = resume
            self.jobs = jobs
            self.screenings = screenings
            self.sources = sources
            searchPreferences = preferences
            workProfile = profile
            self.stretch = stretch
            phase = .ready
        }
    #endif

    @ObservationIgnored private var db: Database?
    @ObservationIgnored private var buildQueue: BuildQueue?
    @ObservationIgnored private var buildEvents: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private let http = URLSessionHTTPClient()
    @ObservationIgnored private let log = Logger(subsystem: "com.keneepatel.kairos", category: "model")

    /// Opens the signed-out local profile's database (accounts come with T27).
    func open() async {
        guard db == nil else { return }
        do {
            let url = try AccountStore.applicationSupport().databaseURL(for: .local)
            let db = try Database(path: url.path)
            let capabilities = try await db.capabilities()
            guard capabilities.json1, capabilities.strictTables else {
                phase = .failed("This Mac's SQLite \(capabilities.version) lacks JSON functions or STRICT tables.")
                return
            }
            try await Migrator.migrate(db, with: Migrator.bundled())
            self.db = db
            let resume = ResumeModel(db: db)
            await resume.load()
            self.resume = resume
            // Each key is read from the Keychain at most once a session, however many runs use it.
            let ai = AISettingsModel(
                db: db, secrets: CachingSecretStore(KeychainStore(service: "com.keneepatel.kairos")))
            await ai.load()
            self.ai = ai
            await reload()
            phase = .ready
        } catch {
            log.error("Opening the database failed: \(String(describing: error), privacy: .public)")
            phase = .failed("Kairos couldn't open its database: \(error)")
        }
    }

    func reload() async {
        guard let db else { return }
        do {
            sources = try await SourceRepository(db).sources()
            jobs = try await JobRepository(db).jobs()
            lastFetch = try await RunRepository(db).runs(kind: "fetch", limit: 1).first
            lastScreening = try await RunRepository(db).runs(kind: "screen", limit: 1).first
            screenings = try await ScreeningRepository(db).latestByJob()
            builds = try await BuildRepository(db).recent()
            searchPreferences =
                try await SettingsRepository(db).value(SearchPreferences.storageKey, as: SearchPreferences.self)
                ?? SearchPreferences()
            workProfile =
                try await PrivateSettingsRepository(db).value(WorkProfile.storageKey, as: WorkProfile.self)
                ?? WorkProfile()
            stretch =
                try await SettingsRepository(db).value(StretchSettings.storageKey, as: StretchSettings.self)
                ?? StretchSettings()
        } catch {
            log.error("Reloading failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Sources

    /// Adds the company behind a careers URL. Returns why it couldn't, or nil once added.
    func addCompany(careersURL: String, name: String) async -> String? {
        guard let db else { return "The database isn't open." }
        let kind: SourceKind
        let slug: String
        switch ATSDetector.detect(careersURL) {
        case .detected(let detectedKind, let detectedSlug):
            (kind, slug) = (detectedKind, detectedSlug)
        case .notDetected(let reason):
            return reason
        }
        if sources.contains(where: { $0.kind == kind && BoardConfig.decode($0.config)?.slug == slug }) {
            return "That board is already in your watchlist."
        }
        let company = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let config = BoardConfig(slug: slug, company: company.isEmpty ? nil : company)
            _ = try await SourceRepository(db).add(kind: kind, config: config.json)
            await reload()
            return nil
        } catch {
            return "Couldn't save it: \(error)"
        }
    }

    func setEnabled(_ enabled: Bool, for source: Source) async {
        guard let db else { return }
        var changed = source
        changed.enabled = enabled
        _ = try? await SourceRepository(db).save(changed)
        await reload()
    }

    func remove(_ source: Source) async {
        guard let db else { return }
        _ = try? await SourceRepository(db).tombstone(source.id)
        await reload()
    }

    func source(_ id: UUID) -> Source? {
        sources.first { $0.id == id }
    }

    /// The last failure for this source in this session's fetch, if it failed.
    func failure(for source: Source) -> String? {
        progress?.failures.first { $0.sourceID == source.id }?.message
    }

    func openRoles(for source: Source) -> Int {
        jobs.count { $0.sourceID == source.id }
    }

    // MARK: - Jobs

    /// Canada first, then the US, then jobs whose country the posting didn't state.
    var jobSections: [JobSection] {
        let groups: [(String, String, Country?)] = [
            ("ca", "Canada", .canada), ("us", "United States", .unitedStates), ("none", "Location not stated", nil),
        ]
        return groups.compactMap { id, title, country in
            let matching = jobs.filter { $0.country == country }
            return matching.isEmpty ? nil : JobSection(id: id, title: title, jobs: matching)
        }
    }

    func job(_ id: JobID?) -> Job? {
        id.flatMap { id in jobs.first { $0.id == id } }
    }

    /// Fetches every enabled board, then screens what's new (SPEC §5.2). Without an AI key only
    /// the prefilter runs, and the rest wait.
    func fetchNow() {
        guard let db, !isFetching else { return }
        isFetching = true
        screening = nil
        let http = self.http
        let run = PipelineRun(
            fetch: FetchRun(db: db, makeSource: { try SourceFactory.make($0, http: http) }),
            screening: ScreeningRun(db: db, router: ai?.router()))
        fetchTask = Task { [weak self] in
            for await event in run.start() {
                switch event {
                case .fetching(let update):
                    self?.progress = update
                    if update.added > 0 { await self?.reload() }
                case .screening(let update):
                    self?.screening = update
                    // Verdicts arrive one by one; refresh the list now and then, not on every one.
                    if update.done % 5 == 0 { await self?.reload() }
                }
            }
            if Task.isCancelled { self?.progress?.phase = .cancelled }
            self?.isFetching = false
            await self?.reload()
        }
    }

    func stopFetch() {
        fetchTask?.cancel()
    }

    // MARK: - Today

    /// Screened jobs you haven't acted on, best first.
    var todayJobs: [Job] {
        jobs.filter { $0.verdict != nil && ($0.state == .new || $0.state == .shortlisted) }
            .sorted { ($0.rank ?? 0, $1.title) > ($1.rank ?? 0, $0.title) }
    }

    /// Today's jobs with `verdict` (all when nil), grouped by country in your order.
    func todaySections(showing verdict: Verdict?) -> [JobSection] {
        let shown = todayJobs.filter { verdict == nil || $0.verdict == verdict }
        let countries: [Country?] =
            searchPreferences.countries
            + Country.allCases.filter {
                !searchPreferences.countries.contains($0)
            } + [nil]
        return countries.compactMap { country in
            let matching = shown.filter { $0.country == country }
            guard !matching.isEmpty else { return nil }
            return JobSection(
                id: country?.rawValue ?? "none", title: country?.displayName ?? "Location not stated", jobs: matching)
        }
    }

    func todayCount(_ verdict: Verdict?) -> Int {
        todayJobs.count { verdict == nil || $0.verdict == verdict }
    }

    /// New jobs that passed the prefilter and still wait for an analysis.
    var waitingForAI: Int { jobs.count { $0.verdict == nil && $0.state == .new } }

    func screening(for job: Job) -> ScreeningRecord? { screenings[job.id.rawValue] }

    /// 0 to 100, from the share of the posting your skills cover; nil when nothing was analysed.
    func matchScore(for job: Job) -> Int? {
        screening(for: job)?.coverage.map { Int(($0.match * 100).rounded()) }
    }

    /// The analysis behind a verdict, for the explanation.
    func analysis(for job: Job) async -> JobAnalysis? {
        guard let db else { return nil }
        return try? await AnalysisRepository(db).analysis(for: job.id, promptVersion: AnalyzeJobTask.promptVersion)?
            .analysis
    }

    /// Your verdict wins over screening's from now on.
    func overrule(_ job: Job, to verdict: Verdict) async {
        guard let db else { return }
        let match = screening(for: job)?.coverage?.match ?? 0
        let rank = Ranking.rank(verdict, country: job.country, match: match, countries: searchPreferences.countries)
        do {
            try await JobRepository(db).setUserVerdict(verdict, rank: rank, for: job.id)
            try await ScreeningRepository(db).recordOverrule(verdict, for: job.id)
        } catch {
            log.error("Overruling failed: \(String(describing: error), privacy: .public)")
        }
        await reload()
    }

    /// "Not for me": off Today, verdict kept.
    func skip(_ job: Job) async {
        guard let db else { return }
        try? await JobRepository(db).setState(.skipped, for: job.id)
        await reload()
    }

    // MARK: - Builds

    /// Your master resume as screening evidence, to quote what showed a requirement.
    var screeningProfile: ScreeningProfile? { resume.map { ScreeningProfile($0.resume) } }

    /// Stretch when you've turned it on, otherwise strict.
    var defaultBuildMode: BuildMode { stretch.enabled ? .stretch : .strict }

    /// Starts a build for `job`, once your master resume is ready (S14), and shows it.
    func startBuild(for job: Job, mode: BuildMode? = nil, coverLetter: Bool = false) async -> String? {
        let mode = mode ?? defaultBuildMode
        guard let db else { return "The database isn't open." }
        guard let resume, resume.readiness.isReady else {
            return
                "Finish your master resume first: \(resume?.readiness.missing.map(\.message).joined(separator: " ") ?? "")"
        }
        let queue = queue(db)
        await queue.setRouter(ai?.router())
        do {
            let id = try await queue.enqueue(job: job.id, mode: mode, coverLetter: coverLetter)
            selectedBuild = id
            section = .builds
            await reload()
            return nil
        } catch {
            log.error("Starting a build failed: \(String(describing: error), privacy: .public)")
            return "The build couldn't start."
        }
    }

    func build(_ id: UUID?) -> BuildRecord? {
        id.flatMap { id in builds.first { $0.id == id } }
    }

    /// A PDF a finished build saved: its resume, or its cover letter (`cover_letter`). The latest,
    /// if a restarted build saved one twice.
    func pdf(of build: BuildRecord, kind: String = "resume") async -> URL? {
        guard let db,
            let path = try? await BuildRepository(db).artifacts(for: build.id).last(where: { $0.kind == kind })?
                .localPath
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// You applied with this build: the job leaves Today.
    func markApplied(_ job: Job) async {
        guard let db else { return }
        try? await JobRepository(db).setState(.applied, for: job.id)
        await reload()
    }

    /// The build queue, made on first use: it renders with the typst in the app bundle, keeps PDFs
    /// beside the database, and restarts any build a quit left unfinished.
    private func queue(_ db: Database) -> BuildQueue {
        if let buildQueue { return buildQueue }
        let renderer = Bundle.main.url(forAuxiliaryExecutable: "typst").map {
            ResumeRenderer(runner: TypstRunner(executable: $0))
        }
        let folder =
            ((try? AccountStore.applicationSupport().databaseURL(for: .local))?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory).appending(path: "Builds")
        let queue = BuildQueue(db: db, router: ai?.router(), folder: folder) { printable in
            guard let renderer else { throw RenderError.launch("typst isn't in the app bundle") }
            return try await renderer.render(printable)
        }
        buildQueue = queue
        buildEvents = Task { [weak self] in
            for await event in queue.events { await self?.handle(event) }
        }
        Task { _ = try? await queue.resumeInterrupted() }
        return queue
    }

    private func handle(_ event: BuildQueue.Event) async {
        switch event {
        case .step(let id, let step):
            buildSteps[id] = step
        case .finished(let id, _, _):
            buildSteps[id] = nil
            await reload()
        case .failed:
            // The last step stays, so the screen can show where it stopped.
            await reload()
        case .queued:
            await reload()
        }
    }

    // MARK: - Screening settings

    func save(_ preferences: SearchPreferences) async {
        guard let db else { return }
        searchPreferences = preferences
        try? await SettingsRepository(db).save(preferences, for: SearchPreferences.storageKey)
    }

    func save(_ stretch: StretchSettings) async {
        guard let db else { return }
        self.stretch = stretch
        try? await SettingsRepository(db).save(stretch, for: StretchSettings.storageKey)
    }

    func save(_ profile: WorkProfile) async {
        guard let db else { return }
        workProfile = profile
        try? await PrivateSettingsRepository(db).save(profile, for: WorkProfile.storageKey)
    }

    /// Screens new jobs again with your current settings. Stored analyses are reused, so only jobs
    /// never analysed cost an AI call. Your own verdicts stay.
    func screenAgain() {
        guard let db, !isFetching else { return }
        isFetching = true
        screening = nil
        let run = ScreeningRun(db: db, router: ai?.router())
        fetchTask = Task { [weak self] in
            _ = try? await JobRepository(db).clearScreening()
            for await update in run.start() {
                self?.screening = update
                if update.done % 5 == 0 { await self?.reload() }
            }
            self?.isFetching = false
            await self?.reload()
        }
    }

    /// How far the run is: fetching boards, then screening jobs.
    var runFraction: Double {
        if let screening, screening.total > 0 { return Double(screening.done) / Double(screening.total) }
        guard let progress, progress.sourcesTotal > 0 else { return 0 }
        return Double(progress.sourcesDone) / Double(progress.sourcesTotal)
    }

    /// "Last run 7:58 AM · 312 fetched · 61% filtered before AI", or what's happening now.
    var runSummary: String {
        if isFetching { return fetchSummary }
        guard let run = lastScreening, let finished = run.finishedAt, let stats = ScreeningRun.Stats.decode(run.stats)
        else { return fetchSummary }
        var parts = ["Last run \(finished.formatted(date: .omitted, time: .shortened))"]
        if let fetch = lastFetch, let fetched = FetchRun.Stats.decode(fetch.stats), fetch.startedAt <= run.startedAt {
            parts.append("\(fetched.found) fetched")
        }
        if stats.screened > 0 { parts.append("\(Int((stats.dropRate * 100).rounded()))% filtered before AI") }
        if waitingForAI > 0 { parts.append("\(waitingForAI) waiting for AI") }
        return parts.joined(separator: " · ")
    }

    /// "Last fetch 7:58 AM · 312 found · 12 new", or what's happening now.
    var fetchSummary: String {
        if isFetching, let screening, screening.phase == .running {
            return "Screening \(screening.done) of \(screening.total) · \(screening.yes) yes · \(screening.maybe) maybe"
        }
        if isFetching, let progress {
            return "Fetching \(progress.sourcesDone) of \(progress.sourcesTotal) boards · \(progress.added) new so far"
        }
        guard let run = lastFetch, let finished = run.finishedAt, let stats = FetchRun.Stats.decode(run.stats) else {
            return sources.isEmpty ? "Add a company in Sources to start" : "Not fetched yet"
        }
        var parts = [
            "Last fetch \(finished.formatted(date: .omitted, time: .shortened))", "\(stats.found) found",
            "\(stats.added) new",
        ]
        if stats.failed > 0 { parts.append("\(stats.failed) board\(stats.failed == 1 ? "" : "s") failed") }
        if run.error == "cancelled" { parts.append("stopped") }
        if let screen = lastScreening, screen.startedAt >= run.startedAt,
            let screened = ScreeningRun.Stats.decode(screen.stats)
        {
            parts.append("\(screened.yes) yes · \(screened.maybe) maybe")
            if screened.waiting > 0 { parts.append("\(screened.waiting) waiting for AI") }
        }
        return parts.joined(separator: " · ")
    }
}
