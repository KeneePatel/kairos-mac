import Foundation
import Jobs
import KairosKit
import SQL

/// One read a fetch made of one source.
public struct FetchLogEntry: Sendable, Equatable {
    public enum Outcome: String, Sendable, Codable {
        case ok, unchanged, failed
        /// Not read: muted, resting, or a search with nothing left of its budget.
        case skipped
    }

    public var runID: UUID?
    public var sourceID: UUID
    public var at: Date
    public var outcome: Outcome
    public var httpStatus: Int?
    public var error: String?
    /// HTTP requests it took: what search budgets count.
    public var requests: Int
    /// Postings the answer held.
    public var items: Int
    public var added: Int
    public var changed: Int
    public var closed: Int
    public var milliseconds: Int

    public init(
        runID: UUID? = nil, sourceID: UUID, at: Date, outcome: Outcome, httpStatus: Int? = nil, error: String? = nil,
        requests: Int = 1, items: Int = 0, added: Int = 0, changed: Int = 0, closed: Int = 0, milliseconds: Int = 0
    ) {
        self.runID = runID
        self.sourceID = sourceID
        self.at = at
        self.outcome = outcome
        self.httpStatus = httpStatus
        self.error = error
        self.requests = requests
        self.items = items
        self.added = added
        self.changed = changed
        self.closed = closed
        self.milliseconds = milliseconds
    }
}

/// Which public board a company is on, or that none was found.
public struct CompanyLookup: Sendable, Equatable {
    public var nameKey: String
    public var board: Board?
    public var checkedAt: Date

    public init(nameKey: String, board: Board?, checkedAt: Date) {
        self.nameKey = nameKey
        self.board = board
        self.checkedAt = checkedAt
    }
}

/// Runs, the fetch log, leads, company lookups and Google Jobs turns: what Kairos did and plans.
public struct ActivityRepository: Sendable {
    let db: Database

    // MARK: - Runs

    public func start(_ kind: Run.Kind, at now: Date = Date()) async throws -> Run {
        let run = Run(id: .v7(at: now), kind: kind, startedAt: now, finishedAt: nil, stats: RunStats(), error: nil)
        try await db.execute(
            "INSERT INTO run (id, kind, started_at, stats) VALUES (?, ?, ?, '{}')",
            [.id(run.id), .text(kind.rawValue), SQLValue(now)])
        return run
    }

    public func finish(_ run: Run) async throws {
        try await db.execute(
            "UPDATE run SET finished_at = ?, stats = ?, error = ? WHERE id = ?",
            [SQLValue(run.finishedAt ?? Date()), try .json(run.stats), SQLValue(run.error), .id(run.id)])
    }

    /// The latest runs of a kind, newest first.
    public func runs(_ kind: Run.Kind, limit: Int = 20) async throws -> [Run] {
        try await db.query(
            "SELECT * FROM run WHERE kind = ? ORDER BY started_at DESC, id DESC LIMIT ?",
            [.text(kind.rawValue), SQLValue(limit)]
        ).map(Self.run)
    }

    public func lastRun(_ kind: Run.Kind) async throws -> Run? {
        try await runs(kind, limit: 1).first
    }

    /// The last finished run of a kind that didn't fail: when Kairos last fetched.
    public func lastGoodRun(_ kind: Run.Kind) async throws -> Run? {
        try await db.first(
            """
            SELECT * FROM run WHERE kind = ? AND finished_at IS NOT NULL AND error IS NULL
            ORDER BY started_at DESC, id DESC LIMIT 1
            """, [.text(kind.rawValue)]
        ).map(Self.run)
    }

    /// Runs Kairos quit during are marked as stopped.
    @discardableResult
    public func closeInterruptedRuns(at now: Date = Date()) async throws -> Int {
        try await db.transaction { connection in
            try connection.execute(
                "UPDATE run SET finished_at = ?, error = 'Kairos quit before it finished.' WHERE finished_at IS NULL",
                [SQLValue(now)])
            return connection.changes
        }
    }

    // MARK: - Fetch log

