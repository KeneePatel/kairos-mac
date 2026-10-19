import Foundation
import JobSources
import Store
import Testing

@testable import Pipeline

/// One real company on each ATS, end to end through the real network (SPEC §11, "Live smoke").
/// Off by default: run with `KAIROS_LIVE=1 swift test --filter LiveSmokeTests`.
@Suite("Live smoke", .enabled(if: ProcessInfo.processInfo.environment["KAIROS_LIVE"] == "1", "Set KAIROS_LIVE=1"))
struct LiveSmokeTests {
    @Test func fetchesOneRealCompanyFromEachBoard() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let sources = SourceRepository(db)
        for url in [
            "https://job-boards.greenhouse.io/gitlab", "https://jobs.lever.co/spotify", "https://jobs.ashbyhq.com/ramp",
        ] {
            guard case .detected(let kind, let slug) = ATSDetector.detect(url) else {
                Issue.record("not detected: \(url)")
                continue
            }
            _ = try await sources.add(kind: kind, config: BoardConfig(slug: slug).json)
        }
        let http = URLSessionHTTPClient()
        let run = FetchRun(db: db, makeSource: { try SourceFactory.make($0, http: http) })
        var last = FetchRun.Progress()
        for await progress in run.start() { last = progress }

        print(
            "live: \(last.found) found · \(last.outside) outside · \(last.duplicates) duplicates · \(last.added) added",
            last.failures.map(\.message))
        #expect(last.failures.isEmpty)
        #expect(last.found > 0 && last.added > 0)
        let jobs = try await JobRepository(db).jobs()
        let withCountry = jobs.filter { $0.country != nil }.count
        print("live: \(jobs.count) stored, \(withCountry) with a country")
        for job in jobs.prefix(12) {
            print(
                "  \(job.company) | \(job.title) | \(job.location) → \(job.country?.rawValue ?? "?") \(job.region ?? "") \(job.city ?? "") \(job.remoteScope.rawValue)"
            )
        }
        #expect(withCountry * 2 >= jobs.count)  // most stored jobs have a parsed country
    }
}
