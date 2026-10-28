import Foundation
import Jobs
import KairosKit
import Screening
import Secrets
import Store

/// What a fetch has done so far, for the status line.
public struct FetchProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case reading
        /// Looking for the boards behind a search's leads.
        case lookingUp
        case finishing
        case finished
        case stopped
    }

    public var phase = Phase.reading
    /// Sources to read, including boards found during the run.
    public var total = 0
    public var done = 0
    public var stats = RunStats()
    public var failures: [FetchFailure] = []

    public init() {}
}

/// A source that couldn't be read, in words for Sources.
public struct FetchFailure: Sendable, Equatable, Identifiable {
    public let sourceID: UUID
    public let name: String
    public let message: String

    public var id: UUID { sourceID }
}

/// One "Fetch now". Every watched source is read, boards before searches, a few at a time for each
/// job-board system; each answer goes through the listing ledger. Searches spend only their plan's
/// share (Adzuna's, SerpApi's, Himalayas's), Adzuna's snippets become leads, and the boards behind
/// a search's links and leads are added and read in the same run. Catalog boards with nothing for
/// you rest for a few days. Then search listings long unseen close, old jobs you never acted on
/// leave, and the logs are trimmed.
public struct Fetcher: Sendable {
    public struct Options: Sendable {
        /// Reads in flight at once.
        public var width = 16
        /// Reads in flight on one job-board system (Greenhouse serves every Greenhouse board).
        public var perSystem = 4
        /// Companies looked up behind leads per run: at most a few hundred requests.
        public var lookupsPerRun = 60
        public var catalog = BoardCatalog.bundled
        /// Look up the boards behind leads (tests turn it off).
        public var lookUpLeads = true

        public init() {}
    }

    /// "Not found" this many reads in a row, and a board is gone.
    public static let goneAfterMisses = 3
    /// A company with no board found is looked up again after this long.
    public static let lookUpAgainAfter: TimeInterval = .days(30)

    let store: KairosStore
    let http: any HTTPClient
    let keys: Readers.Keys
    let clock: any WallClock
    let options: Options

    public init(
        store: KairosStore, http: any HTTPClient, keys: Readers.Keys, clock: any WallClock = SystemWallClock(),
        options: Options = Options()
    ) {
        self.store = store
        self.http = http
        self.keys = keys
        self.clock = clock
        self.options = options
    }

    /// Runs the fetch; cancelling the task stops it between reads. Returns the finished run.
    @discardableResult
    public func run(progress report: @Sendable (FetchProgress) -> Void = { _ in }) async throws -> Run {
        var run = try await store.activity.start(.fetch, at: clock.now)
        var progress = FetchProgress()
        let plan = try await prepare(&progress)
        report(progress)

        let due = try await store.sources.all().filter { $0.status == .watching }
        let reading = due.filter { $0.isDue(at: plan.now) }
        progress.stats.resting = due.count - reading.count
        let boards = reading.filter(\.kind.isBoard)
        let searches = reading.filter { !$0.kind.isBoard }
        progress.total = reading.count
        report(progress)

        var found: [Board] = []
        await read(boards, plan: plan, progress: &progress, found: &found, report: report)
        await read(searches, plan: plan, progress: &progress, found: &found, report: report)

        // The boards behind a search's links, read now so their postings arrive in full.
        var discovered: [Source] = []
        for board in found where !Task.isCancelled {
            if let source = try await store.sources.add(board, origin: .link, at: plan.now) {
                discovered.append(source)
            }
        }
        if options.lookUpLeads, !Task.isCancelled {
            progress.phase = .lookingUp
            report(progress)
            discovered += try await lookUpLeads(at: plan.now)
        }
        if !discovered.isEmpty { progress.stats.newBoards = (progress.stats.newBoards ?? 0) + discovered.count }
        progress.total += discovered.count
        progress.phase = .reading
        await read(discovered, plan: plan, progress: &progress, found: &found, report: report)

        if !Task.isCancelled {
            progress.phase = .finishing
            report(progress)
            let now = clock.now
            let stale = try await store.ledger.closeStaleSearchListings(at: now)
            if stale > 0 { progress.stats.closed = (progress.stats.closed ?? 0) + stale }
            let retained = try await store.jobs.applyRetention(at: now)
            if retained.archived > 0 { progress.stats.archived = retained.archived }
            try await store.activity.trim(at: now)
            try await store.ai.trim(olderThan: 30, at: now)
        }

        progress.phase = Task.isCancelled ? .stopped : .finished
        progress.stats.sources = progress.done
        progress.stats.failed = progress.failures.isEmpty ? nil : progress.failures.count
        run.stats = progress.stats
        run.finishedAt = clock.now
        run.error = Task.isCancelled ? "Stopped." : nil
        try await store.activity.finish(run)
        report(progress)
        return run
    }

