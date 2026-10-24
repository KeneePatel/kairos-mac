import Foundation

/// Where jobs come from (SPEC §5.4): company ATS boards, the Adzuna aggregator, or a page runner.
public enum SourceKind: String, Sendable, CaseIterable {
    case greenhouse, lever, ashby, adzuna
    case smartRecruiters = "smartrecruiters"
    case workable, recruitee, personio
    case bambooHR = "bamboohr"
    case teamtailor
    /// Remote jobs, searched (job collection v2, J7).
    case himalayas
    case linkedIn = "linkedin"
    case indeedCanada = "indeed_ca"
    case indeedUS = "indeed_us"
    case glassdoor
    case googleJobs = "google_jobs"
    case wellfound
    case jobBank = "job_bank"

    /// Searches across companies (Adzuna, the page runners) rather than one company's own board.
    /// Boards run first in a fetch, so their full postings win over a search's copy.
    public var isSearch: Bool { !Self.boards.contains(self) }

    /// Companies' own public job boards (SPEC §5.4, tier A; job collection v2, J2).
    public static let boards: Set<SourceKind> = [
        .greenhouse, .lever, .ashby, .smartRecruiters, .workable, .recruitee, .personio, .bambooHR, .teamtailor,
    ]

    /// Its descriptions are snippets, not the whole posting (Adzuna's API sends 500 characters).
    public var sendsSnippets: Bool { self == .adzuna }
}

public enum SourceHealth: String, Sendable, CaseIterable {
    case ok, degraded
    /// The board answered "not found" fetch after fetch: the company left that ATS or closed its
    /// board. It isn't fetched again until you resume it.
    case gone
}

/// One configured source (SPEC §6.2, `source`).
public struct Source: Sendable, Equatable, Identifiable {
    /// Runs in a row with no results before a source is marked degraded (SPEC §5.4).
    public static let degradedAfterEmptyRuns = 3

    public let id: UUID
    public var kind: SourceKind
    /// A JSON object; each source kind reads its own settings from it, such as a Greenhouse board token.
    public var config: String
    public var enabled: Bool
    public var lastRunAt: Date?
    public var health: SourceHealth
    public var emptyRuns: Int
    /// Set by the repository on every write.
    public internal(set) var updatedHLC: HLCTimestamp?

    public init(
        id: UUID, kind: SourceKind, config: String = "{}", enabled: Bool = true, lastRunAt: Date? = nil,
        health: SourceHealth = .ok, emptyRuns: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.config = config
        self.enabled = enabled
        self.lastRunAt = lastRunAt
        self.health = health
        self.emptyRuns = emptyRuns
    }
}

/// Reads and writes `source` rows, stamping a fresh HLC on every write.
public struct SourceRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// Creates a source with a new UUIDv7 id.
    public func add(kind: SourceKind, config: String = "{}", enabled: Bool = true) async throws -> Source {
        var source = Source(id: await db.newID(), kind: kind, config: config, enabled: enabled)
        source.updatedHLC = try await save(source)
        return source
    }

    /// Inserts the source, or replaces the stored one with the same id. A tombstoned source comes back.
    @discardableResult
    public func save(_ source: Source) async throws -> HLCTimestamp {
        let values: [SQLValue] = [
            .text(source.id.lowercased), SQLValue(source.kind), .text(source.config), SQLValue(source.enabled),
            SQLValue(source.lastRunAt), SQLValue(source.health), SQLValue(source.emptyRuns),
        ]
        return try await db.write { connection, stamp in
            try connection.execute(
                """
                INSERT INTO source (id, kind, config, enabled, last_run_at, health, empty_runs, updated_hlc, deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, config = excluded.config,
                    enabled = excluded.enabled, last_run_at = excluded.last_run_at, health = excluded.health,
                    empty_runs = excluded.empty_runs, updated_hlc = excluded.updated_hlc, deleted = 0
                """, values + [.text(stamp.hlc.description)])
            return stamp.hlc
        }
    }

    /// The source with `id`, unless it was deleted.
    public func source(_ id: UUID) async throws -> Source? {
        let rows = try await db.query("SELECT * FROM source WHERE id = ? AND deleted = 0", [.text(id.lowercased)])
        return try rows.first.map(Self.source)
    }

    /// Live sources in the order they were added.
    public func sources(enabledOnly: Bool = false) async throws -> [Source] {
        let sql = "SELECT * FROM source WHERE deleted = 0" + (enabledOnly ? " AND enabled = 1" : "") + " ORDER BY id"
        return try await db.query(sql).map(Self.source)
    }

    /// Every source ever added, removed ones too: so a catalog board you removed isn't added back.
    public func everySource() async throws -> [Source] {
        try await db.query("SELECT * FROM source ORDER BY id").map(Self.source)
    }

    /// Adds many sources in one transaction (the catalog's boards), each with a new UUIDv7 id.
    @discardableResult
    public func add(_ boards: [(kind: SourceKind, config: String)]) async throws -> Int {
        var made: [UUID] = []
        for _ in boards { made.append(await db.newID()) }
        let ids = made
        return try await db.write { connection, stamp in
            for (board, id) in zip(boards, ids) {
                try connection.execute(
                    "INSERT INTO source (id, kind, config, enabled, health, empty_runs, updated_hlc) VALUES (?, ?, ?, 1, 'ok', 0, ?)",
                    [.text(id.lowercased), SQLValue(board.kind), .text(board.config), .text(stamp.hlc.description)])
            }
            return boards.count
        }
    }

    /// Marks a board gone: it isn't fetched again until you resume it.
    public func markGone(_ id: UUID) async throws {
        guard var source = try await source(id) else { return }
        source.health = .gone
        try await save(source)
    }

    /// Records a finished run: when it ran, and whether it found anything. A source is degraded
    /// after `Source.degradedAfterEmptyRuns` empty runs in a row, and healthy again after any result.
    /// Returns nil if the source no longer exists.
    @discardableResult
    public func recordRun(of id: UUID, found count: Int, at date: Date) async throws -> Source? {
        guard var source = try await source(id) else { return nil }
        source.lastRunAt = date
        source.emptyRuns = count > 0 ? 0 : source.emptyRuns + 1
        if source.health != .gone {
            source.health = source.emptyRuns >= Source.degradedAfterEmptyRuns ? .degraded : .ok
        }
        source.updatedHLC = try await save(source)
        return source
    }

    /// Marks the source deleted, leaving a tombstone that can sync.
    @discardableResult
    public func tombstone(_ id: UUID) async throws -> HLCTimestamp {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE source SET deleted = 1, updated_hlc = ? WHERE id = ?",
                [.text(stamp.hlc.description), .text(id.lowercased)])
            return stamp.hlc
        }
    }

    private static func source(_ row: Row) throws(StoreError) -> Source {
        let r = RowReader(row: row, table: "source")
        var source = Source(
            id: try r.uuid("id"), kind: try r.value("kind", as: SourceKind.self), config: try r.string("config"),
            enabled: try r.bool("enabled"), lastRunAt: r.optionalDate("last_run_at"),
            health: try r.value("health", as: SourceHealth.self), emptyRuns: try r.int("empty_runs"))
        source.updatedHLC = try r.hlc("updated_hlc")
        return source
    }
}
