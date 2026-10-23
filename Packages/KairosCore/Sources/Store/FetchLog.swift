import Foundation

/// How a source answered last time on this Mac (`source_fetch_state`, local): what to send for
/// "only if it changed", and under which settings that answer was taken.
public struct SourceFetchState: Sendable, Equatable {
    public var etag: String?
    /// The settings in force when the ETag came. An answer taken under other settings (a longer
    /// "Posted" limit) may have left jobs out that now count, so it isn't reused.
    public var fingerprint: String?
    public var lastOKAt: Date?
    /// Fetches in a row that failed.
    public var failRuns: Int

    public init(etag: String? = nil, fingerprint: String? = nil, lastOKAt: Date? = nil, failRuns: Int = 0) {
        self.etag = etag
        self.fingerprint = fingerprint
        self.lastOKAt = lastOKAt
        self.failRuns = failRuns
    }
}

/// One request a fetch made (`fetch_log`, local, kept 30 days): for coverage, budgets and
/// explaining a source's failures.
public struct FetchLogEntry: Sendable, Equatable {
    public enum Outcome: String, Sendable, CaseIterable {
        case ok
        /// The source said nothing changed since last time (HTTP 304).
        case unchanged
        case failed
        /// Not asked: its plan's share for now was spent (a search's budget).
        case skipped
    }

    public var runID: UUID?
    public var sourceID: UUID
    public var at: Date
    /// "board", or a search and its page.
    public var request: String
    public var outcome: Outcome
    public var error: String?
    public var items = 0
    public var added = 0
    public var changed = 0
    public var closed = 0
    public var milliseconds = 0
    /// Requests it took: a search's pages each count.
    public var requests = 1

    public init(
        runID: UUID?, sourceID: UUID, at: Date, request: String, outcome: Outcome, error: String? = nil, items: Int = 0,
        added: Int = 0, changed: Int = 0, closed: Int = 0, milliseconds: Int = 0, requests: Int = 1
    ) {
        self.requests = requests
        self.runID = runID
        self.sourceID = sourceID
        self.at = at
        self.request = request
        self.outcome = outcome
        self.error = error
        self.items = items
        self.added = added
        self.changed = changed
        self.closed = closed
        self.milliseconds = milliseconds
    }
}

/// The local `source_fetch_state` and `fetch_log` tables.
public struct FetchLog: Sendable {
    public static let retentionDays = 30

    let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public func state(of source: UUID) async throws -> SourceFetchState {
        guard
            let row = try await db.query(
                "SELECT * FROM source_fetch_state WHERE source_id = ?", [.text(source.lowercased)]
            ).first
        else { return SourceFetchState() }
        return SourceFetchState(
            etag: row.string("etag"), fingerprint: row.string("fingerprint"),
            lastOKAt: row.int64("last_ok_at").map(Date.init(milliseconds:)), failRuns: row.int("fail_runs") ?? 0)
    }

    public func save(_ state: SourceFetchState, of source: UUID) async throws {
        try await db.execute(
            """
            INSERT INTO source_fetch_state (source_id, etag, fingerprint, last_ok_at, fail_runs) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (source_id) DO UPDATE SET etag = excluded.etag, fingerprint = excluded.fingerprint,
                last_ok_at = excluded.last_ok_at, fail_runs = excluded.fail_runs
            """,
            [
                .text(source.lowercased), SQLValue(state.etag), SQLValue(state.fingerprint), SQLValue(state.lastOKAt),
                SQLValue(state.failRuns),
            ])
    }

    /// Forgets every source's ETag, so the next fetch reads every board in full.
    public func forgetAnswers() async throws {
        try await db.execute("UPDATE source_fetch_state SET etag = NULL")
    }

    public func record(_ entry: FetchLogEntry) async throws {
        try await db.execute(
            """
            INSERT INTO fetch_log (run_id, source_id, at, request, outcome, error, items, added, changed, closed, ms,
                requests)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                SQLValue(entry.runID?.lowercased), .text(entry.sourceID.lowercased), SQLValue(entry.at),
                .text(entry.request), .text(entry.outcome.rawValue), SQLValue(entry.error), SQLValue(entry.items),
                SQLValue(entry.added), SQLValue(entry.changed), SQLValue(entry.closed), SQLValue(entry.milliseconds),
                SQLValue(entry.requests),
            ])
    }

    /// Requests made to `source` since `date`: what a plan's day, week or month has used.
    public func requests(of source: UUID, since date: Date) async throws -> Int {
        try await db.query(
            "SELECT coalesce(sum(requests), 0) AS n FROM fetch_log WHERE source_id = ? AND at >= ?",
            [.text(source.lowercased), SQLValue(date)]
        ).first?.int("n") ?? 0
    }

    /// A source's requests since `date`, newest first.
    public func entries(of source: UUID, since date: Date) async throws -> [FetchLogEntry] {
        try await db.query(
            "SELECT * FROM fetch_log WHERE source_id = ? AND at >= ? ORDER BY at DESC, id DESC",
            [.text(source.lowercased), SQLValue(date)]
        ).compactMap { row in
            guard let at = row.int64("at"), let outcome = row.string("outcome").flatMap(FetchLogEntry.Outcome.init)
            else { return nil }
            return FetchLogEntry(
                runID: row.string("run_id").flatMap(UUID.init(uuidString:)), sourceID: source,
                at: Date(milliseconds: at), request: row.string("request") ?? "", outcome: outcome,
                error: row.string("error"), items: row.int("items") ?? 0, added: row.int("added") ?? 0,
                changed: row.int("changed") ?? 0, closed: row.int("closed") ?? 0, milliseconds: row.int("ms") ?? 0,
                requests: row.int("requests") ?? 1)
        }
    }

    /// Rows older than `date` go (SPEC §6.2: 30 days).
    @discardableResult
    public func deleteOlder(than date: Date) async throws -> Int {
        try await db.transaction { connection in
            try connection.execute("DELETE FROM fetch_log WHERE at < ?", [SQLValue(date)])
            return connection.changes
        }
    }
}