    // MARK: - Planning

    /// What every read in a run shares.
    struct Plan: Sendable {
        let now: Date
        let preferences: SearchPreferences
        /// Nil when no role is set: every title counts.
        let roles: RoleMatcher?
        let postedAfter: Date?
        /// What a fetch keeps changed since the last one: searches ask for every day again.
        let settingsChanged: Bool
        let lastSearched: [String: Date]
    }

    static let fingerprintKey = "fetch_fingerprint"

    /// What decides which postings a fetch keeps. While it's the same, a board's "unchanged" and a
    /// search's "only the days since" are safe; when it changes, every board answers in full once.
    static func fingerprint(_ preferences: SearchPreferences) -> String {
        let roles = preferences.roleMatcher
        return [
            "v1", "age:\(preferences.maxAgeDays.map(String.init) ?? "any")",
            "roles:\(roles.families.map(\.rawValue).sorted().joined(separator: ","))",
            "titles:\(roles.extra.map { $0.lowercased() }.sorted().joined(separator: ","))",
            "countries:\(preferences.countries.map(\.rawValue).joined(separator: ","))",
        ].joined(separator: "|")
    }

    private func prepare(_ progress: inout FetchProgress) async throws -> Plan {
        let now = clock.now
        let preferences = try await store.settings.preferences()
        let fingerprint = Self.fingerprint(preferences)
        let changed = try await store.settings.value(Self.fingerprintKey, as: String.self) != fingerprint
        if changed {
            try await store.sources.forgetETags()
            try await store.settings.set(Self.fingerprintKey, to: fingerprint, at: now)
        }
        if preferences.watchCatalog {
            let added = try await store.sources.add(
                options.catalog.boards(in: preferences.countries), origin: .catalog, at: now)
            if added > 0 { progress.stats.newBoards = added }
        }
        let roles = preferences.roleMatcher
        return Plan(
            now: now, preferences: preferences, roles: roles.isOpen ? nil : roles,
            postedAfter: preferences.maxAgeDays.map { now.addingTimeInterval(-.days(Double($0))) },
            settingsChanged: changed, lastSearched: try await store.activity.lastSearched())
    }

    // MARK: - Reading

    /// One source's answer: nil when it wasn't asked (its plan's share is spent, or a key is
    /// missing, with `skipped` saying which).
    struct Answer: Sendable {
        let source: Source
        var result: Result<ReadResult, SourceError>?
        var skipped: String?
        var turns: [SearchTurn] = []
        var milliseconds = 0
    }

    /// Reads `sources`, a few at a time for each system, and records each answer as it arrives.
    private func read(
        _ sources: [Source], plan: Plan, progress: inout FetchProgress, found: inout [Board],
        report: @Sendable (FetchProgress) -> Void
    ) async {
        guard !sources.isEmpty, !Task.isCancelled else { return }
        let gate = ConcurrencyGate(limit: options.perSystem)
        await withTaskGroup(of: Answer.self) { group in
            var pending = sources[...]
            func startNext() {
                guard !Task.isCancelled, let source = pending.popFirst() else { return }
                group.addTask {
                    let answer = try? await gate.run(source.kind.rawValue) { await self.ask(source, plan: plan) }
                    return answer ?? Answer(source: source, result: .failure(.cancelled))
                }
            }
            for _ in 0..<options.width { startNext() }
            for await answer in group {
                await record(answer, plan: plan, progress: &progress, found: &found)
                progress.done += 1
                report(progress)
                startNext()
            }
        }
    }

    private func ask(_ source: Source, plan: Plan) async -> Answer {
        let started = Date()
        var answer = await read(source, plan: plan)
        answer.milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        return answer
    }

