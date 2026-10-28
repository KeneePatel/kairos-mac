import Foundation
import Jobs
import KairosKit
import SQL
import Screening

/// Which jobs a list asks for.
public enum JobScope: Sendable, Equatable {
    /// Every job not archived.
    case live
    /// Jobs retention archived.
    case archived
    case ids([String])
}

/// Jobs, their listings and their history. A fetch writes them through `ListingLedger`.
public struct JobRepository: Sendable {
    let db: Database

    static let table = "job"

    public func job(_ id: String) async throws -> Job? {
        try await db.first("SELECT * FROM job WHERE id = ?", [.text(id)]).map(Self.job)
    }

    /// Jobs with their posting text, in no particular order.
    public func jobs(_ ids: [String]) async throws -> [Job] {
        guard !ids.isEmpty else { return [] }
        return try await db.query("SELECT * FROM job WHERE id IN (SELECT value FROM json_each(?))", [try .json(ids)])
            .map(Self.job)
    }

    /// Jobs as lists show them, with their screening, latest build and application.
    public func summaries(_ scope: JobScope = .live) async throws -> [JobSummary] {
        var sql = Self.summarySQL
        var values: [SQLValue] = []
        switch scope {
        case .live: sql += " WHERE j.archived_at IS NULL"
        case .archived: sql += " WHERE j.archived_at IS NOT NULL"
        case .ids(let ids):
            guard !ids.isEmpty else { return [] }
            sql += " WHERE j.id IN (SELECT value FROM json_each(?))"
            values = [try .json(ids)]
        }
        return try await db.query(sql, values).map(Self.summary)
    }

    public func summary(_ id: String) async throws -> JobSummary? {
        try await summaries(.ids([id])).first
    }

    /// Everything about one job: its listings with their sources, its history, its analysis and
    /// where screening left it.
    public func detail(_ id: String) async throws -> JobDetail? {
        try await db.read { connection in
            guard let row = try connection.first("SELECT * FROM job WHERE id = ?", [.text(id)]) else { return nil }
            let listings = try connection.query(
                """
                SELECT l.id, l.source_id, l.url, l.first_seen_at, l.last_seen_at, l.closed_at, s.kind, s.name, s.slug
                FROM listing l LEFT JOIN source s ON s.id = l.source_id
                WHERE l.job_id = ? ORDER BY l.first_seen_at, l.id
                """, [.text(id)])
            let events = try connection.query("SELECT * FROM job_event WHERE job_id = ? ORDER BY at, id", [.text(id)])
            let analysis = try connection.first("SELECT * FROM analysis WHERE job_id = ?", [.text(id)])
            let screening = try connection.first("SELECT * FROM screening WHERE job_id = ?", [.text(id)])
            return JobDetail(
                job: try Self.job(row), listings: try listings.map(Self.listingRecord),
                events: try events.map(Self.event),
                analysis: try analysis.map(ScreeningRepository.analysis)?.analysis,
                screening: try screening.flatMap(ScreeningRepository.state))
        }
    }

    /// Saved or skipped, or neither.
    public func setDecision(_ decision: Job.Decision?, for id: String, at now: Date = Date()) async throws {
        try await db.execute(
            "UPDATE job SET decision = ?, decided_at = ?, updated_at = ? WHERE id = ?",
            [SQLValue(decision?.rawValue), decision == nil ? .null : SQLValue(now), SQLValue(now), .text(id)])
    }

    /// Canonical URLs of `source`'s open listings: a board that needs a request per job doesn't ask
    /// for their text again.
    public func knownURLs(of source: UUID) async throws -> Set<String> {
        Set(
            try await db.query(
                "SELECT canonical_url FROM listing WHERE source_id = ? AND closed_at IS NULL", [.id(source)]
            ).compactMap { $0.string("canonical_url") })
    }

    /// How many of `source`'s listings are open: a board with none has nothing for you lately.
    public func openListingCount(of source: UUID) async throws -> Int {
        try await db.first(
            "SELECT count(*) AS n FROM listing WHERE source_id = ? AND closed_at IS NULL", [.id(source)]
        )?.int("n") ?? 0
    }

    // MARK: - Clearing and retention

    /// Jobs you've acted on: saved, built a resume for, or applied to. Clearing and retention keep them.
    static let engaged = """
        (coalesce(decision, '') = 'saved' OR id IN (SELECT job_id FROM build)
            OR id IN (SELECT job_id FROM application))
        """

    /// What "Clear jobs" would delete, and what it keeps.
    public struct Clearing: Sendable, Equatable {
        public var deleted = 0
        public var saved = 0
        public var built = 0
        public var applied = 0

        public init(deleted: Int = 0, saved: Int = 0, built: Int = 0, applied: Int = 0) {
            self.deleted = deleted
            self.saved = saved
            self.built = built
            self.applied = applied
        }
    }

