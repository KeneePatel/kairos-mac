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

@Suite("Job verdicts: yours and re-screening")
struct JobOverruleTests {
    @Test func youCanOverruleAndSkipAJob() async throws {
        let db = try await migratedDatabase()
        let repo = JobRepository(db)
        let job = sampleJob(1)
        try await repo.upsert(job)
        try await repo.setVerdict(.no, source: .prefilter, rank: 20, for: job.id)
        try await repo.setUserVerdict(.yes, rank: 220, for: job.id)
        let mine = try #require(try await repo.job(job.id))
        #expect(mine.verdict == .yes && mine.verdictSource == .user && mine.rank == 220)

        try await repo.setState(.skipped, for: job.id)
        #expect(try await repo.job(job.id)?.state == .skipped)
        #expect(try await repo.job(job.id)?.verdict == .yes)  // the state change leaves the verdict alone
    }

    /// After you change your preferences: automatic verdicts on new jobs go, so they're screened
    /// again; yours and those on jobs you've acted on stay.
    @Test func clearingScreeningKeepsYourVerdicts() async throws {
        let db = try await migratedDatabase()
        let repo = JobRepository(db)
        try await repo.upsert([sampleJob(1), sampleJob(2), sampleJob(3), sampleJob(4, state: .applied)])
        try await repo.setVerdict(.no, source: .prefilter, rank: 20, for: sampleJob(1).id)
        try await repo.setVerdict(.yes, source: .analysis, rank: 220, for: sampleJob(2).id)
        try await repo.setUserVerdict(.maybe, rank: 120, for: sampleJob(3).id)
        try await repo.setVerdict(.yes, source: .analysis, rank: 220, for: sampleJob(4).id)

        #expect(try await repo.clearScreening() == 2)
        let jobs = try await repo.jobs().sorted { $0.title < $1.title }
        #expect(jobs.map(\.verdict) == [nil, nil, .maybe, .yes])
        #expect(jobs.map(\.rank) == [nil, nil, 120, 220])
    }
}
