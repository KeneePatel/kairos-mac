import Foundation
import Jobs
import KairosKit
import SQL

/// Company boards and searches.
public struct SourceRepository: Sendable {
    let db: Database

    static let table = "source"

    public func all() async throws -> [Source] {
        try await db.query("SELECT * FROM source ORDER BY kind, name COLLATE NOCASE, slug").map(Self.source)
    }

    public func source(_ id: UUID) async throws -> Source? {
        try await db.first("SELECT * FROM source WHERE id = ?", [.id(id)]).map(Self.source)
    }

    /// The board, whatever its status (a removed one too), or nil.
    public func board(kind: SourceKind, slug: String) async throws -> Source? {
        try await db.first(
            "SELECT * FROM source WHERE kind = ? AND slug = ?", [.text(kind.rawValue), .text(Self.slug(slug, kind))]
        )
        .map(Self.source)
    }

    /// The source for a search, made on first use.
    public func search(_ kind: SourceKind, at now: Date = Date()) async throws -> Source {
        if let existing = try await db.first(
            "SELECT * FROM source WHERE kind = ? AND slug = ''", [.text(kind.rawValue)])
        {
            return try Self.source(existing)
        }
        let source = Source(kind: kind, name: kind.displayName, origin: .search, addedAt: now)
        try await insert(source)
        return source
    }

    /// Adds `board` unless it's there already (whatever its status, so a removed board stays
    /// removed). Returns the new source, or nil when it was known.
    @discardableResult
    public func add(_ board: Board, origin: Source.Origin, at now: Date = Date()) async throws -> Source? {
        guard try await self.board(kind: board.kind, slug: board.slug) == nil else { return nil }
        let source = Source(
            kind: board.kind, slug: Self.slug(board.slug, board.kind), name: board.name, region: board.region,
            origin: origin,
            addedAt: now)
        try await insert(source)
        return source
    }

    /// Adds every board not yet known, in one transaction. Returns how many were added.
    @discardableResult
    public func add(_ boards: [Board], origin: Source.Origin, at now: Date = Date()) async throws -> Int {
        let sources = boards.map {
            Source(
                kind: $0.kind, slug: Self.slug($0.slug, $0.kind), name: $0.name, region: $0.region, origin: origin,
                addedAt: now)
        }
        return try await db.transaction { connection in
            var added = 0
            for source in sources {
                try connection.execute(Self.insertSQL + " ON CONFLICT (kind, slug) DO NOTHING", Self.values(source))
                added += connection.changes
            }
            return added
        }
    }

    /// You added it: it's watched again even if you'd removed it, and keeps the name you gave.
    public func addByYou(_ board: Board, at now: Date = Date()) async throws -> Source {
        if var existing = try await self.board(kind: board.kind, slug: board.slug) {
            existing.status = .watching
            existing.origin = .you
            if !board.name.isEmpty { existing.name = board.name }
            existing.missingStreak = 0
            existing.restUntil = nil
            try await save(existing)
            return existing
        }
        let source = Source(
            kind: board.kind, slug: Self.slug(board.slug, board.kind), name: board.name, region: board.region,
            origin: .you,
            addedAt: now)
        try await insert(source)
        return source
    }

    public func save(_ source: Source) async throws {
        try await db.execute(
            """
            UPDATE source SET name = ?, region = ?, origin = ?, status = ?, checked_at = ?, ok_at = ?, etag = ?,
                fail_streak = ?, missing_streak = ?, quiet_streak = ?, rest_until = ?, last_error = ?
            WHERE id = ?
            """,
            [
                .text(source.name), SQLValue(source.region), .text(source.origin.rawValue),
                .text(source.status.rawValue),
                SQLValue(source.checkedAt), SQLValue(source.okAt), SQLValue(source.etag), SQLValue(source.failStreak),
                SQLValue(source.missingStreak), SQLValue(source.quietStreak), SQLValue(source.restUntil),
                SQLValue(source.lastError), .id(source.id),
            ])
    }

    public func setStatus(_ status: Source.Status, for id: UUID) async throws {
        let resume = status == .watching
        try await db.execute(
            "UPDATE source SET status = ?, missing_streak = CASE WHEN ? THEN 0 ELSE missing_streak END, rest_until = CASE WHEN ? THEN NULL ELSE rest_until END WHERE id = ?",
            [.text(status.rawValue), SQLValue(resume), SQLValue(resume), .id(id)])
    }

    private func insert(_ source: Source) async throws {
        try await db.execute(Self.insertSQL, Self.values(source))
    }

    static let insertSQL = """
        INSERT INTO source (id, kind, slug, name, region, origin, status, added_at, checked_at, ok_at, etag, fail_streak,
            missing_streak, quiet_streak, rest_until, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    static func values(_ source: Source) -> [SQLValue] {
        [
            .id(source.id), .text(source.kind.rawValue), .text(source.slug), .text(source.name),
            SQLValue(source.region),
            .text(source.origin.rawValue), .text(source.status.rawValue), SQLValue(source.addedAt),
            SQLValue(source.checkedAt),
            SQLValue(source.okAt), SQLValue(source.etag), SQLValue(source.failStreak), SQLValue(source.missingStreak),
            SQLValue(source.quietStreak), SQLValue(source.restUntil), SQLValue(source.lastError),
        ]
    }

    /// The same board whatever the case of its slug; SmartRecruiters ids keep theirs.
    static func slug(_ slug: String, _ kind: SourceKind) -> String {
        kind == .smartRecruiters ? slug : slug.lowercased()
    }

    static func source(_ row: Row) throws(SQLError) -> Source {
        Source(
            id: try row.uuid("id", table: table), kind: try row.value("kind", as: SourceKind.self, table: table),
            slug: row.string("slug") ?? "", name: row.string("name") ?? "", region: row.string("region"),
            origin: try row.value("origin", as: Source.Origin.self, table: table),
            status: try row.value("status", as: Source.Status.self, table: table),
            addedAt: try row.requiredDate("added_at", table: table), checkedAt: row.date("checked_at"),
            okAt: row.date("ok_at"),
            etag: row.string("etag"), failStreak: row.int("fail_streak") ?? 0,
            missingStreak: row.int("missing_streak") ?? 0,
            quietStreak: row.int("quiet_streak") ?? 0, restUntil: row.date("rest_until"),
            lastError: row.string("last_error"))
    }
}