    private func read(_ source: Source, plan: Plan) async -> Answer {
        var answer = Answer(source: source)
        var request = ReadRequest(
            roles: plan.roles ?? RoleMatcher(families: []), countries: plan.preferences.countries,
            maxAgeDays: plan.preferences.maxAgeDays)
        let reader: any JobReader
        if let board = source.board {
            request.knownURLs = (try? await store.jobs.knownURLs(of: source.id)) ?? []
            request.etag = source.etag
            reader = Readers.board(board, http: http, clock: clock)
        } else {
            switch Readers.search(source.kind, keys: keys, http: http, clock: clock) {
            case .failure(let error):
                answer.skipped = error.message
                return answer
            case .success(let search):
                reader = search
            }
            let used =
                (try? await store.activity.requests(of: source.id, at: plan.now)) ?? (today: 0, week: 0, month: 0)
            let budget = Self.budget(for: source.kind)?.remaining(today: used.today, week: used.week, month: used.month)
            guard let budget, budget > 0 else {
                answer.skipped = "Its plan's share for now is spent."
                return answer
            }
            request.budget = budget
            request.since = plan.settingsChanged ? nil : source.okAt
            if source.kind == .googleJobs {
                let all = SearchTurn.all(
                    phrases: (plan.roles ?? plan.preferences.roleMatcher).googlePhrases,
                    places: plan.preferences.effectivePlaces, countries: plan.preferences.countries)
                answer.turns = SearchTurn.due(all, lastSearched: plan.lastSearched, count: budget)
                guard !answer.turns.isEmpty else {
                    answer.skipped = "Set your roles to search Google Jobs."
                    return answer
                }
                request.turns = answer.turns
            }
        }
        do {
            answer.result = .success(try await reader.read(request))
        } catch {
            answer.result = .failure(error)
        }
        return answer
    }

    static func budget(for kind: SourceKind) -> SearchBudget? {
        switch kind {
        case .adzuna: .adzuna
        case .googleJobs: .serpAPI
        case .himalayas: .himalayas
        default: nil
        }
    }

    // MARK: - Recording

    private func record(_ answer: Answer, plan: Plan, progress: inout FetchProgress, found: inout [Board]) async {
        var source = answer.source
        var entry = FetchLogEntry(
            sourceID: source.id, at: clock.now, outcome: .ok, requests: 0, milliseconds: answer.milliseconds)
        await apply(answer, to: &source, entry: &entry, plan: plan, progress: &progress, found: &found)
        try? await store.activity.log([entry])
        try? await store.sources.save(source)
    }

    private func apply(
        _ answer: Answer, to source: inout Source, entry: inout FetchLogEntry, plan: Plan,
        progress: inout FetchProgress,
        found: inout [Board]
    ) async {
        let now = entry.at
        guard let result = answer.result else {
            progress.stats.searchesSkipped = (progress.stats.searchesSkipped ?? 0) + 1
            entry.outcome = .skipped
            entry.error = answer.skipped
            source.lastError = answer.skipped
            return
        }
        source.checkedAt = now
        switch result {
        case .failure(let error):
            entry.outcome = .failed
            entry.error = error.message
            entry.requests = 1
            source.failStreak += 1
            source.lastError = error.message
            if case .notFound = error {
                source.missingStreak += 1
                if source.missingStreak >= Self.goneAfterMisses { source.status = .gone }
            }
            if error != .cancelled {
                progress.failures.append(
                    FetchFailure(sourceID: source.id, name: source.displayName, message: error.message))
            }
        case .success(let read):
            entry.requests = read.requests
            entry.items = read.postings.count
            do {
                if read.unchanged {
                    entry.outcome = .unchanged
                    entry.closed = try await store.ledger.recordUnchanged(source, at: now)
                    progress.stats.unchanged = (progress.stats.unchanged ?? 0) + 1
                    if entry.closed > 0 { progress.stats.closed = (progress.stats.closed ?? 0) + entry.closed }
                } else {
                    try await take(read, from: source, plan: plan, entry: &entry, progress: &progress, found: &found)
                    if !answer.turns.isEmpty {
                        let searched = answer.turns.prefix(max(read.requests, 1)).map(\.key)
                        try await store.activity.markSearched(Array(searched), at: now)
                    }
                    source.etag = read.etag
                }
                source.okAt = now
                source.failStreak = 0
                source.missingStreak = 0
                source.lastError = nil
                try await rest(&source, at: now)
            } catch {
                entry.outcome = .failed
                entry.error = "Couldn't save its jobs: \(error)"
                // Nothing was saved, so its next answer mustn't be "unchanged".
                source.etag = nil
                progress.failures.append(
                    FetchFailure(sourceID: source.id, name: source.displayName, message: entry.error ?? ""))
            }
        }
    }

