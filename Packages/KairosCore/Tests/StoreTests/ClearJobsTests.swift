import Foundation
import Testing

@testable import Store

private func insertBuild(for job: JobID, in db: Database) async throws {
    try await db.write { connection, stamp in
        try connection.execute(
            """
            INSERT INTO build (id, job_id, mode, master_version, status, created_at, updated_hlc)
            VALUES (?, ?, 'strict', 1, 'done', 0, ?)
            """, [.text(UUID.v7().lowercased), .text(job.rawValue), .text(stamp.hlc.description)])
    }
}

/// "Delete all jobs" (2026-10-22): a fresh start that keeps what you've engaged with, and lets the
/// next fetch bring back postings that are still up.
@Suite("Delete all jobs")
struct ClearJobsTests {
    @Test func itKeepsWhatYouEngagedWithAndForgetsTheRest() async throws {
        let db = try await migratedDatabase()
        let jobs = JobRepository(db)
        let plain = sampleJob(1)
        let skipped = sampleJob(2, state: .skipped)
        let saved = sampleJob(3, state: .shortlisted)
        let built = sampleJob(4)
        let applied = sampleJob(5)
        try await jobs.upsert([plain, skipped, saved, built, applied])
        try await insertBuild(for: built.id, in: db)
        try await ApplicationRepository(db).apply(job: applied.id, at: Date(milliseconds: 1_760_000_000_000))

        #expect(try await jobs.clearingPreview() == JobRepository.Clearing(deleted: 2, saved: 1, built: 1, applied: 1))
        #expect(try await jobs.clearAll() == 2)
        #expect(
            try await jobs.jobs().map(\.id).sorted { $0.rawValue < $1.rawValue }
                == [saved.id, built.id, applied.id].sorted { $0.rawValue < $1.rawValue })
        #expect(try await jobs.clearingPreview() == JobRepository.Clearing(deleted: 0, saved: 1, built: 1, applied: 1))

        // Cleared jobs aren't known, so the next fetch sees them as new; kept ones still are.
        #expect(try await jobs.knownIDs(among: [plain.id, skipped.id, saved.id]) == [saved.id])
    }

    /// A cleared job found again comes back fresh: no verdict, state new, no longer cleared.
    @Test func aClearedJobFoundAgainComesBackAsNew() async throws {
        let db = try await migratedDatabase()
        let jobs = JobRepository(db)
        var job = sampleJob(1, verdict: .no)
        try await jobs.upsert([job])
        try await jobs.clearAll()
        #expect(try await jobs.job(job.id) == nil)
        job.verdict = nil
        try await jobs.upsert([job])
        let back = try #require(try await jobs.job(job.id))
        #expect(back.state == .new && back.verdict == nil)
        #expect(try await jobs.knownIDs(among: [job.id]) == [job.id])
        let rows = try await db.query("SELECT cleared FROM job WHERE id = ?", [.text(job.id.rawValue)])
        #expect(rows.first?.int("cleared") == 0)
    }

    /// Retention's tombstones aren't cleared, so an old posting still up never returns.
    @Test func retentionTombstonesStayKnown() async throws {
        let db = try await migratedDatabase()
        let old = sampleJob(1, seenAt: 1_760_000_000_000)
        try await JobRepository(db).upsert([old])
        try await Retention(db).apply(now: Date(milliseconds: 1_760_000_000_000 + 130 * 86_400_000))
        #expect(try await JobRepository(db).knownIDs(among: [old.id]) == [old.id])
    }
}
