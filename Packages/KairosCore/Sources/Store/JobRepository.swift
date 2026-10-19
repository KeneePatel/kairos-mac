import Foundation

/// Which jobs to list. A nil set matches anything; an empty set matches nothing.
public struct JobFilter: Sendable, Equatable {
    public var states: Set<JobState>?
    public var verdicts: Set<Verdict>?
    public var countries: Set<Country>?
    public var limit: Int?

    public init(
        states: Set<JobState>? = nil, verdicts: Set<Verdict>? = nil, countries: Set<Country>? = nil,
        limit: Int? = nil
    ) {
        self.states = states
        self.verdicts = verdicts
        self.countries = countries
        self.limit = limit
    }
}

/// Reads and writes `job` rows. Every write stamps a fresh HLC, and deleting leaves a tombstone so
/// the deletion can sync (SPEC §6.1).
public struct JobRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// Inserts each job, or replaces the stored job with the same id, in one transaction. A job's
    /// first-seen time keeps the value first written, and a tombstoned job comes back.
    @discardableResult
    public func upsert(_ jobs: [Job]) async throws -> HLCTimestamp {
        let rows = try jobs.map(Self.values)
        return try await db.write { connection, stamp in
            for values in rows {
                try connection.execute(Self.upsertSQL, values + [.text(stamp.hlc.description)])
            }
            return stamp.hlc
        }
    }

    @discardableResult
    public func upsert(_ job: Job) async throws -> HLCTimestamp {
        try await upsert([job])
    }

    /// The job with `id`, unless it was deleted.
    public func job(_ id: JobID) async throws -> Job? {
        let rows = try await db.query("SELECT * FROM job WHERE id = ? AND deleted = 0", [.text(id.rawValue)])
        return try rows.first.map(Self.job)
    }

    /// Live jobs matching `filter`, best ranked first, then newest.
    public func jobs(matching filter: JobFilter = JobFilter()) async throws -> [Job] {
        var sql = "SELECT * FROM job WHERE deleted = 0"
        var values: [SQLValue] = []
        func constrain(_ column: String, to raw: [String]?) {
            guard let raw else { return }
            sql += " AND \(column) IN (\(Array(repeating: "?", count: raw.count).joined(separator: ", ")))"
            values += raw.sorted().map(SQLValue.text)
        }
        constrain("state", to: filter.states.map { $0.map(\.rawValue) })
        constrain("verdict", to: filter.verdicts.map { $0.map(\.rawValue) })
        constrain("country", to: filter.countries.map { $0.map(\.rawValue) })
        sql += " ORDER BY rank IS NULL, rank DESC, first_seen_at DESC, id"
        if let limit = filter.limit {
            sql += " LIMIT ?"
            values.append(SQLValue(limit))
        }
        return try await db.query(sql, values).map(Self.job)
    }

    /// Which of `ids` are already stored, tombstones included, so a fetch can skip known postings.
    public func knownIDs(among ids: [JobID]) async throws -> Set<JobID> {
        guard !ids.isEmpty else { return [] }
        var known: Set<JobID> = []
        // Batches stay well under SQLite's bound-parameter limit.
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = ids[start..<min(start + 500, ids.count)]
            let marks = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            let rows = try await db.query(
                "SELECT id FROM job WHERE id IN (\(marks))", batch.map { .text($0.rawValue) })
            known.formUnion(rows.compactMap { $0.string("id") }.map(JobID.init(rawValue:)))
        }
        return known
    }

    /// Marks the job deleted. The row stays as a tombstone, without its description, which a
    /// deleted job no longer needs.
    @discardableResult
    public func tombstone(_ id: JobID) async throws -> HLCTimestamp {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE job SET deleted = 1, description = NULL, updated_hlc = ? WHERE id = ?",
                [.text(stamp.hlc.description), .text(id.rawValue)])
            return stamp.hlc
        }
    }

    // MARK: - Row mapping

    private static let columns = [
        "id", "source_id", "url", "canonical_url", "dedup_key", "company", "title", "location", "city", "region",
        "country", "remote_scope", "currency", "salary", "posted_at", "description", "state", "verdict",
        "verdict_source", "rank", "first_seen_at", "updated_hlc",
    ]

    private static let upsertSQL: String = {
        let updates = columns.filter { $0 != "id" && $0 != "first_seen_at" }.map { "\($0) = excluded.\($0)" }
        return """
            INSERT INTO job (\(columns.joined(separator: ", ")), deleted)
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")), 0)
            ON CONFLICT (id) DO UPDATE SET \(updates.joined(separator: ", ")), deleted = 0
            """
    }()

    /// Every column but `updated_hlc`, which comes from the write's stamp.
    private static func values(_ job: Job) throws(StoreError) -> [SQLValue] {
        [
            .text(job.id.rawValue), .text(job.sourceID.lowercased), .text(job.url), .text(job.canonicalURL),
            .text(job.dedupKey), .text(job.company), .text(job.title), .text(job.location), SQLValue(job.city),
            SQLValue(job.region), SQLValue(job.country), SQLValue(job.remoteScope), SQLValue(job.currency),
            try SQLValue(json: job.salary), SQLValue(job.postedAt), SQLValue(job.descriptionMarkdown),
            SQLValue(job.state), SQLValue(job.verdict), SQLValue(job.verdictSource), SQLValue(job.rank),
            SQLValue(job.firstSeenAt),
        ]
    }

    private static func job(_ row: Row) throws(StoreError) -> Job {
        let r = RowReader(row: row, table: "job")
        let canonicalURL = try r.string("canonical_url")
        var job = Job(
            canonicalURL: canonicalURL, sourceID: try r.uuid("source_id"), url: try r.string("url"),
            dedupKey: try r.string("dedup_key"), company: try r.string("company"), title: try r.string("title"),
            location: try r.string("location"), city: row.string("city"), region: row.string("region"),
            country: try r.optionalValue("country", as: Country.self),
            remoteScope: try r.value("remote_scope", as: RemoteScope.self), currency: row.string("currency"),
            salary: try r.json("salary", as: Salary.self), postedAt: r.optionalDate("posted_at"),
            descriptionMarkdown: row.string("description"), state: try r.value("state", as: JobState.self),
            verdict: try r.optionalValue("verdict", as: Verdict.self),
            verdictSource: try r.optionalValue("verdict_source", as: VerdictSource.self), rank: row.double("rank"),
            firstSeenAt: try r.date("first_seen_at"))
        // The stored id must still be the hash of the stored URL; anything else is a damaged row.
        guard job.id.rawValue == row.string("id") else {
            throw .corruptRow(table: "job", id: job.id.rawValue, column: "id")
        }
        job.updatedHLC = try r.hlc("updated_hlc")
        return job
    }
}
