import Foundation
import Testing

@testable import Store

@Suite("Job verdicts")
struct JobVerdictTests {
    /// Screening sets verdicts; yours (SPEC user story 4: "I can overrule it") is never overwritten.
    @Test func aVerdictIsSetButNeverOverYours() async throws {
        let db = try await migratedDatabase()
        let repo = JobRepository(db)
        let job = sampleJob(1)
        try await repo.upsert(job)
        #expect(try await repo.setVerdict(.yes, source: .analysis, rank: 212.5, for: job.id))
        let stored = try #require(try await repo.job(job.id))
        #expect(stored.verdict == .yes && stored.verdictSource == .analysis && stored.rank == 212.5)
        #expect(stored.updatedHLC != nil && stored.title == job.title && stored.state == .new)

        var mine = stored
        mine.verdict = .no
        mine.verdictSource = .user
        try await repo.upsert(mine)
        #expect(try await repo.setVerdict(.yes, source: .analysis, rank: 1, for: job.id) == false)
        #expect(try await repo.job(job.id)?.verdict == .no)
        // A job that isn't stored changes nothing.
        #expect(try await repo.setVerdict(.yes, source: .analysis, rank: 1, for: sampleJob(2).id) == false)
    }
}
