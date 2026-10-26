import Foundation
import JobSources
import LLM
import Store

/// One "Fetch now": every enabled source is fetched (a few at a time), and each answer goes to
/// the `ListingLedger` (SPEC §5.2, steps 1–3; job collection v2): new jobs stored, copies on other
/// sources attached to their job, edits and closings recorded. Postings outside Canada and the US
/// are dropped, and new ones older than your "posted within" limit never stored. A board that
/// hasn't changed answers "unchanged" to its last ETag. Then old jobs you never engaged with leave
/// (`Retention`, T46). Progress arrives as an `AsyncStream`; stopping the stream cancels the run.
public struct FetchRun: Sendable {
    public struct Progress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable { case running, finished, cancelled }
        public var phase: Phase = .running
        public var sourcesTotal = 0
        public var sourcesDone = 0
        /// Postings the boards returned.
        public var found = 0
        /// Dropped because every place they name is outside Canada and the US.
        public var outside = 0
        /// Not new jobs: stored before, or another board's copy (now attached to its job).
        public var duplicates = 0
        /// Copies of stored jobs found on another source, now listed with them.
        public var attached = 0
        /// Postings whose title, place or text changed.
        public var changed = 0
        /// Snippets a full posting replaced.
        public var upgraded = 0
        /// Jobs no longer posted anywhere, and jobs back again.
        public var closed = 0
        public var reopened = 0
        /// Boards that said nothing changed since last time.
        public var unchanged = 0
        /// New postings left out because their titles aren't among your roles.
        public var otherRoles = 0
        /// Searches not asked this time: their plan's share for now was spent.
        public var searchesSkipped = 0
        /// Catalog boards added as sources before the fetch (J5).
        public var catalogAdded = 0
        /// Catalog boards with nothing for you, checked lately, so not asked this time.
        public var quiet = 0
        /// Companies' boards found behind a search's leads or links and read this run (J6, C1).
        public var boardsFound = 0
        /// New leads: postings a search sent as snippets, kept as company names to look up (C2).
        public var leads = 0
        /// Dropped because they were posted before your "posted within" limit.
        public var tooOld = 0
        public var added = 0
        public var failures: [Failure] = []
        /// Old jobs archived (60 days) and removed (120 days) at the end of the run.
        public var retired = Retention.Outcome()

