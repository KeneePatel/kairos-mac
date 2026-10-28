import AI
import Engine
import Foundation
import Jobs
import KairosKit
import Resume
import Screening
import Store
import TestKit
import Testing

@Suite("Screening runs")
struct ScreenerTests {
    /// Three jobs at Northline Freight: a backend role, a sales role, and the backend role posted again
    /// for Vancouver ("copy").
    static func store() async throws -> (KairosStore, [String: String]) {
        let store = try await softwareStore()
        try await store.resume.replace(with: Sample.resume, reason: "Test", at: now)
        let board = try await store.sources.addByYou(
            Board(kind: .greenhouse, slug: "northline", name: "Northline"), at: now)
        func listing(_ id: Int, _ title: String) -> Listing {
            let url = "https://job-boards.greenhouse.io/northline/jobs/\(id)"
            return Listing(
                canonicalURL: url, url: url, company: "Northline Freight", title: title, location: "Toronto, ON",
                city: "Toronto", region: "ON", country: .canada, remoteScope: .hybrid,
                description: "We move freight with Go, PostgreSQL and Kafka. Three years of backend work.")
        }
        _ = try await store.ledger.record(
            [listing(1, "Backend Developer"), listing(2, "Account Executive")], from: board, complete: false, at: now)
        let google = try await store.sources.search(.googleJobs, at: now)
        let copy = Listing(
            canonicalURL: "https://careers.example.com/northline/77", url: "https://careers.example.com/northline/77",
            company: "Northline Freight Inc.", title: "Backend Developer", location: "Vancouver, BC", city: "Vancouver",
            region: "BC", country: .canada, description: "Copy.")
        _ = try await store.ledger.record([copy], from: google, complete: false, at: now.addingTimeInterval(60))
        var ids: [String: String] = [:]
        for job in try await store.jobs.summaries() {
            ids[job.placeLine.contains("Vancouver") ? "copy" : job.title] = job.id
        }
        return (store, ids)
    }

    static func analysis() throws -> ScriptedChat.Reply {
        .json(try Fixtures.text("screening/analyzeJob-gemini-flash-lite-latest.json"))
    }

    @Test func theFiltersRunFirstThenTheAIAndAStoredAnalysisIsReused() async throws {
        let (store, ids) = try await Self.store()
        let chat = ScriptedChat()
        chat.always(.analyzeJob, try Self.analysis())
        let screener = Screener(store: store, router: scriptedRouter(chat), clock: ManualWallClock(now))

        let run = try await screener.run()
        #expect(run.stats.filtered == 1 && run.stats.judged == 2 && run.stats.aiCalls == 2 && run.error == nil)
        let salesID = try #require(ids["Account Executive"])
        let backendID = try #require(ids["Backend Developer"])
        let sales = try #require(try await store.screening.state(for: salesID))
        #expect(sales.stage == .filtered && sales.filterRule == .titleInclude)
        let backend = try #require(try await store.screening.state(for: backendID))
        #expect(backend.stage == .judged && backend.verdict != nil && backend.coverage != nil && backend.rank != nil)
        #expect(chat.calls(.analyzeJob).count == 2)

        // Nothing new: nothing to do.
        #expect(try await screener.run().stats.screened == 0)
        // Judging everything again reuses the stored analyses: no new calls.
        let again = try await screener.run(.everything)
        #expect(again.stats.judged == 2 && again.stats.filtered == 1)
        #expect(chat.calls(.analyzeJob).count == 2)
    }

    @Test func withoutAIJobsWaitAndAStopLeavesTheRestWaiting() async throws {
        let (store, ids) = try await Self.store()
        let alone = try await Screener(store: store, router: nil, clock: ManualWallClock(now)).run()
        #expect(alone.stats.waiting == 2 && alone.stats.filtered == 1 && alone.stats.stopped == true)
        let backendID = try #require(ids["Backend Developer"])
        #expect(try await store.screening.state(for: backendID)?.stage == .waiting)

        let chat = ScriptedChat()
        chat.always(.analyzeJob, .error(.keyRejected(provider: "p")))
        let rejected = try await Screener(store: store, router: scriptedRouter(chat), clock: ManualWallClock(now)).run()
        #expect(rejected.stats.waiting == 2 && rejected.error?.contains("rejected") == true)
        #expect(chat.calls(.analyzeJob).count <= 2)
    }

    @Test func aJobYouBringBackIsJudgedAndApplyingRetiresItsCopies() async throws {
        let (store, ids) = try await Self.store()
        let chat = ScriptedChat()
        chat.always(.analyzeJob, try Self.analysis())
        let screener = Screener(store: store, router: scriptedRouter(chat), clock: ManualWallClock(now))
        _ = try await screener.run()

        let sales = try #require(ids["Account Executive"])
        guard case .judged = try await screener.bringBack(sales) else {
            Issue.record("a job brought back is judged")
            return
        }
        #expect(try await store.screening.state(for: sales)?.broughtBack == true)
        // The filters never drop it again.
        _ = try await screener.run(.everything)
        #expect(try await store.screening.state(for: sales)?.stage == .judged)

        let backend = try #require(ids["Backend Developer"])
        try await store.applications.apply(Application(jobID: backend, appliedAt: now))
        #expect(try await screener.retireCopies(of: backend) == 1)
        let copyID = try #require(ids["copy"])
        let copy = try #require(try await store.screening.state(for: copyID))
        #expect(copy.filterRule == .alreadyApplied)
    }

    @Test func reevaluatingAsksAgainAndNeverReusesTheStoredAnalysis() async throws {
        let (store, ids) = try await Self.store()
        let chat = ScriptedChat()
        chat.always(.analyzeJob, try Self.analysis())
        let screener = Screener(store: store, router: scriptedRouter(chat), clock: ManualWallClock(now))
        _ = try await screener.run()
        let backend = try #require(ids["Backend Developer"])
        guard case .judged = try await screener.reevaluate(backend) else {
            Issue.record("re-evaluating judges the job")
            return
        }
        #expect(chat.calls(.analyzeJob).count == 3)
        let salesID = try #require(ids["Account Executive"])
        guard case .filtered(.titleInclude) = try await screener.reevaluate(salesID) else {
            Issue.record("the filters run first")
            return
        }
    }
}
