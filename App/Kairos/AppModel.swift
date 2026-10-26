import Foundation
import JobSources
import LLM
import MasterResume
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
    var section: AppSection = .inbox
    /// The Settings tab to show, so another screen can open the right one ("Change titles").
    var settingsTab: SettingsView.Tab = .ai
    private(set) var sources: [Source] = []
    /// Jobs you applied to (T45), the most recently moved first.
    private(set) var applications: [Application] = []
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
    private(set) var pages = PageSettings()
    /// Every job's builds, newest first, and where each running one is.
    private(set) var builds: [BuildRecord] = []
    /// Each job's newest build, by job id, however many builds there are: which jobs have a resume.
    private(set) var latestBuilds: [String: BuildRecord] = [:]
    private(set) var buildSteps: [UUID: BuildStep] = [:]
    /// Each running or just-finished build's model calls, live (`BuildQueue.Event.call`).
    private(set) var buildActivity: [UUID: BuildActivity] = [:]
    /// A build failed, or a batch of them is over with something to say: the dialog shows it. A
    /// fallback alone never interrupts; it shows on the build (decided 2026-10-23).
    var buildNotice: BuildNotice?
    /// The builds of the last "Build resumes" run, and how each ended (true: made).
    @ObservationIgnored private var batch: Set<UUID> = []
    @ObservationIgnored private var batchEnded: [UUID: Bool] = [:]
    var selectedBuild: UUID?
    private(set) var isFetching = false
    /// The master resume editor's state; there once the database is open.
    private(set) var resume: ResumeModel?
    /// AI providers, keys (in Kairos's private key file until release) and routing; there once the
    /// database is open.
    private(set) var ai: AISettingsModel?

    init() {}

    #if DEBUG
        /// For snapshots: an open model with sample jobs and their screening.
        init(
            preview jobs: [Job], screenings: [String: ScreeningRecord], sources: [Source],
            preferences: SearchPreferences = SearchPreferences(), profile: WorkProfile = WorkProfile(),
            stretch: StretchSettings = StretchSettings(), resume: ResumeModel? = nil, applications: [Application] = [],
            ai: AISettingsModel? = nil, screening: ScreeningRun.Progress? = nil
        ) {
            self.resume = resume
            self.ai = ai
            self.screening = screening
            isFetching = screening?.phase == .running
            self.jobs = jobs
            self.screenings = screenings
            self.sources = sources
            self.applications = applications
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
    /// API keys: the AI providers', Adzuna's and GitHub's, in the one store until release (P6).
    @ObservationIgnored private let secrets = AppSecrets.store()
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
            let ai = AISettingsModel(db: db, secrets: secrets)
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
            applications = try await ApplicationRepository(db).applications()
            lastFetch = try await RunRepository(db).runs(kind: "fetch", limit: 1).first
            await refreshAdzunaUsage()
            lastScreening = try await RunRepository(db).runs(kind: "screen", limit: 1).first
            screenings = try await ScreeningRepository(db).latestByJob()
            builds = try await BuildRepository(db).recent()
            latestBuilds = try await BuildRepository(db).latestByJob()
            searchPreferences =
                try await SettingsRepository(db).value(SearchPreferences.storageKey, as: SearchPreferences.self)
                ?? SearchPreferences()
            workProfile =
                try await PrivateSettingsRepository(db).value(WorkProfile.storageKey, as: WorkProfile.self)
                ?? WorkProfile()
            stretch =
                try await SettingsRepository(db).value(StretchSettings.storageKey, as: StretchSettings.self)
                ?? StretchSettings()
            pages =
                try await SettingsRepository(db).value(PageSettings.storageKey, as: PageSettings.self) ?? PageSettings()
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
            let config = BoardConfig(
                slug: slug, company: company.isEmpty ? nil : company, region: ATSDetector.leverRegion(careersURL))
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
        // Resuming a gone board tries it again.
        if enabled, changed.health == .gone {
            changed.health = .ok
            changed.emptyRuns = 0
        }
        _ = try? await SourceRepository(db).save(changed)
        await reload()
    }

    func remove(_ source: Source) async {
        guard let db else { return }
        _ = try? await SourceRepository(db).tombstone(source.id)
        if source.kind == .adzuna {
            try? secrets.delete(Self.adzunaAppID)
            try? secrets.delete(Self.adzunaAppKey)
        }
        await reload()
    }

    // MARK: - Adzuna

    static let adzunaAppID = SecretKey("adzuna.app_id")
    static let adzunaAppKey = SecretKey("adzuna.app_key")

    /// Your Adzuna app ID and key, when both are saved.
    var adzunaCredentials: AdzunaSource.Credentials? {
        guard let id = (try? secrets.read(Self.adzunaAppID)) ?? nil,
            let key = (try? secrets.read(Self.adzunaAppKey)) ?? nil
        else { return nil }
        return AdzunaSource.Credentials(appID: id, appKey: key)
    }

    /// The Adzuna search, if you've added it.
    var adzunaSource: Source? { sources.first { $0.kind == .adzuna } }

    /// Adzuna requests used today (UTC) and this month, against its plan (job collection v2, J4).
    private(set) var adzunaUsed = (today: 0, month: 0)

    private func refreshAdzunaUsage() async {
        guard let db, let adzuna = adzunaSource else { return }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let log = FetchLog(db)
        let now = Date()
        func used(_ component: Calendar.Component) async -> Int {
            guard let start = utc.dateInterval(of: component, for: now)?.start else { return 0 }
            return (try? await log.requests(of: adzuna.id, since: start)) ?? 0
        }
        adzunaUsed = (await used(.day), await used(.month))
    }

    static let himalayasKey = SecretKey("himalayas.key")
    static let serpAPIKey = SecretKey("serpapi.key")

    func source(of kind: SourceKind) -> Source? { sources.first { $0.kind == kind } }

    /// Adds Himalayas or Google Jobs (job collection v2, J7) with its key: optional for Himalayas,
    /// needed for Google Jobs through SerpApi. Returns why it couldn't, or nil once saved.
    func saveSearch(_ kind: SourceKind, key: String) async -> String? {
        guard let db else { return "The database isn't open." }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .googleJobs, key.isEmpty { return "Paste your SerpApi key." }
        do {
            let name = kind == .googleJobs ? Self.serpAPIKey : Self.himalayasKey
            if key.isEmpty {
                try secrets.delete(name)
            } else {
                try secrets.write(key, for: name, hint: LLMSettings.masked(key))
            }
            if source(of: kind) == nil { _ = try await SourceRepository(db).add(kind: kind) }
        } catch {
            return "Couldn't save it on this Mac."
        }
        await reload()
        return nil
    }

    /// Saves your Adzuna app ID and key, and adds the Adzuna search if it isn't there yet. Returns
    /// why it couldn't, or nil once saved.
    func saveAdzuna(appID: String, appKey: String) async -> String? {
        guard let db else { return "The database isn't open." }
        let id = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !key.isEmpty else { return "Paste both the app ID and the app key." }
        do {
            try secrets.write(id, for: Self.adzunaAppID)
            try secrets.write(key, for: Self.adzunaAppKey, hint: LLMSettings.masked(key))
            if adzunaSource == nil { _ = try await SourceRepository(db).add(kind: .adzuna) }
        } catch {
            return "Couldn't save them on this Mac."
        }
        await reload()
        return nil
    }

    /// Whether `job` came from a search's snippet (Adzuna), so its description is partial.
    /// Kairos holds only a search's snippet of it: Adzuna's, until the full posting turns up on
    /// the company's board.
    func isSnippet(_ job: Job) -> Bool { job.descriptionKind == .snippet || source(job.sourceID)?.kind == .adzuna }

    func source(_ id: UUID) -> Source? {
        sources.first { $0.id == id }
    }

    /// Each source's last failure in this session's fetch, for the ones that failed.
    var failures: [UUID: String] {
        Dictionary((progress?.failures ?? []).map { ($0.sourceID, $0.message) }) { first, _ in first }
    }

    /// Open jobs by source, counted once for a whole table: rows that each read `jobs` made
    /// SwiftUI abort when you left Find jobs for Review (2026-10-26).
    var openRoles: [UUID: Int] { jobs.reduce(into: [:]) { $0[$1.sourceID, default: 0] += 1 } }

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
        // A search source (Adzuna) asks by your titles, countries and posting age.
        let preferences = searchPreferences
        // Searches ask for your roles (J3); a board's jobs at other roles aren't kept.
        let roles = preferences.roleMatcher
        let search = SearchContext(
            query: SourceQuery(
                titles: roles.searches, countries: preferences.countries, maxAgeDays: preferences.maxAgeDays,
                roles: roles.isOpen ? nil : roles),
            adzuna: adzunaCredentials, himalayasKey: (try? secrets.read(Self.himalayasKey)) ?? nil,
            serpAPIKey: (try? secrets.read(Self.serpAPIKey)) ?? nil)
        let run = PipelineRun(
            fetch: FetchRun(
                db: db, postedWithinDays: preferences.maxAgeDays, roles: roles,
                watch: preferences.watchCatalog
                    ? CatalogWatch(catalog: .bundled, countries: preferences.countries) : nil,
                finder: SnippetFinder(db: db, probe: BoardProbe(http: http), catalog: .bundled),
                makeSource: { try SourceFactory.make($0, http: http, search: search) }),
            screening: ScreeningRun(db: db, router: ai?.router()))
        fetchTask = Task { [weak self] in
            for await event in run.start() {
                switch event {
                case .fetching(let update):
                    self?.progress = update
                    if update.added + update.changed + update.closed > 0 { await self?.reload() }
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

    // MARK: - Review

    /// Review's views (polish P3, split by stage at your request): the jobs that reached the AI by
    /// verdict, then everything the prefilter dropped, then all of it. A verdict you set counts as
    /// the AI's stage, whichever stage set it before.
    enum ReviewFilter: String, CaseIterable, Identifiable {
        case yes, maybe, no, all
        var id: Self { self }

        var title: String {
            switch self {
            case .yes: "Yes"
            case .maybe: "Maybe"
            case .no: "No"
            case .all: "All"
            }
        }
    }

    /// Review holds the jobs that passed your filters (2026-10-22). Yes, Maybe and No are a to-do
    /// list: they leave out jobs you've applied to or marked "Not for me", and jobs no longer
    /// posted anywhere (job collection v2). All adds those (shown dimmed) and jobs waiting for the
    /// AI. Jobs retention has archived leave Review.
    func reviewJobs(_ filter: ReviewFilter) -> [Job] {
        let byRank: (Job, Job) -> Bool = { ($0.rank ?? -1, $1.title) > ($1.rank ?? -1, $0.title) }
        let passed = jobs.filter { $0.verdictSource != .prefilter && $0.state != .archived }
        let open = passed.filter { ($0.state == .new || $0.state == .shortlisted) && $0.isOpen }
        switch filter {
        case .yes: return open.filter { $0.verdict == .yes }.sorted(by: byRank)
        case .maybe: return open.filter { $0.verdict == .maybe }.sorted(by: byRank)
        case .no: return open.filter { $0.verdict == .no }.sorted(by: byRank)
        case .all: return passed.sorted(by: byRank)
        }
    }

    func reviewCount(_ filter: ReviewFilter) -> Int { reviewJobs(filter).count }

    /// Whether you've acted on `job` (applied, or "Not for me"): All shows it dimmed.
    func isActedOn(_ job: Job) -> Bool { job.state == .applied || job.state == .skipped }

    /// `filter`'s jobs grouped by country in your order.
    func reviewSections(_ filter: ReviewFilter) -> [JobSection] {
        let shown = reviewJobs(filter)
        let countries: [Country?] =
            searchPreferences.countries + Country.allCases.filter { !searchPreferences.countries.contains($0) } + [nil]
        return countries.compactMap { country in
            let matching = shown.filter { $0.country == country }
            guard !matching.isEmpty else { return nil }
            return JobSection(
                id: country?.rawValue ?? "none", title: country?.displayName ?? "Location not stated", jobs: matching)
        }
    }

    // MARK: - Filtered out

    /// The filter rule that dropped `job`, when it's one of the filters' jobs.
    func filterRule(of job: Job) -> PrefilterRule? {
        guard job.verdictSource == .prefilter else { return nil }
        return screening(for: job)?.ruleID.flatMap(PrefilterRule.init(rawValue:))
    }

    /// Filtered out (2026-10-22): the jobs your filters dropped before any AI call, all of them
    /// (`rule` nil) or one rule's, newest first.
    func filteredJobs(_ rule: PrefilterRule?) -> [Job] {
        jobs.filter { $0.verdictSource == .prefilter && (rule == nil || filterRule(of: $0) == rule) }
            .sorted { ($0.firstSeenAt, $1.title) > ($1.firstSeenAt, $0.title) }
    }

    var filteredCount: Int { jobs.count { $0.verdictSource == .prefilter } }

    /// Each rule with how many jobs it dropped, most first.
    var filteredReasons: [(rule: PrefilterRule, count: Int)] {
        let rules = jobs.compactMap(filterRule(of:))
        return Dictionary(grouping: rules) { $0 }.map { ($0.key, $0.value.count) }
            .sorted { ($0.1, $1.0.rawValue) > ($1.1, $0.0.rawValue) }
    }

    /// Brings a filtered job back: the filters never drop it again, and it's judged like any other
    /// (its stored analysis, or the AI's). Returns why it couldn't be judged yet, or nil.
    func bringBack(_ job: Job) async -> String? {
        guard let db else { return "The database isn't open." }
        let outcome = await ScreeningRun(db: db, router: ai?.router()).bringBack(job.id)
        await reload()
        switch outcome {
        case .verdict: return nil
        case .failed:
            return "It's back in Review. The AI couldn't analyse it just now; Screen waiting jobs there tries again."
        case .stopped(let reason): return "It's back in Review, waiting: \(reason)"
        }
    }

    /// "Re-check filters": your current filters on every job, with no AI calls. A job whose stored
    /// analysis still applies gets its verdict from it; one newly let through waits for the AI; the
    /// rest keep theirs.
    func recheckFilters() {
        runScreening(.everything, router: nil, reloadEvery: 25)
    }

    /// Jobs that would need the AI on a Re-screen all: those in Review, still posted, with no
    /// analysis from the current prompt. Each is one call.
    func analysesNeeded() async -> Int {
        guard let db else { return 0 }
        let rows = try? await db.query(
            """
            SELECT COUNT(*) AS n FROM job j WHERE j.deleted = 0 AND j.state IN ('new', 'shortlisted')
              AND j.closed_at IS NULL AND (j.verdict_source IS NULL OR j.verdict_source = 'analysis')
              AND NOT EXISTS (SELECT 1 FROM job_analysis a WHERE a.job_id = j.id AND a.deleted = 0
                AND a.prompt_version = ?)
            """, [.integer(Int64(AnalyzeJobTask.promptVersion))])
        return rows?.first?.int("n") ?? 0
    }

    // MARK: - Delete all jobs

    /// What "Delete all jobs" would delete and keep, for its confirmation.
    func clearingPreview() async -> JobRepository.Clearing? {
        guard let db else { return nil }
        return try? await JobRepository(db).clearingPreview()
    }

    /// Deletes every job you haven't saved, built for or applied to; the next fetch brings back the
    /// ones still posted (your decision, 2026-10-22).
    func deleteAllJobs() async {
        guard let db, !isFetching else { return }
        _ = try? await JobRepository(db).clearAll()
        await reload()
    }

    /// How many jobs each prefilter rule dropped, most first: what Fetch shows under the run.
    var droppedByRule: [(rule: PrefilterRule, count: Int)] {
        let rules = screenings.values.filter { $0.stage == .prefilter }.compactMap {
            $0.ruleID.flatMap(PrefilterRule.init(rawValue:))
        }
        return Dictionary(grouping: rules) { $0 }.map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    /// The analysis behind a job's verdict, whichever prompt made it.
    /// Every place the job is posted, the one it shows first, and what happened to it.
    func postings(of job: Job) async -> (listings: [Listing], history: [JobEvent]) {
        guard let db else { return ([], []) }
        let listings = (try? await ListingRepository(db).listings(of: job.id)) ?? []
        return (listings, (try? await ListingRepository(db).events(of: job.id)) ?? [])
    }

    func storedAnalysis(for job: Job) async -> StoredAnalysis? {
        guard let db, let stored = try? await AnalysisRepository(db).latest(for: job.id) else { return nil }
        // As the verdict reads it: a language you list counts as shown.
        return StoredAnalysis(
            analysis: stored.analysis.recognizingLanguages(languages), model: stored.model,
            promptVersion: stored.promptVersion, analyzedAt: stored.analyzedAt)
    }

    /// Your master resume's languages.
    private var languages: [EntryFields.Language] {
        resume?.resume.entries(.language).compactMap { entry in
            guard case .language(let language) = entry.fields else { return nil }
            return language
        } ?? []
    }

    /// Screens one job again from scratch (P2). Nil when it worked; otherwise why not, in words.
    func reevaluate(_ job: Job) async -> String? {
        guard let db else { return "The database isn't open." }
        let outcome = await ScreeningRun(db: db, router: ai?.router()).reevaluate(job.id)
        await reload()
        switch outcome {
        case .verdict: return nil
        case .failed: return "The AI couldn't analyse this posting just now. Try again in a moment."
        case .stopped(let reason): return reason
        }
    }

    /// S14: why Build is blocked for `job`, or nil when it isn't.
    func buildBlocked(_ job: Job, analysed: Bool) -> String? {
        if let readiness = resume?.readiness, !readiness.isReady {
            return "Finish your master resume first: \(readiness.missing.map(\.message).joined(separator: " "))"
        }
        return analysed ? nil : "This job needs an analysis first: Re-evaluate it, with an AI key set."
    }

    /// New jobs, still posted, that passed the prefilter and wait for an analysis: what Screen
    /// waiting jobs screens. A job no longer posted never reaches the AI, so it isn't counted.
    var waitingForAI: Int { jobs.count { $0.verdict == nil && $0.state == .new && $0.isOpen } }

    /// Whether a model is set up to analyse jobs: analyzeJob's route names a provider with a key, or
    /// one that needs none (Ollama on this Mac).
    var canAnalyse: Bool {
        guard let ai, let chain = ai.settings.routes[TaskID.analyzeJob.rawValue] else { return false }
        return chain.contains { ref in
            ai.settings.provider(ref.provider).map { !$0.preset.needsKey || !$0.keyNames.isEmpty } ?? false
        }
    }

    /// The screening running now, as opposed to a fetch's boards.
    var isScreening: Bool { isFetching && screening?.phase == .running }

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

    /// Starts a build for `job`, once your master resume is ready (S14). `show` opens it in Resumes;
    /// a job's own resume page passes false and shows it there instead.
    func startBuild(for job: Job, mode: BuildMode? = nil, coverLetter: Bool = false, show: Bool = true) async
        -> String?
    {
        guard let id = await enqueue([job.id], mode: mode, coverLetter: coverLetter).first else {
            return buildProblem ?? "The build couldn't start."
        }
        if show {
            selectedBuild = id
            section = .resumes
        }
        return nil
    }

    /// "Build resumes for every Yes" (or Maybe): which of the list's jobs get one. Jobs with a
    /// resume, or one on the way, are skipped, and so are jobs the current prompt hasn't analysed.
    func bulkBuild(_ filter: ReviewFilter) async -> BulkBuild {
        var analysed: Set<JobID> = []
        if let db {
            analysed =
                (try? await AnalysisRepository(db).analysedJobs(promptVersion: AnalyzeJobTask.promptVersion)) ?? []
        }
        return BulkBuild(
            candidates: reviewJobs(filter).map(\.id), latest: latestBuilds.mapValues(\.status), analysed: analysed)
    }

    /// Queues a build for each job, two running at a time, and stays where you are. Nil once
    /// queued; otherwise why not.
    func startBuilds(_ jobs: [JobID], mode: BuildMode? = nil, coverLetter: Bool = false) async -> String? {
        let queued = await enqueue(jobs, mode: mode, coverLetter: coverLetter)
        batch.formUnion(queued)
        return queued.count == jobs.count ? nil : buildProblem ?? "Some builds couldn't start."
    }

    /// Why the last `enqueue` stopped short, in words.
    @ObservationIgnored private var buildProblem: String?

    /// Queues builds once your master resume is ready (S14). Returns the ids queued.
    private func enqueue(_ jobs: [JobID], mode: BuildMode?, coverLetter: Bool) async -> [UUID] {
        buildProblem = nil
        guard let db else {
            buildProblem = "The database isn't open."
            return []
        }
        guard let resume, resume.readiness.isReady else {
            buildProblem =
                "Finish your master resume first: \(resume?.readiness.missing.map(\.message).joined(separator: " ") ?? "")"
            return []
        }
        let queue = queue(db)
        await queue.setRouter(ai?.router())
        var ids: [UUID] = []
        for job in jobs {
            do {
                ids.append(try await queue.enqueue(job: job, mode: mode ?? defaultBuildMode, coverLetter: coverLetter))
            } catch {
                log.error("Starting a build failed: \(String(describing: error), privacy: .public)")
                buildProblem = "The build couldn't start."
                break
            }
        }
        await reload()
        return ids
    }

    /// The job's newest build, if it has one.
    func latestBuild(for job: Job) -> BuildRecord? { latestBuilds[job.id.rawValue] }

    /// A build's model calls: live while it runs, else replayed from the call log (kept 30 days).
    func activity(for build: UUID) async -> BuildActivity? {
        if let live = buildActivity[build] { return live }
        guard let db, let calls = try? await CallLog(db).calls(build: build.lowercased), !calls.isEmpty else {
            return nil
        }
        return BuildActivity(calls: calls)
    }

    /// The same job, mode and letter again.
    func rebuild(_ id: UUID) async -> String? {
        guard let db, let record = try? await BuildRepository(db).build(id),
            let job = jobs.first(where: { $0.id.rawValue == record.jobID })
        else { return "That build is gone." }
        return await startBuild(for: job, mode: record.mode, coverLetter: record.coverLetter != nil)
    }

    /// One of the last batch's builds is over; once all are, a summary when there's something to say.
    private func ended(_ id: UUID, made: Bool) {
        guard batch.contains(id) else { return }
        batchEnded[id] = made
        guard batchEnded.count == batch.count else { return }
        let failed = batchEnded.filter { !$0.value }.map(\.key)
        let helped = batch.filter { buildActivity[$0]?.hasFallbacks == true || buildActivity[$0]?.hasGivenUp == true }
        defer {
            batch = []
            batchEnded = [:]
        }
        guard !failed.isEmpty || !helped.isEmpty else { return }
        var lines: [String] = []
        for id in failed {
            let title = build(id).flatMap { record in jobs.first { $0.id.rawValue == record.jobID }?.title } ?? "A job"
            lines.append("\(title): \(build(id)?.error ?? "didn't finish").")
        }
        if !helped.isEmpty {
            lines.append(
                "\(helped.count) used a fallback model or left a step out; each says what on its resume page.")
        }
        buildNotice = BuildNotice(
            title: "\(batch.count - failed.count) of \(batch.count) resumes made",
            message: lines.joined(separator: "\n"),
            retry: nil)
    }

    /// A failure's message with what the build tried, from its calls.
    static func explain(_ message: String, _ activity: BuildActivity?) -> String {
        let notes = activity?.notes.map { "• \($0.text)" } ?? []
        return notes.isEmpty ? message : message + "\n\nWhat happened:\n" + notes.joined(separator: "\n")
    }

    /// Every build of one job, newest first: its resume page's history.
    func builds(for job: JobID) async -> [BuildRecord] {
        guard let db else { return [] }
        return (try? await BuildRepository(db).builds(for: job)) ?? []
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
    /// Records that you applied: when, where (the job's board) and with which build, your latest
    /// finished one unless `build` says.
    func markApplied(_ job: Job, build: UUID? = nil) async {
        guard let db else { return }
        let sent = build ?? builds.first { $0.jobID == job.id.rawValue && $0.status == .done }?.id
        _ = try? await ApplicationRepository(db).apply(
            job: job.id, build: sent, channel: source(job.sourceID)?.kind.displayName, at: Date())
        await reload()
    }

    // MARK: - Applications

    func application(_ id: UUID) -> Application? { applications.first { $0.id == id } }

    func application(for job: Job) -> Application? { applications.first { $0.jobID == job.id } }

    /// The application's timeline, oldest first.
    func events(for application: Application) async -> [ApplicationEvent] {
        guard let db else { return [] }
        return (try? await ApplicationRepository(db).events(for: application.id)) ?? []
    }

    func setStatus(_ status: ApplicationStatus, for application: Application, note: String? = nil) async {
        guard let db, status != application.status else { return }
        try? await ApplicationRepository(db).setStatus(status, for: application.id, at: Date(), note: note)
        await reload()
    }

    /// Moves several at once, each with its own timeline line, skipping any already there: Applied's
    /// selection, or the silent ones to No reply (ADR-016).
    func setStatus(_ status: ApplicationStatus, for applications: [Application]) async {
        guard let db else { return }
        let moving = applications.filter { $0.status != status }.map(\.id)
        try? await ApplicationRepository(db).setStatus(status, for: moving, at: Date())
        await reload()
    }

    func addNote(_ note: String, to application: Application) async {
        guard let db else { return }
        try? await ApplicationRepository(db).addNote(note, to: application.id, at: Date())
        await reload()
    }

    /// Sets the follow-up and its notification, or clears both with nil.
    func setFollowUp(_ date: Date?, _ text: String?, for application: Application) async {
        guard let db else { return }
        try? await ApplicationRepository(db).setFollowUp(date, text, for: application.id)
        await reload()
        if let updated = self.application(application.id) {
            await FollowUpReminders.schedule(updated, job: job(updated.jobID))
        }
    }

    func setNotes(_ notes: String, for application: Application) async {
        guard let db, notes != application.notes else { return }
        try? await ApplicationRepository(db).setNotes(notes, for: application.id)
        await reload()
    }

    /// Forgets the application and its reminder; the job goes back to new.
    func delete(_ application: Application) async {
        guard let db else { return }
        try? await ApplicationRepository(db).delete(application.id)
        FollowUpReminders.cancel(application.id)
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
        let queue = BuildQueue(db: db, router: ai?.router(), folder: folder, template: .standard) { printable in
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
        case .call(let id, let event):
            buildActivity[id, default: BuildActivity()].apply(event, at: Date())
        case .finished(let id, _, _):
            buildSteps[id] = nil
            await reload()
            ended(id, made: true)
        case .failed(let id, let message):
            // The last step stays, so the screen can show where it stopped.
            await reload()
            if batch.contains(id) {
                ended(id, made: false)
            } else {
                buildNotice = BuildNotice(
                    title: "The resume couldn't be made", message: Self.explain(message, buildActivity[id]), retry: id)
            }
        case .queued:
            await reload()
        }
    }

    // MARK: - Improve

    /// Improve's report (P11): Review's No and Maybe jobs against your master resume, and the
    /// titles your list dropped. Nil until the database and your resume are open.
    func improveReport() async -> ImproveReport? {
        guard let db, let resume else { return nil }
        let analyses =
            (try? await AnalysisRepository(db).analyses(promptVersion: AnalyzeJobTask.promptVersion)) ?? [:]
        return ImproveReport(
            jobs: reviewJobs(.no) + reviewJobs(.maybe), screenings: screenings, analyses: analyses,
            filteredByTitle: jobs.filter { filterRule(of: $0) == .titleInclude && $0.state != .archived },
            resume: resume.resume, preferences: searchPreferences, profile: workProfile)
    }

    /// "How could I show this?": the AI points at your roles, projects and bullets that might show
    /// a fix, each as a question. One call, or none when the same question was asked before.
    func suggestions(for fix: ImproveReport.Fix) async -> Result<SuggestEvidenceTask.Output, SuggestionProblem> {
        guard let resume, let router = ai?.router() else { return .failure(.text(BuildError.noAI.message)) }
        let input = SuggestEvidenceTask.Input(
            fix: fix.title, asks: fix.asks.map(\.text), profile: ScreeningProfile(resume.resume))
        do {
            let result = try await router.run(SuggestEvidenceTask(), input: input)
            await ai?.refreshUsage()
            return .success(result.output)
        } catch {
            log.error("Suggestions failed: \(error.code, privacy: .public)")
            return .failure(.text(Self.words(for: error)))
        }
    }

    struct SuggestionProblem: Error, Equatable {
        let message: String
        static func text(_ message: String) -> SuggestionProblem { SuggestionProblem(message: message) }
    }

    /// An AI failure in words, with what to do.
    private static func words(for error: LLMError) -> String {
        switch error {
        case .noProvider, .noKey: BuildError.noAI.message
        case .keyRejected: "Your key was rejected. Check it in Settings, AI providers."
        case .budgetReached: "\(Budget.reachedMessage). It resets at midnight."
        case .rateLimited, .modelNotOnPlan: "The AI is busy or out of quota for now. Try again later."
        case .invalidJSON, .invalidOutput: "The AI's answer didn't hold up to Kairos's checks. Try again."
        default: "The AI couldn't answer just now. Try again in a moment."
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

    func save(_ pages: PageSettings) async {
        guard let db else { return }
        self.pages = pages
        try? await SettingsRepository(db).save(pages, for: PageSettings.storageKey)
    }

    func save(_ profile: WorkProfile) async {
        guard let db else { return }
        workProfile = profile
        try? await PrivateSettingsRepository(db).save(profile, for: WorkProfile.storageKey)
    }

    /// Screens the jobs waiting for the AI, picking up where a stopped run left off (2026-10-26).
    /// Jobs with a verdict are left alone, so each waiting job costs at most one AI call.
    func screenWaiting() {
        runScreening(.waiting, router: ai?.router())
    }

    /// Re-screen all: every new job judged again with your current settings, in place, so each keeps
    /// its verdict until it gets a new one. Stored analyses are reused, so only jobs never analysed
    /// with the current prompt cost an AI call. Your own verdicts stay.
    func screenAgain() {
        runScreening(.everything, router: ai?.router())
    }

    /// One screening run, its progress in `screening`, the lists refreshed now and then. Stop it
    /// with `stopFetch()`.
    private func runScreening(_ scope: ScreeningRun.Scope, router: LLMRouter?, reloadEvery: Int = 5) {
        guard let db, !isFetching else { return }
        isFetching = true
        screening = nil
        let run = ScreeningRun(db: db, router: router, scope: scope)
        fetchTask = Task { [weak self] in
            for await update in run.start() {
                self?.screening = update
                if update.done % reloadEvery == 0 { await self?.reload() }
            }
            if Task.isCancelled { self?.screening?.phase = .cancelled }
            self?.isFetching = false
            await self?.reload()
        }
    }

    /// The sidebar's status line (UI v2): what runs now, or when Kairos last checked.
    var runStatus: RunStatus {
        var input = RunStatus.Input()
        input.fetching = isFetching
        input.fetch = progress
        input.screening = screening
        input.building = builds.count { $0.status == .running }
        input.queued = builds.count { $0.status == .queued }
        input.lastChecked = lastFetch?.finishedAt
        input.newLastTime = lastFetch.flatMap { FetchRun.Stats.decode($0.stats)?.added } ?? 0
        input.waiting = waitingForAI
        input.hasSources = !sources.isEmpty
        return RunStatus.current(input)
    }

    /// Builds running or queued: the Resumes badge.
    var buildsUnderWay: Int { builds.count { $0.status == .running || $0.status == .queued } }

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
        if let tooOld = stats.tooOld { parts.append("\(tooOld) older ones skipped") }
        // Job collection v2: what changed on postings already known.
        if let upgraded = stats.upgraded { parts.append("\(upgraded) snippet\(upgraded == 1 ? "" : "s") filled in") }
        if let changed = stats.changed { parts.append("\(changed) edited") }
        if let closed = stats.closed { parts.append("\(closed) no longer posted") }
        if let other = stats.otherRoles { parts.append("\(other) at other roles left out") }
        if let added = stats.catalogAdded { parts.append("\(added) catalog compan\(added == 1 ? "y" : "ies") added") }
        if let quiet = stats.quiet { parts.append("\(quiet) quiet boards rested") }
        if let found = stats.boardsFound {
            parts.append("\(found) compan\(found == 1 ? "y's" : "ies'") boards found behind snippets")
        }
        if stats.searchesSkipped != nil { parts.append("Adzuna's share for today is used up") }
        if let unchanged = stats.unchanged {
            parts.append("\(unchanged) board\(unchanged == 1 ? "" : "s") unchanged")
        }
        // Retention (T46): old jobs you never engaged with leave after a fetch.
        let retired = (stats.archived ?? 0) + (stats.removed ?? 0)
        if retired > 0 { parts.append("\(retired) old job\(retired == 1 ? "" : "s") tidied away") }
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

/// What a build needs you to know now: one that failed, or how a batch of builds went.
struct BuildNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    /// A single failed build, to try again.
    let retry: UUID?
}
