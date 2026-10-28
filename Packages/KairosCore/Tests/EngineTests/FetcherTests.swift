import Engine
import Foundation
import Jobs
import KairosKit
import Screening
import Store
import TestKit
import Testing

let now = isoDate("2026-10-28T12:00:00Z")

func day(_ offset: Double) -> Date { now.addingTimeInterval(.days(offset)) }

/// A store whose preferences look for software roles, catalog off.
func softwareStore() async throws -> KairosStore {
    let store = try await KairosStore.inMemory()
    var preferences = SearchPreferences()
    preferences.roles = [.software]
    preferences.watchCatalog = false
    try await store.settings.set(SearchPreferences.storageKey, to: preferences, at: now)
    return store
}

@Suite("Fetch")
struct FetcherTests {
    static let light = "https://boards-api.greenhouse.io/v1/boards/acmerobotics/jobs"

    /// Greenhouse's light list (texts left out), with an ETag, and each posting's detail.
    static func greenhouse(etag: String = "W/\"v1\"") throws -> FakeHTTP {
        let page = try JSONValue(parsing: try Fixtures.data("boards/greenhouse_jobs.json"))
        let jobs = page["jobs"]?.arrayValue ?? []
        let lightJobs = jobs.map { job -> JSONValue in
            guard case .object(var fields) = job else { return job }
            fields["content"] = nil
            return .object(fields)
        }
        let list = JSONValue.object(["jobs": .array(lightJobs)]).text
        var details: [String: String] = [:]
        for job in jobs {
            if let id = job["id"]?.numberValue { details["\(Self.light)/\(Int(id))?pay_transparency=true"] = job.text }
        }
        let answers = details
        return FakeHTTP { request in
            let url = request.url.absoluteString
            if url == Self.light {
                if request.headers["If-None-Match"] == etag { return .status(304) }
                return .json(list, headers: ["ETag": etag])
            }
            return answers[url].map { .json($0) }
        }
    }

    static func options() -> Fetcher.Options {
        var options = Fetcher.Options()
        options.lookUpLeads = false
        options.catalog = BoardCatalog(checked: "", entries: [])
        return options
    }

    @Test func aFetchKeepsJobsAtYourRolesAndAnUnchangedBoardRepeatsItsAnswer() async throws {
        let store = try await softwareStore()
        let board = try await store.sources.addByYou(
            Board(kind: .greenhouse, slug: "acmerobotics", name: "Acme Robotics"), at: now)
        let http = try Self.greenhouse()
        let clock = ManualWallClock(now)
        let fetcher = Fetcher(store: store, http: http, keys: Readers.Keys(), clock: clock, options: Self.options())

        let first = try await fetcher.run()
        #expect(first.stats.found == 3 && first.stats.added == 1 && first.stats.otherRoles == 2)
        #expect(first.stats.sources == 1 && first.stats.failed == nil && first.error == nil)
        #expect(try await store.jobs.summaries().map(\.title) == ["Backend Engineer, Platform"])
        let read = try #require(try await store.sources.source(board.id))
        #expect(read.etag == "W/\"v1\"" && read.okAt == now && read.restUntil == nil)

        clock.advance(by: 3_600)
        let second = try await fetcher.run()
        #expect(second.stats.unchanged == 1 && second.stats.added == nil)
        #expect(http.requests.last?.headers["If-None-Match"] == "W/\"v1\"")
        #expect(try await store.activity.lastReads()[board.id]?.outcome == .unchanged)

        // New roles change what a fetch keeps: every board answers in full once.
        var preferences = try await store.settings.preferences()
        preferences.roles = [.software, .devops]
        try await store.settings.set(SearchPreferences.storageKey, to: preferences, at: now)
        let third = try await fetcher.run()
        #expect(third.stats.unchanged == nil && third.stats.added == 1)
        #expect(try await store.jobs.summaries().count == 2)
    }

    @Test func aBoardNotFoundThreeTimesIsGone() async throws {
        let store = try await softwareStore()
        let board = try await store.sources.addByYou(Board(kind: .lever, slug: "goneco", name: "Gone Co"), at: now)
        let http = FakeHTTP { _ in .status(404) }
        let fetcher = Fetcher(
            store: store, http: http, keys: Readers.Keys(), clock: ManualWallClock(now), options: Self.options())
        for _ in 1...3 {
            let run = try await fetcher.run()
            #expect(run.stats.failed == 1)
        }
        let gone = try #require(try await store.sources.source(board.id))
        #expect(gone.status == .gone && gone.missingStreak == 3 && gone.lastError != nil)
        // A gone board waits for you to resume it.
        let after = try await fetcher.run()
        #expect(after.stats.sources == 0)
    }

    @Test func aSearchWithoutItsKeyIsSkippedAndSnippetsBecomeLeads() async throws {
        let store = try await softwareStore()
        let google = try await store.sources.search(.googleJobs, at: now)
        _ = try await store.sources.search(.adzuna, at: now)
        let http = FakeHTTP { request in
            guard request.url.host() == "api.adzuna.com" else { return nil }
            if request.url.path().contains("/jobs/ca/search/1") { return try? .fixture("boards/adzuna_search_ca.json") }
            return .json(#"{"results":[]}"#)
        }
        var preferences = try await store.settings.preferences()
        preferences.countries = [.canada]
        try await store.settings.set(SearchPreferences.storageKey, to: preferences, at: now)
        let keys = Readers.Keys(adzuna: .init(appID: "id", appKey: "key"))
        let run = try await Fetcher(
            store: store, http: http, keys: keys, clock: ManualWallClock(now), options: Self.options()
        )
        .run()
        #expect(run.stats.searchesSkipped == 1)
        #expect(try await store.sources.source(google.id)?.lastError?.contains("SerpApi") == true)
        #expect((run.stats.leads ?? 0) > 0)
        #expect(run.stats.added == nil)
        #expect(try await store.jobs.summaries().isEmpty)
        #expect(try await store.activity.leads(since: day(-1)).count == run.stats.leads)
    }

    @Test func aCatalogBoardWithNothingForYouRests() async throws {
        let store = try await softwareStore()
        try await store.sources.add(
            [Board(kind: .greenhouse, slug: "acmerobotics", name: "Acme Robotics")], origin: .catalog, at: now)
        var preferences = try await store.settings.preferences()
        preferences.roles = [.qa]
        try await store.settings.set(SearchPreferences.storageKey, to: preferences, at: now)
        let clock = ManualWallClock(now)
        let fetcher = Fetcher(
            store: store, http: try Self.greenhouse(), keys: Readers.Keys(), clock: clock, options: Self.options())
        _ = try await fetcher.run()
        let rested = try #require(try await store.sources.all().first)
        #expect(rested.quietStreak == 1 && rested.restUntil == day(3))

        clock.set(day(1))
        let resting = try await fetcher.run()
        #expect(resting.stats.resting == 1 && resting.stats.sources == 0)
    }
}