    /// One answer's postings: listings to the ledger, snippets to leads, and the boards behind a
    /// search's links to `found`.
    private func take(
        _ read: ReadResult, from source: Source, plan: Plan, entry: inout FetchLogEntry, progress: inout FetchProgress,
        found: inout [Board]
    ) async throws {
        progress.stats.found = (progress.stats.found ?? 0) + read.postings.count
        var listings: [Listing] = []
        var leads: [Lead] = []
        for posting in read.postings {
            guard let listing = Normalizer.normalize(posting) else {
                progress.stats.outside = (progress.stats.outside ?? 0) + 1
                continue
            }
            if listing.isSnippet || source.kind == .adzuna {
                if plan.roles?.matches(listing.title) ?? true {
                    leads.append(Lead(listing, at: plan.now))
                } else {
                    progress.stats.otherRoles = (progress.stats.otherRoles ?? 0) + 1
                }
            } else {
                listings.append(listing)
            }
        }
        if !leads.isEmpty {
            let new = try await store.activity.save(leads, at: plan.now)
            progress.stats.leads = (progress.stats.leads ?? 0) + new
            entry.added = new
        }
        if !source.kind.isBoard {
            for board in ATSDetector.boards(behind: read.postings) where !found.contains(where: { $0.key == board.key })
            {
                found.append(board)
            }
        }
        guard !listings.isEmpty || read.complete else { return }
        let outcome = try await store.ledger.record(
            listings, from: source, complete: read.complete, at: plan.now, postedAfter: plan.postedAfter,
            roles: plan.roles)
        entry.added += outcome.added
        entry.changed = outcome.changed
        entry.closed = outcome.closed
        progress.stats.add(outcome)
    }

    /// A board you didn't add rests while it has nothing for you: 3 days, then 6, then a week at a
    /// time. One with a job for you is read every fetch.
    private func rest(_ source: inout Source, at now: Date) async throws {
        guard source.kind.isBoard, source.origin != .you else { return }
        if try await store.jobs.openListingCount(of: source.id) > 0 {
            source.quietStreak = 0
            source.restUntil = nil
        } else {
            source.quietStreak += 1
            source.restUntil = now.addingTimeInterval(.days(Double(min(3 * source.quietStreak, 7))))
        }
    }

    // MARK: - Leads

    /// Looks for public boards behind the companies of recent leads, newest first, and returns the
    /// boards it added as sources. Each company is looked up once, and again a month later when
    /// nothing was found.
    private func lookUpLeads(at now: Date) async throws -> [Source] {
        let leads = try await store.activity.leads(since: now.addingTimeInterval(-.days(30)))
        let known = Set(try await store.sources.all().filter(\.kind.isBoard).map { DedupKey.company($0.name) })
        var names: [String: String] = [:]
        var order: [String] = []
        for lead in leads where !BoardCatalog.isAggregator(lead.company) {
            let key = DedupKey.company(lead.company)
            guard !key.isEmpty, !known.contains(key), names[key] == nil, lead.company != "Company not listed" else {
                continue
            }
            names[key] = lead.company
            order.append(key)
        }
        let lookups = try await store.activity.lookups(order)
        let due = order.filter { key in
            guard let lookup = lookups[key] else { return true }
            return lookup.board == nil && now.timeIntervalSince(lookup.checkedAt) >= Self.lookUpAgainAfter
        }.prefix(options.lookupsPerRun)
        let catalog = options.catalog
        let probe = BoardProbe(http: http)
        let results = await withTaskGroup(of: CompanyLookup.self) { group in
            var pending = due[...]
            var results: [CompanyLookup] = []
            func startNext() {
                guard !Task.isCancelled, let key = pending.popFirst(), let name = names[key] else { return }
                group.addTask {
                    var board = catalog.board(forCompany: name)
                    if board == nil { board = await probe.find(name) }
                    board?.name = name
                    return CompanyLookup(nameKey: key, board: board, checkedAt: now)
                }
            }
            for _ in 0..<8 { startNext() }
            for await result in group {
                results.append(result)
                startNext()
            }
            return results
        }
        try await store.activity.save(results)
        var added: [Source] = []
        for board in results.compactMap(\.board) {
            if let source = try await store.sources.add(board, origin: .lead, at: now) { added.append(source) }
        }
        return added
    }
}

extension RunStats {
    mutating func add(_ outcome: ListingLedger.Outcome) {
        func plus(_ value: Int?, _ more: Int) -> Int? { more == 0 ? value : (value ?? 0) + more }
        added = plus(added, outcome.added)
        attached = plus(attached, outcome.attached)
        changed = plus(changed, outcome.changed)
        closed = plus(closed, outcome.closed)
        reopened = plus(reopened, outcome.reopened)
        tooOld = plus(tooOld, outcome.tooOld)
        otherRoles = plus(otherRoles, outcome.otherRoles)
    }
}

extension Readers.Keys {
    /// The searches' keys from your saved keys.
    public init(secrets: any SecretStore) {
        func read(_ key: SecretKey) -> String? {
            (try? secrets.read(key))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        var credentials: AdzunaReader.Credentials?
        if let id = read(.adzunaAppID), let key = read(.adzunaAppKey) {
            credentials = AdzunaReader.Credentials(appID: id, appKey: key)
        }
        self.init(adzuna: credentials, himalayas: read(.himalayas), serpAPI: read(.serpAPI))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
