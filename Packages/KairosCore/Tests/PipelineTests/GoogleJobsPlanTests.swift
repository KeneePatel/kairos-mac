import Foundation
import JobSources
import Store
import Synchronization
import Testing

@testable import Pipeline

private let day0 = Date(timeIntervalSince1970: 1_790_000_000)
private let toronto = Place(city: "Toronto", region: "Ontario", country: .canada)
private let halifax = Place(city: "Halifax", region: "Nova Scotia", country: .canada)

private struct TurnSource: JobSource {
    let id: SourceID
    let seen: @Sendable ([SearchTurn]) -> Void
    func fetch(_ query: SourceQuery) async throws -> [Posting] { [] }
    func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        seen(query.turns)
        return .postings([], memo: FetchMemo(etag: nil, requests: query.turns.count))
    }
}

/// Google Jobs's plan (job collection v3, C3): every role in every place and remote in each
/// country, the least recently searched first, the plan's share at a time.
@Suite("Google Jobs plan")
struct GoogleJobsPlanTests {
    @Test func everyPhraseInEveryPlaceAndRemoteInEachCountry() {
        let turns = GoogleJobsPlan.turns(
            phrases: ["software developer", "qa engineer"], places: [toronto, halifax], countries: [.canada])
        #expect(turns.count == 6)
        #expect(
            turns.map(\.key) == [
                "software developer|toronto|ontario|ca|CA", "software developer|halifax|nova scotia|ca|CA",
                "software developer|remote|CA", "qa engineer|toronto|ontario|ca|CA",
                "qa engineer|halifax|nova scotia|ca|CA",
                "qa engineer|remote|CA",
            ])
        #expect(turns[2].remote && turns[2].place == nil && turns[0].remote == false)
    }

    @Test func theLeastRecentlySearchedComeFirstAndComeRoundAgain() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let source = try await SourceRepository(db).add(kind: .googleJobs)
        let plan = GoogleJobsPlan(db)
        let all = GoogleJobsPlan.turns(
            phrases: ["software developer", "qa engineer"], places: [toronto, halifax], countries: [.canada])
        // Nothing searched yet: the plan's order, the share's worth.
        let first = try await plan.due(for: source.id, among: all, count: 4)
        #expect(first.map(\.key) == all.prefix(4).map(\.key))
        try await plan.mark(first, for: source.id, at: day0)
        // Next: the two never searched, then the oldest of the rest.
        let second = try await plan.due(for: source.id, among: all, count: 4)
        #expect(second.map(\.key) == [all[4].key, all[5].key, all[0].key, all[1].key])
        try await plan.mark(second, for: source.id, at: day0.addingTimeInterval(86_400))
        let third = try await plan.due(for: source.id, among: all, count: 2)
        #expect(third.map(\.key) == [all[2].key, all[3].key])
        #expect(try await plan.due(for: source.id, among: all, count: 0).isEmpty)
    }

    /// In a fetch: Google Jobs gets the day's share of turns, the ones searched are remembered, and
    /// the next day's fetch asks the never-searched one first.
    @Test func aFetchGivesGoogleJobsItsTurnsAndRemembersThem() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let google = try await SourceRepository(db).add(kind: .googleJobs)
        // Six of today's eight searches are spent already: two left.
        try await FetchLog(db).record(
            FetchLogEntry(runID: nil, sourceID: google.id, at: day0, request: "search", outcome: .ok, requests: 6))
        let seen = Mutex<[[SearchTurn]]>([])
        func run(at: Date) -> FetchRun {
            FetchRun(
                db: db, now: { at }, roles: RoleMatcher(families: [.software]), googlePhrases: ["software developer"],
                places: [toronto, halifax],
                makeSource: { source in
                    (
                        TurnSource(id: source.id) { turns in seen.withLock { $0.append(turns) } },
                        SourceQuery(countries: [.canada])
                    )
                })
        }
        for await _ in run(at: day0).start() {}
        for await _ in run(at: day0.addingTimeInterval(86_400)).start() {}
        let rounds = seen.withLock { $0 }
        #expect(rounds.count == 2 && rounds[0].count == 2 && rounds[1].count == 3)
        #expect(rounds[0].map(\.place?.city) == ["Toronto", "Halifax"])
        #expect(rounds[1].map { $0.place?.city ?? "remote" } == ["remote", "Toronto", "Halifax"])
        #expect(try await db.query("SELECT COUNT(*) AS n FROM search_turn").first?.int("n") == 3)
    }
}
