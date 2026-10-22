import Foundation
import Testing

@testable import Store

private let now = Date(milliseconds: 1_790_000_000_000)
private func daysAgo(_ days: Int64) -> Int64 { now.milliseconds - days * 86_400_000 }

/// A job first seen `days` ago.
private func job(_ n: Int, seen days: Int64, state: JobState = .new) -> Job {
    sampleJob(n, state: state, seenAt: daysAgo(days))
}

private func insertBuild(for job: JobID, in db: Database) async throws {
    try await db.write { connection, stamp in
        try connection.execute(
            """
            INSERT INTO build (id, job_id, mode, master_version, status, created_at, updated_hlc)
            VALUES (?, ?, 'strict', 1, 'done', 0, ?)
            """, [.text(UUID.v7().lowercased), .text(job.rawValue), .text(stamp.hlc.description)])
    }
}

/// SPEC §6.5, T46: jobs you never engaged with leave at 60 and 120 days; everything else stays.
@Suite("Retention")
struct RetentionTests {
    @Test func untouchedJobsAreArchivedThenRemoved() async throws {
        let db = try await migratedDatabase()
        let jobs = JobRepository(db)
        let fresh = job(1, seen: 30)
        let stale = job(2, seen: 70)
        let skipped = job(3, seen: 70, state: .skipped)
        let old = job(4, seen: 130)
        let archived = job(5, seen: 125, state: .archived)
        let saved = job(6, seen: 130, state: .shortlisted)
        let applied = job(7, seen: 130)
        let built = job(8, seen: 130)
        try await jobs.upsert([fresh, stale, skipped, old, archived, saved, applied, built])
        try await ApplicationRepository(db).apply(job: applied.id, at: Date(milliseconds: daysAgo(100)))
        try await insertBuild(for: built.id, in: db)
        // The old job's analysis and screening trail go with it.
        try await AnalysisLikeRows.insert(for: old.id, in: db)

        let outcome = try await Retention(db).apply(now: now)
        #expect(outcome == Retention.Outcome(archived: 2, removed: 2))
        let left = Dictionary(uniqueKeysWithValues: try await jobs.jobs().map { ($0.id, $0.state) })
        #expect(left[fresh.id] == .new && left[stale.id] == .archived && left[skipped.id] == .archived)
        #expect(left[old.id] == nil && left[archived.id] == nil)
        #expect(left[saved.id] == .shortlisted && left[applied.id] == .applied && left[built.id] == .new)
        #expect(try await AnalysisLikeRows.live(for: old.id, in: db) == 0)
        // Tombstones stay known, so the same posting isn't added back as new.
        #expect(try await jobs.knownIDs(among: [old.id, archived.id]) == [old.id, archived.id])

        #expect(try await Retention(db).apply(now: now) == Retention.Outcome())  // nothing left to do
    }

    @Test func aCleanDatabaseHasNoFindings() async throws {
        let db = try await migratedDatabase()
        let job = sampleJob(1)
        try await JobRepository(db).upsert([job])
        try await ApplicationRepository(db).apply(job: job.id, at: now)
        let report = try await Doctor(db).run()
        #expect(report.isClean && report.databaseBytes > 0)
    }

    /// A database from before the applications migration is checked for what it has.
    @Test func anOlderDatabaseIsCheckedForWhatItHas() async throws {
        let db = try await migratedDatabase()
        try await db.write { connection, _ in
            try connection.execute("DROP TABLE application_event")
            try connection.execute("DROP TABLE application")
        }
        #expect(try await Doctor(db).run().isClean)
    }

    /// Rows pointing at something that's gone, and build files missing from disk, are reported;
    /// nothing is changed.
    @Test func orphansAndMissingFilesAreReported() async throws {
        let db = try await migratedDatabase()
        let gone = JobID(rawValue: "gone")
        try await AnalysisLikeRows.insert(for: gone, in: db)
        try await insertBuild(for: gone, in: db)
        try await db.write { connection, stamp in
            let hlc = SQLValue.text(stamp.hlc.description)
            try connection.execute(
                "INSERT INTO artifact (id, build_id, kind, sha256, local_path, updated_hlc) VALUES ('a1', 'no-build', 'resume', 'x', '/nowhere/a.pdf', ?)",
                [hlc])
            try connection.execute(
                "INSERT INTO application_event (id, application_id, kind, at, updated_hlc) VALUES ('e1', 'no-app', 'note', 0, ?)",
                [hlc])
        }
        let report = try await Doctor(db).run(fileExists: { _ in false })
        #expect(
            report.findings.map(\.problem) == [
                "Analyses of jobs that are gone", "Screening records of jobs that are gone",
                "Builds of jobs that are gone",
                "Build files whose build is gone", "Timeline lines of applications that are gone",
                "Build files missing from disk",
            ])
        #expect(report.findings.allSatisfy { $0.count == 1 } && !report.isClean)
        let stillThere = try await db.query("SELECT COUNT(*) AS n FROM screening WHERE deleted = 0")
        #expect(stillThere.first?.int("n") == 1)  // reported, not removed
    }
}

/// An analysis and a screening record for a job, written directly, as screening would.
private enum AnalysisLikeRows {
    static func insert(for job: JobID, in db: Database) async throws {
        try await db.write { connection, stamp in
            let hlc = SQLValue.text(stamp.hlc.description)
            try connection.execute(
                """
                INSERT INTO job_analysis
                    (job_id, requirements, flags, domains, model, prompt_version, analyzed_at, updated_hlc)
                VALUES (?, '[]', '{}', '[]', 'flash-lite', 2, 0, ?)
                """, [.text(job.rawValue), hlc])
            try connection.execute(
                """
                INSERT INTO screening (id, job_id, stage, verdict, coverage, reasons, at, updated_hlc)
                VALUES (?, ?, 'analysis', 'no', '{}', '[]', 0, ?)
                """, [.text(UUID.v7().lowercased), .text(job.rawValue), hlc])
        }
    }

    static func live(for job: JobID, in db: Database) async throws -> Int {
        let rows = try await db.query(
            """
            SELECT (SELECT COUNT(*) FROM job_analysis WHERE job_id = ?1 AND deleted = 0)
                 + (SELECT COUNT(*) FROM screening WHERE job_id = ?1 AND deleted = 0) AS n
            """, [.text(job.rawValue)])
        return rows.first?.int("n") ?? -1
    }
}
