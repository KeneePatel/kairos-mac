import Foundation
import JobSources
import Store
import Testing

@testable import Pipeline

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func posting(_ source: SourceID, _ path: String, _ title: String) -> Posting {
    Posting(
        sourceID: source, url: URL(string: "https://jobs.example/\(path)")!, company: "Acme Robotics", title: title,
        location: "Toronto, ON", postedAt: now, descriptionHTML: "<p>\(title) work.</p>")
}

/// Job collection v2, J8: where jobs come from and how complete they are.
@Suite("Coverage report")
struct CoverageReportTests {
    @Test func itCountsSourcesJobsAndRequests() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let sources = SourceRepository(db)
        let mine = try await sources.add(kind: .greenhouse, config: BoardConfig(slug: "acme").json)
        var paused = try await sources.add(kind: .lever, config: BoardConfig(slug: "quiet", origin: "catalog").json)
        paused.enabled = false
        try await sources.save(paused)
        let adzuna = try await sources.add(kind: .adzuna)
        let ledger = ListingLedger(db)
        _ = try await ledger.record(
            [posting(mine.id, "1", "Backend Developer"), posting(mine.id, "2", "Data Engineer")], from: mine.id,
            kind: .greenhouse, complete: true, at: now)
        _ = try await ledger.record(
            [posting(adzuna.id, "a1", "QA Engineer")], from: adzuna.id, kind: .adzuna, complete: false, at: now)
        let log = FetchLog(db)
        try await log.record(
            FetchLogEntry(runID: nil, sourceID: mine.id, at: now, request: "board", outcome: .unchanged))
        try await log.record(
            FetchLogEntry(runID: nil, sourceID: adzuna.id, at: now, request: "search", outcome: .ok, requests: 12))
        for _ in 0..<2 {
            try await log.record(
                FetchLogEntry(
                    runID: nil, sourceID: paused.id, at: now, request: "board", outcome: .failed,
                    error: "The board wasn't found."))
        }

        let report = try await CoverageReport.load(from: db, now: now.addingTimeInterval(60))
        #expect(
            report.openJobs == [.full: 2, .snippet: 1] && report.newThisWeek == 3 && report.closedThisWeek == 0,
            "\(report.openJobs) new \(report.newThisWeek) closed \(report.closedThisWeek)")
        #expect(report.byOrigin == ["you": 1, "catalog": 1, "search engine": 1])
        let greenhouse = try #require(report.lines.first { $0.kind == .greenhouse })
        #expect(greenhouse.open == 2 && greenhouse.unchanged == 1 && greenhouse.requests == 1)
        #expect(report.lines.first { $0.kind == .adzuna }?.requests == 12)
        #expect(report.lines.first { $0.kind == .lever }.map { ($0.paused, $0.failed) } ?? (0, 0) == (1, 2))
        #expect(report.failures.first?.count == 2)
        #expect(report.text.contains("Open jobs: 3 (2 with the full posting, 1 snippets, 0 without text)"))
        #expect(report.text.contains("2 × The board wasn't found."))
    }
}
