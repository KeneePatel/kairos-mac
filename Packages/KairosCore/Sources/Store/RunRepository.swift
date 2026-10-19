import Foundation

/// One pipeline run (SPEC §6.2, `run`). `stats` is a JSON object whose shape belongs to the run's kind.
public struct Run: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let stats: String
    public let error: String?
}

/// Records run history, stamping a fresh HLC on every write.
public struct RunRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// Starts a run now and returns its id.
    public func begin(kind: String) async throws -> UUID {
        let id = await db.newID()
        try await db.write { connection, stamp in
            try connection.execute(
                "INSERT INTO run (id, kind, started_at, updated_hlc) VALUES (?, ?, ?, ?)",
                [.text(id.lowercased), .text(kind), .integer(stamp.milliseconds), .text(stamp.hlc.description)])
        }
        return id
    }

    /// Ends the run now with its stats, and an error if it stopped short.
    public func finish(_ id: UUID, stats: String, error: String? = nil) async throws {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE run SET finished_at = ?, stats = ?, error = ?, updated_hlc = ? WHERE id = ?",
                [
                    .integer(stamp.milliseconds), .text(stats), SQLValue(error), .text(stamp.hlc.description),
                    .text(id.lowercased),
                ])
        }
    }

    /// The newest runs first.
    public func runs(kind: String? = nil, limit: Int = 20) async throws -> [Run] {
        var sql = "SELECT * FROM run WHERE deleted = 0"
        var values: [SQLValue] = []
        if let kind {
            sql += " AND kind = ?"
            values.append(.text(kind))
        }
        sql += " ORDER BY started_at DESC, id DESC LIMIT ?"
        values.append(SQLValue(limit))
        return try await db.query(sql, values).map { row throws(StoreError) in
            let r = RowReader(row: row, table: "run")
            return Run(
                id: try r.uuid("id"), kind: try r.string("kind"), startedAt: try r.date("started_at"),
                finishedAt: r.optionalDate("finished_at"), stats: try r.string("stats"), error: row.string("error"))
        }
    }
}
