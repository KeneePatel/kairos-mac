import Foundation
import Screening
import Store
import Tailoring
import Testing

@testable import Pipeline

// Made-up postings: fixtures only.

private func migrated() async throws -> Database {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    return db
}

private func job(_ name: String) -> JobID { JobID(canonicalURL: "https://jobs.example.com/\(name)") }

private func posting(_ name: String) -> Job {
    Job(
        canonicalURL: "https://jobs.example.com/\(name)", sourceID: UUID(), url: "https://jobs.example.com/\(name)",
        dedupKey: "northline|\(name)|toronto", company: "Northline Freight", title: "Backend Developer",
        location: "Toronto, ON", region: "ON", country: .canada, remoteScope: .hybrid,
        descriptionMarkdown: "Go and PostgreSQL.", firstSeenAt: Date())
}

private let analysis = JobAnalysis(
    requirements: [.init(text: "Go", kind: .must, matchedSkill: "Go")], yearsRequired: nil, seniority: nil,
    domains: [],
    flags: .init(sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .hybrid))

@Suite struct BulkBuildTests {
    @Test func eachJobsLatestBuildIsItsNewestOneLeftStanding() async throws {
        let db = try await migrated()
        let builds = BuildRepository(db)
        let first = try await builds.create(job: job("a"), mode: .strict, masterVersion: 1)
        try await builds.fail(first, error: "Daily AI budget reached")
        let second = try await builds.create(job: job("a"), mode: .lite, masterVersion: 1)
        let other = try await builds.create(job: job("b"), mode: .strict, masterVersion: 1)

        var latest = try await builds.latestByJob()
        #expect(latest.count == 2)
        #expect(latest[job("a").rawValue]?.id == second)
        #expect(latest[job("b").rawValue]?.id == other)

        // A deleted build doesn't count: the one before it is the latest again.
        try await db.write { connection, _ in
            try connection.execute("UPDATE build SET deleted = 1 WHERE id = ?", [.text(second.lowercased)])
        }
        latest = try await builds.latestByJob()
        #expect(latest[job("a").rawValue]?.id == first)
        #expect(latest[job("a").rawValue]?.status == .failed)
    }

    @Test func onlyTheCurrentPromptsAnalysesCountAsAnalysed() async throws {
        let db = try await migrated()
        let jobs = JobRepository(db)
        let analyses = AnalysisRepository(db)
        for name in ["current", "stale", "none"] { try await jobs.upsert(posting(name)) }
        try await analyses.save(analysis, for: job("current"), model: "flash-lite", promptVersion: 2)
        try await analyses.save(analysis, for: job("stale"), model: "flash-lite", promptVersion: 1)

        #expect(try await analyses.analysedJobs(promptVersion: 2) == [job("current")])
        let current = try await analyses.analyses(promptVersion: 2)
        #expect(Array(current.keys) == [job("current")] && current[job("current")] == analysis)
    }

    @Test func aBulkBuildSkipsJobsWithAResumeOrNoAnalysis() {
        let plan = BulkBuild(
            candidates: [job("done"), job("failed"), job("never"), job("running"), job("queued"), job("unread")],
            latest: [
                job("done").rawValue: .done, job("failed").rawValue: .failed, job("running").rawValue: .running,
                job("queued").rawValue: .queued,
            ],
            analysed: [job("done"), job("failed"), job("never"), job("running"), job("queued")])

        // A failed build is built again; the list's order is kept.
        #expect(plan.jobs == [job("failed"), job("never")])
        #expect(plan.alreadyBuilt == 3)
        #expect(plan.notAnalysed == 1)
    }

    @Test func aBuildsCallsDependOnItsModeLetterAndSummary() {
        // Harvard writes no summary: experience, projects and skills, then up to 3 rewrite passes over
        // two sections.
        #expect(BulkBuild.calls(mode: .strict, coverLetter: false, summary: false) == 3...9)
        #expect(BulkBuild.calls(mode: .strict, coverLetter: true, summary: false) == 4...10)
        #expect(BulkBuild.calls(mode: .stretch, coverLetter: false, summary: false) == 3...10)
        // Lite copies your bullets: only the skills line, and the summary when there is one.
        #expect(BulkBuild.calls(mode: .lite, coverLetter: false, summary: false) == 1...1)
        #expect(BulkBuild.calls(mode: .lite, coverLetter: true, summary: true) == 3...3)

        let plan = BulkBuild(candidates: [job("a"), job("b")], latest: [:], analysed: [job("a"), job("b")])
        #expect(plan.calls(mode: .strict, coverLetter: false, summary: false) == 6...18)
        #expect(
            BulkBuild(candidates: [], latest: [:], analysed: []).calls(mode: .lite, coverLetter: false, summary: false)
                == 0...0)
    }
}