    public func clearingPreview() async throws -> Clearing {
        let row = try await db.first(
            """
            SELECT
              (SELECT count(*) FROM job WHERE NOT \(Self.engaged)) AS deleted,
              (SELECT count(*) FROM job WHERE decision = 'saved') AS saved,
              (SELECT count(*) FROM job WHERE id IN (SELECT job_id FROM build)
                  AND id NOT IN (SELECT job_id FROM application)) AS built,
              (SELECT count(*) FROM application) AS applied
            """)
        return Clearing(
            deleted: row?.int("deleted") ?? 0, saved: row?.int("saved") ?? 0, built: row?.int("built") ?? 0,
            applied: row?.int("applied") ?? 0)
    }

    /// "Clear jobs": deletes every job you haven't acted on, with its listings, history, analysis
    /// and screening. They aren't known any more, so the next fetch brings back the ones still
    /// posted, screened afresh. Returns how many were deleted.
    @discardableResult
    public func clear() async throws -> Int {
        try await db.transaction { connection in
            try connection.execute("DELETE FROM job WHERE NOT \(Self.engaged)")
            let deleted = connection.changes
            // A board answering "unchanged" would never send the deleted jobs again.
            try connection.execute("UPDATE source SET etag = NULL")
            return deleted
        }
    }

    /// What retention did.
    public struct Retained: Sendable, Equatable {
        public var archived = 0
        public var slimmed = 0

        public init(archived: Int = 0, slimmed: Int = 0) {
            self.archived = archived
            self.slimmed = slimmed
        }
    }

    /// Jobs you never acted on leave on their own: archived `archiveAfterDays` after Kairos first
    /// saw them, and slimmed at `slimAfterDays` (their text, analysis, screening and history go).
    /// The row and its listings stay, so a posting still up isn't added back as new.
    @discardableResult
    public func applyRetention(archiveAfterDays: Int = 60, slimAfterDays: Int = 120, at now: Date = Date()) async throws
        -> Retained
    {
        let archiveBefore = SQLValue(now.addingTimeInterval(-.days(Double(archiveAfterDays))))
        let slimBefore = SQLValue(now.addingTimeInterval(-.days(Double(slimAfterDays))))
        let time = SQLValue(now)
        return try await db.transaction { connection in
            try connection.execute(
                "UPDATE job SET archived_at = ?, updated_at = ? WHERE archived_at IS NULL AND first_seen_at < ? AND NOT \(Self.engaged)",
                [time, time, archiveBefore])
            let archived = connection.changes
            let going = "SELECT id FROM job WHERE archived_at IS NOT NULL AND description != '' AND first_seen_at < ?"
            for table in ["analysis", "screening", "job_event"] {
                try connection.execute("DELETE FROM \(table) WHERE job_id IN (\(going))", [slimBefore])
            }
            try connection.execute(
                "UPDATE job SET description = '', updated_at = ? WHERE id IN (\(going))", [time, slimBefore])
            return Retained(archived: archived, slimmed: connection.changes)
        }
    }

    /// Back in the lists: you opened an archived job and kept it.
    public func unarchive(_ id: String, at now: Date = Date()) async throws {
        try await db.execute(
            "UPDATE job SET archived_at = NULL, updated_at = ? WHERE id = ?", [SQLValue(now), .text(id)])
    }

    // MARK: - Rows

    static let summarySQL = """
        SELECT j.id, j.company, j.title, j.location, j.city, j.region, j.country, j.remote_scope, j.salary, j.posted_at,
            j.first_seen_at, j.closed_at, j.decision, j.source_kind, j.via,
            s.stage, s.verdict, s.rule, s.reasons, s.coverage, s.match, s.rank, s.your_verdict, s.brought_back,
            s.screened_at,
            b.id AS build_id, b.status AS build_status, b.score AS build_score,
            a.id AS application_id, a.status AS application_status
        FROM job j
        LEFT JOIN screening s ON s.job_id = j.id
        LEFT JOIN build b ON b.id = (SELECT id FROM build WHERE job_id = j.id ORDER BY created_at DESC, id DESC LIMIT 1)
        LEFT JOIN application a ON a.job_id = j.id
        """

