import Foundation
import JobSources
import OSLog
import Observation
import Pipeline
import Secrets
import Store

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
    private(set) var sources: [Source] = []
    private(set) var jobs: [Job] = []
    private(set) var lastFetch: Run?
    /// The fetch in flight, or the last one this session; it holds per-source failures.
    private(set) var progress: FetchRun.Progress?
    private(set) var isFetching = false
    /// The master resume editor's state; there once the database is open.
    private(set) var resume: ResumeModel?
    /// AI providers, keys (in the Keychain) and routing; there once the database is open.
    private(set) var ai: AISettingsModel?

    @ObservationIgnored private var db: Database?
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
            let ai = AISettingsModel(db: db, secrets: KeychainStore(service: "com.keneepatel.kairos"))
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

    func fetchNow() {
        guard let db, !isFetching else { return }
        isFetching = true
        let http = self.http
        let run = FetchRun(db: db, makeSource: { try SourceFactory.make($0, http: http) })
        fetchTask = Task { [weak self] in
            for await update in run.start() {
                self?.progress = update
                if update.added > 0 { await self?.reload() }
            }
            if Task.isCancelled { self?.progress?.phase = .cancelled }
            self?.isFetching = false
            await self?.reload()
        }
    }

    func stopFetch() {
        fetchTask?.cancel()
    }

    /// "Last fetch 7:58 AM · 312 found · 12 new", or what's happening now.
    var fetchSummary: String {
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
        return parts.joined(separator: " · ")
    }
}