    public func log(_ entries: [FetchLogEntry]) async throws {
        guard !entries.isEmpty else { return }
        let rows = entries.map { entry -> [SQLValue] in
            [
                .id(entry.runID), .id(entry.sourceID), SQLValue(entry.at), .text(entry.outcome.rawValue),
                SQLValue(entry.httpStatus), SQLValue(entry.error), SQLValue(entry.requests), SQLValue(entry.items),
                SQLValue(entry.added), SQLValue(entry.changed), SQLValue(entry.closed), SQLValue(entry.milliseconds),
            ]
        }
        try await db.transaction { connection in
            for values in rows {
                try connection.execute(
                    """
                    INSERT INTO fetch_log (run_id, source_id, at, outcome, http_status, error, requests, items, added,
                        changed, closed, ms)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, values)
            }
        }
    }

    /// Requests a source made since the start of today (UTC), in the last 7 days, and since the
    /// start of this month (UTC): what its search budget counts.
    public func requests(of source: UUID, at now: Date = Date()) async throws -> (today: Int, week: Int, month: Int) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let day = utc.startOfDay(for: now)
        let month = utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? day
        let row = try await db.first(
            """
            SELECT coalesce(sum(CASE WHEN at >= ? THEN requests END), 0) AS today,
                coalesce(sum(CASE WHEN at >= ? THEN requests END), 0) AS week,
                coalesce(sum(CASE WHEN at >= ? THEN requests END), 0) AS month
            FROM fetch_log WHERE source_id = ? AND at >= ?
            """,
            [
                SQLValue(day), SQLValue(now.addingTimeInterval(-.days(7))), SQLValue(month), .id(source),
                SQLValue(min(month, now.addingTimeInterval(-.days(7)))),
            ])
        return (row?.int("today") ?? 0, row?.int("week") ?? 0, row?.int("month") ?? 0)
    }

    /// Each source's latest read.
    public func lastReads() async throws -> [UUID: FetchLogEntry] {
        var result: [UUID: FetchLogEntry] = [:]
        for row in try await db.query(
            """
            SELECT f.* FROM fetch_log f
            WHERE f.id = (SELECT g.id FROM fetch_log g WHERE g.source_id = f.source_id ORDER BY g.at DESC, g.id DESC LIMIT 1)
            """)
        {
            if let entry = Self.entry(row) { result[entry.sourceID] = entry }
        }
        return result
    }

    /// Jobs each source added since `start`, for Sources.
    public func added(since start: Date) async throws -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for row in try await db.query(
            "SELECT source_id, sum(added) AS n FROM fetch_log WHERE at >= ? GROUP BY source_id", [SQLValue(start)])
        {
            if let id = row.string("source_id").flatMap(UUID.init(uuidString:)) { result[id] = row.int("n") ?? 0 }
        }
        return result
    }

    // MARK: - Leads

    /// Records leads; one seen before is seen again. Returns how many are new.
    @discardableResult
    public func save(_ leads: [Lead], at now: Date = Date()) async throws -> Int {
        guard !leads.isEmpty else { return 0 }
        let rows = leads.map { lead -> [SQLValue] in
            [
                .text(lead.id), .text(lead.company), .text(lead.title), .text(lead.location), SQLValue(lead.postedAt),
                SQLValue(now), SQLValue(now),
            ]
        }
        return try await db.transaction { connection in
            var added = 0
            for values in rows {
                let known = try connection.first("SELECT 1 AS known FROM lead WHERE id = ?", [values[0]]) != nil
                try connection.execute(
                    """
                    INSERT INTO lead (id, company, title, location, posted_at, first_seen_at, last_seen_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET last_seen_at = excluded.last_seen_at
                    """, values)
                if !known { added += 1 }
            }
            return added
        }
    }

    /// Leads seen since `start`, the latest first.
    public func leads(since start: Date) async throws -> [Lead] {
        try await db.query(
            "SELECT * FROM lead WHERE last_seen_at >= ? ORDER BY last_seen_at DESC, id", [SQLValue(start)]
        )
        .compactMap { row in
            guard let id = row.string("id"), let company = row.string("company"), let first = row.date("first_seen_at")
            else { return nil }
            return Lead(
                id: id, company: company, title: row.string("title") ?? "", location: row.string("location") ?? "",
                postedAt: row.date("posted_at"), firstSeenAt: first, lastSeenAt: row.date("last_seen_at") ?? first)
        }
    }

    // MARK: - Company lookups

    public func lookups(_ nameKeys: [String]) async throws -> [String: CompanyLookup] {
        guard !nameKeys.isEmpty else { return [:] }
        var result: [String: CompanyLookup] = [:]
        for row in try await db.query(
            "SELECT * FROM company_lookup WHERE name_key IN (SELECT value FROM json_each(?))", [try .json(nameKeys)])
        {
            guard let key = row.string("name_key"), let checked = row.date("checked_at") else { continue }
            var board: Board?
            if let kind = row.optionalValue("kind", as: SourceKind.self), let slug = row.string("slug") {
                board = Board(kind: kind, slug: slug, name: "")
            }
            result[key] = CompanyLookup(nameKey: key, board: board, checkedAt: checked)
        }
        return result
    }

    public func save(_ lookups: [CompanyLookup]) async throws {
        guard !lookups.isEmpty else { return }
        let rows = lookups.map {
            [.text($0.nameKey), SQLValue($0.board?.kind.rawValue), SQLValue($0.board?.slug), SQLValue($0.checkedAt)]
        }
        try await db.transaction { connection in
            for values in rows {
                try connection.execute(
                    """
                    INSERT INTO company_lookup (name_key, kind, slug, checked_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT (name_key) DO UPDATE SET kind = excluded.kind, slug = excluded.slug,
                        checked_at = excluded.checked_at
                    """, values)
            }
        }
    }

    // MARK: - Google Jobs turns

    public func lastSearched() async throws -> [String: Date] {
        var result: [String: Date] = [:]
        for row in try await db.query("SELECT key, last_at FROM search_turn") {
            if let key = row.string("key"), let at = row.date("last_at") { result[key] = at }
        }
        return result
    }

    public func markSearched(_ keys: [String], at now: Date = Date()) async throws {
        guard !keys.isEmpty else { return }
        try await db.transaction { connection in
            for key in keys {
                try connection.execute(
                    """
                    INSERT INTO search_turn (key, last_at) VALUES (?, ?)
                    ON CONFLICT (key) DO UPDATE SET last_at = excluded.last_at
                    """, [.text(key), SQLValue(now)])
            }
        }
    }

    // MARK: - Trimming

    /// Drops fetch log rows and runs older than `days`, and leads unseen for that long.
    public func trim(olderThan days: Int = 90, at now: Date = Date()) async throws {
        let cutoff = SQLValue(now.addingTimeInterval(-.days(Double(days))))
        try await db.transaction { connection in
            try connection.execute("DELETE FROM fetch_log WHERE at < ?", [cutoff])
            try connection.execute("DELETE FROM run WHERE started_at < ?", [cutoff])
            try connection.execute("DELETE FROM lead WHERE last_seen_at < ?", [cutoff])
        }
    }

    // MARK: - Rows

    static func run(_ row: Row) throws(SQLError) -> Run {
        Run(
            id: try row.uuid("id", table: "run"), kind: try row.value("kind", as: Run.Kind.self, table: "run"),
            startedAt: try row.requiredDate("started_at", table: "run"), finishedAt: row.date("finished_at"),
            stats: try row.json("stats", as: RunStats.self, table: "run") ?? RunStats(), error: row.string("error"))
    }

    static func entry(_ row: Row) -> FetchLogEntry? {
        guard let source = row.string("source_id").flatMap(UUID.init(uuidString:)), let at = row.date("at"),
            let outcome = row.optionalValue("outcome", as: FetchLogEntry.Outcome.self)
        else { return nil }
        return FetchLogEntry(
            runID: row.string("run_id").flatMap(UUID.init(uuidString:)), sourceID: source, at: at, outcome: outcome,
            httpStatus: row.int("http_status"), error: row.string("error"), requests: row.int("requests") ?? 0,
            items: row.int("items") ?? 0, added: row.int("added") ?? 0, changed: row.int("changed") ?? 0,
            closed: row.int("closed") ?? 0, milliseconds: row.int("ms") ?? 0)
    }
}