        public init() {}
    }

    public struct Failure: Sendable, Equatable {
        public let sourceID: UUID
        public let message: String
    }

    /// The `run.stats` JSON for a fetch.
    public struct Stats: Codable, Equatable, Sendable {
        public let sources: Int
        public let failed: Int
        public let found: Int
        public let outside: Int
        public let duplicates: Int
        public let added: Int
        /// Old jobs the run archived and removed; nil when none, as in runs from before retention.
        public var archived: Int?
        public var removed: Int?
        /// Postings skipped as older than your "posted within" limit; nil when none.
        public var tooOld: Int?
        /// Edited postings, snippets replaced, jobs closed and unchanged boards; nil when none, as
        /// in runs from before job collection v2.
        public var changed: Int?
        public var upgraded: Int?
        public var closed: Int?
        public var unchanged: Int?
        public var otherRoles: Int?
        public var searchesSkipped: Int?
        public var catalogAdded: Int?
        public var quiet: Int?
        public var boardsFound: Int?
        public var leads: Int?

        public static func decode(_ json: String) -> Stats? {
            try? JSONDecoder().decode(Stats.self, from: Data(json.utf8))
        }
    }

    public typealias MakeSource = @Sendable (Source) throws -> (any JobSource, SourceQuery)

    let db: Database
    let makeSource: MakeSource
    let maxConcurrent: Int
    let now: @Sendable () -> Date
    let postedWithinDays: Int?
    let roles: RoleMatcher?
    let watch: CatalogWatch?
    let finder: LeadFinder?

    /// A catalog board with nothing open for you is asked every this often, not every fetch.
    public static let quietEvery: TimeInterval = 3 * 86_400
    /// "Not found" this many fetches in a row, and a board is gone.
    public static let goneAfterMisses = 3

    /// At most 4 HTTP sources at a time (SPEC §5.2). `postedWithinDays` is your Fetch screen's
    /// "Posted" setting: older postings are never stored; nil keeps every age. `roles`: new
    /// postings whose titles aren't among them are counted, not stored (J3).
    public init(
        db: Database, maxConcurrent: Int = 4, now: @escaping @Sendable () -> Date = { Date() },
        postedWithinDays: Int? = nil, roles: RoleMatcher? = nil, watch: CatalogWatch? = nil,
        finder: LeadFinder? = nil, makeSource: @escaping MakeSource
    ) {
        self.watch = watch
        self.finder = finder
        self.db = db
        self.makeSource = makeSource
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
        self.postedWithinDays = postedWithinDays
        self.roles = roles.flatMap { $0.isOpen ? nil : $0 }
    }

    public func start() -> AsyncStream<Progress> {
        AsyncStream { continuation in
            let task = Task { await perform(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ continuation: AsyncStream<Progress>.Continuation) async {
        var progress = Progress()
        let runs = RunRepository(db)
        let runID = try? await runs.begin(kind: "fetch")
        if let watch { progress.catalogAdded = (try? await watch.sync(db)) ?? 0 }
        let open = (try? await ListingRepository(db).openCounts()) ?? [:]
        let at = now()
        // A gone board waits for you to resume it; a quiet catalog board waits its turn.
        let sources = ((try? await SourceRepository(db).sources(enabledOnly: true)) ?? []).filter { source in
            guard source.health != .gone else { return false }
            let quiet =
                BoardConfig.decode(source.config)?.origin == "catalog" && (open[source.id] ?? 0) == 0
                && source.lastRunAt.map { at.timeIntervalSince($0) < Self.quietEvery } == true
            if quiet { progress.quiet += 1 }
            return !quiet
        }
        progress.sourcesTotal = sources.count
        continuation.yield(progress)

        // Company boards first, then search sources (Adzuna): a job on both keeps the board's full
        // posting rather than a search's snippet, since the first copy stored wins.
        let boards = sources.filter { !$0.kind.isSearch }
        let searches = sources.filter(\.kind.isSearch)
        let log = FetchLog(db)
        var memos: [UUID: SourceFetchState] = [:]
        for source in sources { memos[source.id] = (try? await log.state(of: source.id)) ?? SourceFetchState() }
        // Boards Kairos reads, behind a search's links (C1): each names a company to watch.
        var linked: [SourceKind: [BoardsFromLinks.Found]] = [:]
        for batch in [boards, searches] where !batch.isEmpty && !Task.isCancelled {
            await withTaskGroup(of: (Source, Fetched).self) { group in
                var pending = batch[...]
                func startNext() {
                    guard let source = pending.popFirst() else { return }
                    let state = memos[source.id] ?? SourceFetchState()
                    let memo = state.fingerprint == fingerprint ? FetchMemo(etag: state.etag) : nil
                    // Only days since a good fetch under the same settings, for a search.
                    let since = state.fingerprint == fingerprint ? state.lastOKAt : nil
                    group.addTask { (source, await fetch(source, since: memo, lastGood: since)) }
                }
                for _ in 0..<maxConcurrent { startNext() }
                for await (source, fetched) in group {
                    guard !Task.isCancelled else { break }
                    if source.kind.isSearch, case .success(.postings(let postings, _))? = fetched.answer {
                        linked[source.kind, default: []] += BoardsFromLinks.boards(in: postings)
                    }
                    await record(
                        fetched, from: source, state: memos[source.id] ?? SourceFetchState(), run: runID,
                        into: &progress)
                    progress.sourcesDone += 1
                    continuation.yield(progress)
                    startNext()
                }
            }
        }
        // The companies behind a search's links, read now so their postings arrive in full (C1).
        for (kind, boards) in linked.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where !Task.isCancelled {
            for source in (try? await BoardsFromLinks.add(boards, via: kind, to: db)) ?? [] where !Task.isCancelled {
                progress.boardsFound += 1
                progress.sourcesTotal += 1
                let fetched = await fetch(source, since: nil, lastGood: nil)
                await record(fetched, from: source, state: SourceFetchState(), run: runID, into: &progress)
                progress.sourcesDone += 1
                continuation.yield(progress)
            }
        }
        // The boards behind a search's leads, read now so the companies' postings arrive in full
        // (J6, C2).
        if !Task.isCancelled, let finder {
            for source in await finder.findBoards() where !Task.isCancelled {
                progress.boardsFound += 1
                progress.sourcesTotal += 1
                let fetched = await fetch(source, since: nil, lastGood: nil)
                await record(fetched, from: source, state: SourceFetchState(), run: runID, into: &progress)
                progress.sourcesDone += 1
                continuation.yield(progress)
            }
        }
        // A search can't show a job is gone, so its listings close when they've long gone unseen.
        if !Task.isCancelled,
            let stale = try? await ListingLedger(db).closeStaleSearchListings(of: searches.map(\.id), at: now())
        {
            progress.closed += stale
        }

        if !Task.isCancelled, let retired = try? await Retention(db).apply(now: now()) {
            progress.retired = retired
        }
        // Leads keep 30 days: a company still posting stays worth a look.
        _ = try? await LeadRepository(db).deleteOlder(than: now().addingTimeInterval(-30 * 86_400))
        // The AI call logs keep 30 days (SPEC §6.2), the per-key one with them.
        let logStart = now().addingTimeInterval(-Double(CallLog.retentionDays) * 86_400)
        _ = try? await CallLog(db).deleteOlder(than: logStart)
        _ = try? await KeyCallLog(db).deleteOlder(than: logStart)
        _ = try? await log.deleteOlder(than: now().addingTimeInterval(-Double(FetchLog.retentionDays) * 86_400))
        progress.phase = Task.isCancelled ? .cancelled : .finished
        if let runID {
            let stats = Stats(
                sources: progress.sourcesTotal, failed: progress.failures.count, found: progress.found,
                outside: progress.outside, duplicates: progress.duplicates, added: progress.added,
                archived: progress.retired.archived > 0 ? progress.retired.archived : nil,
                removed: progress.retired.removed > 0 ? progress.retired.removed : nil,
                tooOld: progress.tooOld > 0 ? progress.tooOld : nil,
                changed: progress.changed > 0 ? progress.changed : nil,
                upgraded: progress.upgraded > 0 ? progress.upgraded : nil,
                closed: progress.closed > 0 ? progress.closed : nil,
                unchanged: progress.unchanged > 0 ? progress.unchanged : nil,
                otherRoles: progress.otherRoles > 0 ? progress.otherRoles : nil,
                searchesSkipped: progress.searchesSkipped > 0 ? progress.searchesSkipped : nil,
                catalogAdded: progress.catalogAdded > 0 ? progress.catalogAdded : nil,
                quiet: progress.quiet > 0 ? progress.quiet : nil,
                boardsFound: progress.boardsFound > 0 ? progress.boardsFound : nil,
                leads: progress.leads > 0 ? progress.leads : nil)
            let json = (try? JSONEncoder().encode(stats)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            try? await runs.finish(runID, stats: json, error: progress.phase == .cancelled ? "cancelled" : nil)
        }
        continuation.yield(progress)
        continuation.finish()
    }

    /// The settings an ETag's answer was taken under: a board's "unchanged" only counts while the
    /// "Posted" limit (which decides which new postings are kept) is the same.
    var fingerprint: String {
        "v2|posted:\(postedWithinDays.map(String.init) ?? "any")|roles:\(roles?.fingerprint ?? "any")"
    }

    /// One source's answer, with whether it lists everything the source has open, and how long it
    /// took; nil when it wasn't asked (its plan's share was spent).
    struct Fetched: Sendable {
        let answer: Result<FetchAnswer, any Error>?
        let listsEverything: Bool
        let milliseconds: Int
    }

    /// What a search may spend this run: its share of its plan, from the fetch log (Adzuna's free
    /// plan, SerpApi's for Google Jobs, Himalayas's allowance).
    private func callBudget(for source: Source) async -> Int? {
        let plan: AdzunaSource.Budget
        switch source.kind {
        case .adzuna: plan = .standard
        case .googleJobs: plan = GoogleJobsSource.budget
        case .himalayas: plan = AdzunaSource.Budget(day: 300, week: 2_000, month: 8_000, run: 30)
        default: return nil
        }
        let at = now()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let log = FetchLog(db)
        func used(since date: Date?) async -> Int {
            guard let date else { return 0 }
            return (try? await log.requests(of: source.id, since: date)) ?? 0
        }
        return plan.remaining(
            today: await used(since: utc.dateInterval(of: .day, for: at)?.start),
            week: await used(since: at.addingTimeInterval(-7 * 86_400)),
            month: await used(since: utc.dateInterval(of: .month, for: at)?.start))
    }

    private func fetch(_ source: Source, since memo: FetchMemo?, lastGood: Date?) async -> Fetched {
        let started = Date()
        func took() -> Int { Int(Date().timeIntervalSince(started) * 1_000) }
        do {
            var (jobSource, query) = try makeSource(source)
            // A board that needs a request per job skips the ones Kairos already has, and asks
            // only for your roles.
            let open = (try? await ListingRepository(db).openListings(of: source.id)) ?? []
            query.knownURLs = Set(open.map(\.canonicalURL))
            if query.roles == nil { query.roles = roles }
            if let budget = await callBudget(for: source) {
                guard budget > 0 else { return Fetched(answer: nil, listsEverything: false, milliseconds: took()) }
                query.callBudget = budget
                query.since = lastGood
            }
            let answer = try await jobSource.fetch(query, since: memo)
            return Fetched(answer: .success(answer), listsEverything: jobSource.listsEverything, milliseconds: took())
        } catch {
            return Fetched(answer: .failure(error), listsEverything: false, milliseconds: took())
        }
    }

    private func record(
        _ fetched: Fetched, from source: Source, state: SourceFetchState, run: UUID?, into progress: inout Progress
    ) async {
        let sources = SourceRepository(db)
        let log = FetchLog(db)
        let at = now()
        var state = state
        var entry = FetchLogEntry(
            runID: run, sourceID: source.id, at: at, request: source.kind.isSearch ? "search" : "board", outcome: .ok,
            milliseconds: fetched.milliseconds)
        switch fetched.answer {
        case nil:
            progress.searchesSkipped += 1
            entry.outcome = .skipped
            entry.requests = 0
        case .failure(let error)?:
            let message = Self.message(for: error)
            progress.failures.append(Failure(sourceID: source.id, message: message))
            // A failed run found nothing, so it counts toward "degraded" too.
            _ = try? await sources.recordRun(of: source.id, found: 0, at: at)
            state.failRuns += 1
            entry.outcome = .failed
            entry.error = message
            // The company left that ATS or closed its board.
            if case .notFound? = error as? SourceError, state.failRuns >= Self.goneAfterMisses {
                try? await sources.markGone(source.id)
            }
        case .success(.unchanged)?:
            // Every job it had open is still there: seen now, and the board isn't empty.
            let closed = (try? await ListingLedger(db).recordUnchanged(source.id, at: at)) ?? 0
            progress.closed += closed
            entry.closed = closed
            let open = (try? await ListingRepository(db).openListings(of: source.id).count) ?? 0
            _ = try? await sources.recordRun(of: source.id, found: max(open, 1), at: at)
            progress.unchanged += 1
            state.lastOKAt = at
            state.failRuns = 0
            entry.outcome = .unchanged
        case .success(.postings(let postings, let memo))? where source.kind.sendsSnippets:
            // A search that sends snippets (Adzuna) gives leads, never jobs (v3, C2): the
            // companies posting at your roles, for the finder to look up on public boards.
            progress.found += postings.count
            entry.items = postings.count
            entry.requests = memo?.requests ?? 1
            var leads: [Lead] = []
            for posting in postings {
                if let roles, !roles.matches(posting.title) {
                    progress.otherRoles += 1
                    continue
                }
                leads.append(
                    Lead(
                        id: JobID(canonicalURL: URLCanonicalizer.canonical(posting.url)).rawValue, sourceID: source.id,
                        company: posting.company, title: posting.title, location: posting.location,
                        postedAt: posting.postedAt, firstSeenAt: at, lastSeenAt: at))
            }
            let new = (try? await LeadRepository(db).record(leads)) ?? 0
            progress.leads += new
            entry.added = new
            state.fingerprint = fingerprint
            state.lastOKAt = at
            state.failRuns = 0
            _ = try? await sources.recordRun(of: source.id, found: postings.count, at: at)
        case .success(.postings(let postings, let memo))?:
            progress.found += postings.count
            entry.items = postings.count
            entry.requests = memo?.requests ?? 1
            do {
                let cutoff = postedWithinDays.map { at.addingTimeInterval(-Double($0) * 86_400) }
                let outcome = try await ListingLedger(db).record(
                    postings, from: source.id, kind: source.kind, complete: fetched.listsEverything, at: at,
                    postedAfter: cutoff, roles: roles)
                progress.added += outcome.added
                progress.outside += outcome.outside
                progress.duplicates += outcome.duplicates
                progress.tooOld += outcome.tooOld
                progress.otherRoles += outcome.otherRoles
                progress.attached += outcome.attached
                progress.changed += outcome.changed
                progress.upgraded += outcome.upgraded
                progress.closed += outcome.closed
                progress.reopened += outcome.reopened
                entry.added = outcome.added
                entry.changed = outcome.changed
                entry.closed = outcome.closed
                state.etag = memo?.etag
                state.fingerprint = fingerprint
                state.lastOKAt = at
                state.failRuns = 0
            } catch {
                progress.failures.append(Failure(sourceID: source.id, message: "Couldn't save the jobs: \(error)"))
                entry.outcome = .failed
                entry.error = "\(error)"
                // Nothing was saved, so its next answer mustn't be "unchanged".
                state.etag = nil
            }
            _ = try? await sources.recordRun(of: source.id, found: postings.count, at: at)
        }
        try? await log.save(state, of: source.id)
        try? await log.record(entry)
    }

    static func message(for error: any Error) -> String {
        if let error = error as? SourceError { return error.message }
        if error is CancellationError { return SourceError.cancelled.message }
        return "Something went wrong: \(error.localizedDescription)"
    }
}