    static func summary(_ row: Row) throws(SQLError) -> JobSummary {
        let id = try row.required("id", table: table)
        let company = row.string("company") ?? ""
        let title = row.string("title") ?? ""
        let country = row.optionalValue("country", as: Country.self)
        let remoteScope = row.optionalValue("remote_scope", as: RemoteScope.self) ?? .unknown
        let firstSeenAt = try row.requiredDate("first_seen_at", table: table)
        // The row's place line is the job's, worked out the same way.
        let place = Job(
            id: id, company: company, title: title, location: row.string("location") ?? "", city: row.string("city"),
            region: row.string("region"), country: country, remoteScope: remoteScope, url: "", firstSeenAt: firstSeenAt
        ).placeLine
        var build: JobSummary.BuildBrief?
        if let buildID = row.string("build_id").flatMap(UUID.init(uuidString:)),
            let status = row.optionalValue("build_status", as: BuildRecord.Status.self)
        {
            build = JobSummary.BuildBrief(id: buildID, status: status, score: row.double("build_score"))
        }
        var application: JobSummary.ApplicationBrief?
        if let applicationID = row.string("application_id").flatMap(UUID.init(uuidString:)),
            let status = row.optionalValue("application_status", as: Application.Status.self)
        {
            application = JobSummary.ApplicationBrief(id: applicationID, status: status)
        }
        return JobSummary(
            id: id, company: company, title: title, placeLine: place, country: country, remoteScope: remoteScope,
            salary: try row.json("salary", as: Salary.self, table: table), postedAt: row.date("posted_at"),
            firstSeenAt: firstSeenAt, closedAt: row.date("closed_at"),
            decision: row.optionalValue("decision", as: Job.Decision.self),
            sourceKind: row.optionalValue("source_kind", as: SourceKind.self), via: row.string("via"),
            screening: try ScreeningRepository.state(row), build: build, application: application)
    }

    static func job(_ row: Row) throws(SQLError) -> Job {
        Job(
            id: try row.required("id", table: table), company: row.string("company") ?? "",
            title: row.string("title") ?? "", location: row.string("location") ?? "", city: row.string("city"),
            region: row.string("region"), country: row.optionalValue("country", as: Country.self),
            remoteScope: row.optionalValue("remote_scope", as: RemoteScope.self) ?? .unknown,
            postedAt: row.date("posted_at"), description: row.string("description") ?? "",
            salary: try row.json("salary", as: Salary.self, table: table), url: row.string("url") ?? "",
            applyURL: row.string("apply_url"), via: row.string("via"),
            sourceKind: row.optionalValue("source_kind", as: SourceKind.self),
            primaryListingID: row.string("primary_listing_id"), dedupKey: row.string("dedup_key"),
            firstSeenAt: try row.requiredDate("first_seen_at", table: table), lastSeenAt: row.date("last_seen_at"),
            closedAt: row.date("closed_at"), decision: row.optionalValue("decision", as: Job.Decision.self),
            decidedAt: row.date("decided_at"), archivedAt: row.date("archived_at"))
    }

    static func listingRecord(_ row: Row) throws(SQLError) -> JobDetail.ListingRecord {
        let kind = row.optionalValue("kind", as: SourceKind.self)
        let name =
            row.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? row.string("slug").flatMap { $0.isEmpty ? nil : $0 }
        return JobDetail.ListingRecord(
            id: try row.required("id", table: "listing"), sourceID: try row.uuid("source_id", table: "listing"),
            sourceKind: kind,
            sourceName: (kind?.isBoard == false ? kind?.displayName : name) ?? kind?.displayName ?? "",
            url: row.string("url") ?? "", firstSeenAt: try row.requiredDate("first_seen_at", table: "listing"),
            lastSeenAt: try row.requiredDate("last_seen_at", table: "listing"), closedAt: row.date("closed_at"))
    }

    static func event(_ row: Row) throws(SQLError) -> JobEvent {
        JobEvent(
            kind: try row.value("kind", as: JobEvent.Kind.self, table: "job_event"),
            at: try row.requiredDate("at", table: "job_event"),
            sourceKind: row.optionalValue("source_kind", as: SourceKind.self), detail: row.string("detail"))
    }

    // MARK: - Inside a transaction

    static func insert(_ job: Job, at now: Date, in connection: Connection) throws {
        try connection.execute(
            """
            INSERT INTO job (id, company, title, location, city, region, country, remote_scope, salary, posted_at,
                description, url, apply_url, via, source_kind, primary_listing_id, dedup_key, first_seen_at, last_seen_at,
                closed_at, decision, decided_at, archived_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(job.id), .text(job.company), .text(job.title), .text(job.location), SQLValue(job.city),
                SQLValue(job.region), SQLValue(job.country?.rawValue), .text(job.remoteScope.rawValue),
                try .json(job.salary),
                SQLValue(job.postedAt), .text(job.description), .text(job.url), SQLValue(job.applyURL),
                SQLValue(job.via),
                SQLValue(job.sourceKind?.rawValue), .text(job.primaryListingID), .text(job.dedupKey),
                SQLValue(job.firstSeenAt), SQLValue(job.lastSeenAt), SQLValue(job.closedAt),
                SQLValue(job.decision?.rawValue), SQLValue(job.decidedAt), SQLValue(job.archivedAt), SQLValue(now),
            ])
    }

    static func job(_ id: String, in connection: Connection) throws -> Job? {
        try connection.first("SELECT * FROM job WHERE id = ?", [.text(id)]).map(job)
    }
}
