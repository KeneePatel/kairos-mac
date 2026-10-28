import Foundation
import Jobs
import KairosKit
import SQL
import Screening

/// An analysis as stored: what the AI found, and which model and prompt found it.
public struct StoredAnalysis: Sendable, Equatable {
    public let analysis: JobAnalysis
    public let model: String
    public let promptVersion: Int
    public let analyzedAt: Date

    public init(analysis: JobAnalysis, model: String, promptVersion: Int, analyzedAt: Date) {
        self.analysis = analysis
        self.model = model
        self.promptVersion = promptVersion
        self.analyzedAt = analyzedAt
    }
}

/// Where screening left each job, and the AI's analyses.
public struct ScreeningRepository: Sendable {
    let db: Database

    static let table = "screening"

    /// Open jobs in the lists that screening hasn't seen yet: the prefilter's work, oldest first.
    public func unscreened() async throws -> [Job] {
        try await db.query(
            """
            SELECT * FROM job WHERE archived_at IS NULL AND closed_at IS NULL
                AND id NOT IN (SELECT job_id FROM screening) ORDER BY first_seen_at, id
            """
        ).map(JobRepository.job)
    }

    /// Open jobs that passed the filters and wait for the AI, newest first: the freshest postings
    /// are the ones worth deciding on soonest.
    public func waiting(limit: Int? = nil) async throws -> [Job] {
        try await db.query(
            """
            SELECT j.* FROM job j JOIN screening s ON s.job_id = j.id
            WHERE s.stage = 'waiting' AND j.archived_at IS NULL AND j.closed_at IS NULL
            ORDER BY j.first_seen_at DESC, j.id LIMIT ?
            """, [SQLValue(limit ?? -1)]
        ).map(JobRepository.job)
    }

    public func state(for jobID: String) async throws -> ScreeningState? {
        try await db.first("SELECT * FROM screening WHERE job_id = ?", [.text(jobID)]).flatMap(Self.state)
    }

    /// Records where screening left jobs. Your verdict and "brought back" stay as they are.
    public func record(_ states: [String: ScreeningState]) async throws {
        guard !states.isEmpty else { return }
        let rows = try states.map { id, state in try Self.values(state, for: id) }
        try await db.transaction { connection in
            for values in rows { try connection.execute(Self.upsertSQL, values) }
        }
    }

    public func record(_ state: ScreeningState, for jobID: String) async throws {
        try await record([jobID: state])
    }

    /// Your verdict, which wins over screening's from now on; nil takes it back.
    public func setYourVerdict(_ verdict: Verdict?, for jobID: String, at now: Date = Date()) async throws {
        try await db.execute(
            """
            INSERT INTO screening (job_id, stage, your_verdict, screened_at) VALUES (?, 'waiting', ?, ?)
            ON CONFLICT (job_id) DO UPDATE SET your_verdict = excluded.your_verdict
            """, [.text(jobID), SQLValue(verdict?.rawValue), SQLValue(now)])
    }

    /// "Bring back" from Filtered out: the filters never drop it again, and the AI judges it next.
    /// Returns whether it was filtered.
    @discardableResult
    public func bringBack(_ jobID: String, at now: Date = Date()) async throws -> Bool {
        try await db.transaction { connection in
            try connection.execute(
                """
                UPDATE screening SET stage = 'waiting', verdict = NULL, rule = NULL, reasons = '[]', coverage = NULL,
                    match = NULL, rank = NULL, brought_back = 1, screened_at = ?
                WHERE job_id = ? AND stage = 'filtered'
                """, [SQLValue(now), .text(jobID)])
            return connection.changes > 0
        }
    }

    /// The jobs a screening run looks at, with where screening left each. New jobs and jobs waiting
    /// for the AI; with `everything`, also every judged or filtered job you haven't acted on (no
    /// decision, no application, no verdict of yours), judged again in place.
    public func candidates(everything: Bool) async throws -> [(job: Job, state: ScreeningState?)] {
        let scope =
            everything
            ? """
            j.decision IS NULL AND j.id NOT IN (SELECT job_id FROM application) AND s.your_verdict IS NULL
            """ : "(s.job_id IS NULL OR s.stage = 'waiting')"
        return try await db.query(
            """
            SELECT j.*, s.stage, s.verdict, s.rule, s.reasons, s.coverage, s.match, s.rank, s.your_verdict,
                s.brought_back, s.screened_at
            FROM job j LEFT JOIN screening s ON s.job_id = j.id
            WHERE j.archived_at IS NULL AND j.closed_at IS NULL AND \(scope)
            ORDER BY j.first_seen_at, j.id
            """
        ).map { row in (try JobRepository.job(row), try Self.state(row)) }
    }

    // MARK: - Analyses

    public func analysis(for jobID: String) async throws -> StoredAnalysis? {
        try await db.first("SELECT * FROM analysis WHERE job_id = ?", [.text(jobID)]).map(Self.analysis)
    }

    public func analyses(for jobIDs: [String]) async throws -> [String: StoredAnalysis] {
        guard !jobIDs.isEmpty else { return [:] }
        var result: [String: StoredAnalysis] = [:]
        for row in try await db.query(
            "SELECT * FROM analysis WHERE job_id IN (SELECT value FROM json_each(?))", [try .json(jobIDs)])
        {
            if let id = row.string("job_id") { result[id] = try Self.analysis(row) }
        }
        return result
    }

    /// Stores an analysis and, in the same transaction, where it left the job.
    public func save(_ stored: StoredAnalysis, state: ScreeningState?, for jobID: String) async throws {
        let analysisValues: [SQLValue] = [
            .text(jobID), try .json(stored.analysis.requirements), try .json(stored.analysis.flags),
            try .json(stored.analysis.domains), SQLValue(stored.analysis.yearsRequired),
            SQLValue(stored.analysis.seniority?.rawValue), .text(stored.model), SQLValue(stored.promptVersion),
            SQLValue(stored.analyzedAt),
        ]
        let stateValues = try state.map { try Self.values($0, for: jobID) }
        try await db.transaction { connection in
            try connection.execute(
                """
                INSERT INTO analysis (job_id, requirements, flags, domains, years_required, seniority, model,
                    prompt_version, analyzed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (job_id) DO UPDATE SET requirements = excluded.requirements, flags = excluded.flags,
                    domains = excluded.domains, years_required = excluded.years_required, seniority = excluded.seniority,
                    model = excluded.model, prompt_version = excluded.prompt_version, analyzed_at = excluded.analyzed_at
                """, analysisValues)
            if let stateValues { try connection.execute(Self.upsertSQL, stateValues) }
        }
    }

    // MARK: - Counts

    /// Live open jobs by where screening left them, for the status line.
    public struct Counts: Sendable, Equatable {
        public var unscreened = 0
        public var filtered = 0
        public var waiting = 0
        public var yes = 0
        public var maybe = 0
        public var no = 0

        public init() {}
    }

    public func counts() async throws -> Counts {
        var counts = Counts()
        for row in try await db.query(
            """
            SELECT s.stage, coalesce(s.your_verdict, s.verdict) AS shown, count(*) AS n
            FROM job j LEFT JOIN screening s ON s.job_id = j.id
            WHERE j.archived_at IS NULL AND j.closed_at IS NULL GROUP BY s.stage, shown
            """)
        {
            let n = row.int("n") ?? 0
            switch (row.string("stage"), row.string("shown").flatMap(Verdict.init)) {
            case (nil, _): counts.unscreened += n
            case (_, .yes?): counts.yes += n
            case (_, .maybe?): counts.maybe += n
            case (_, .no?): counts.no += n
            case ("filtered"?, nil): counts.filtered += n
            default: counts.waiting += n
            }
        }
        return counts
    }

    /// Jobs you applied to, which the prefilter's "already applied" rule compares new jobs with.
    public func appliedJobs() async throws -> [AppliedJob] {
        try await db.query("SELECT j.company, j.title FROM application a JOIN job j ON j.id = a.job_id").compactMap {
            guard let company = $0.string("company"), let title = $0.string("title") else { return nil }
            return AppliedJob(company: company, title: title)
        }
    }

    // MARK: - Rows

    static let upsertSQL = """
        INSERT INTO screening (job_id, stage, verdict, rule, reasons, coverage, match, rank, screened_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (job_id) DO UPDATE SET stage = excluded.stage, verdict = excluded.verdict, rule = excluded.rule,
            reasons = excluded.reasons, coverage = excluded.coverage, match = excluded.match, rank = excluded.rank,
            screened_at = excluded.screened_at
        """

    static func values(_ state: ScreeningState, for jobID: String) throws -> [SQLValue] {
        [
            .text(jobID), .text(state.stage.rawValue), SQLValue(state.verdict?.rawValue), SQLValue(state.rule),
            try .json(state.reasons), try .json(state.coverage), SQLValue(state.match), SQLValue(state.rank),
            SQLValue(state.screenedAt),
        ]
    }

    /// The screening columns of a row, nil when the job has none (a LEFT JOIN with no match).
    static func state(_ row: Row) throws(SQLError) -> ScreeningState? {
        guard let stage = row.optionalValue("stage", as: ScreeningState.Stage.self) else { return nil }
        return ScreeningState(
            stage: stage, verdict: row.optionalValue("verdict", as: Verdict.self), rule: row.string("rule"),
            reasons: try row.json("reasons", as: [String].self, table: table) ?? [],
            coverage: try row.json("coverage", as: Coverage.self, table: table), match: row.double("match"),
            rank: row.double("rank"), yourVerdict: row.optionalValue("your_verdict", as: Verdict.self),
            broughtBack: row.bool("brought_back") ?? false,
            screenedAt: row.date("screened_at") ?? Date(timeIntervalSince1970: 0))
    }

    static func analysis(_ row: Row) throws(SQLError) -> StoredAnalysis {
        let table = "analysis"
        return StoredAnalysis(
            analysis: JobAnalysis(
                requirements: try row.json("requirements", as: [JobAnalysis.Requirement].self, table: table) ?? [],
                yearsRequired: row.int("years_required"), seniority: row.optionalValue("seniority", as: Seniority.self),
                domains: try row.json("domains", as: [String].self, table: table) ?? [],
                flags: try row.json("flags", as: JobAnalysis.Flags.self, table: table) ?? JobAnalysis.Flags()),
            model: row.string("model") ?? "", promptVersion: row.int("prompt_version") ?? 0,
            analyzedAt: try row.requiredDate("analyzed_at", table: table))
    }
}
