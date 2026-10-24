import Foundation
import JobSources
import Screening
import Store
import Synchronization
import Testing

@testable import Pipeline

private let day0 = Date(timeIntervalSince1970: 1_790_000_000)

private let catalog = BoardCatalog(
    checked: "2026-10-23",
    boards: [
        .init(kind: "greenhouse", slug: "acmerobotics", name: "Acme Robotics", ca: 4, us: 10, jobs: 30),
        .init(kind: "lever", slug: "northline", name: "Northline", ca: 0, us: 3, jobs: 3),
        .init(kind: "smartrecruiters", slug: "MaplePay", name: "MaplePay", ca: 2, us: 0, jobs: 2),
        .init(kind: "ashby", slug: "rivet", name: "Rivet", ca: 1, us: 0, jobs: 1),
        .init(kind: "workday", slug: "bigbank", name: "Big Bank", ca: 50, us: 0, jobs: 50),
    ])

private func database() async throws -> Database {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    return db
}

/// A board that answers with a fixed result, counting how often it was asked.
private final class Board: JobSource, Sendable {
    let id: SourceID
    let result: Result<[Posting], SourceError>
    let asked = Mutex(0)

    init(id: SourceID, _ result: Result<[Posting], SourceError>) {
        self.id = id
        self.result = result
    }

    var listsEverything: Bool { true }

    func fetch(_ query: SourceQuery) async throws -> [Posting] {
        asked.withLock { $0 += 1 }
        return try result.get()
    }
}

/// Job collection v2, J5: Kairos's board catalog, watched.
@Suite("Board catalog")
struct CatalogWatchTests {
    /// The boards with jobs in your countries, of kinds Kairos reads; each a catalog source.
    @Test func theCatalogKeepsYourCountries() throws {
        #expect(catalog.boards(in: [.canada]).map(\.slug) == ["acmerobotics", "MaplePay", "rivet"])
        #expect(catalog.boards(in: [.canada, .unitedStates]).count == 4)
        let config = try #require(catalog.boards.first?.config)
        #expect(config == BoardConfig(slug: "acmerobotics", company: "Acme Robotics", origin: "catalog"))
        #expect(BoardConfig.key(kind: .greenhouse, slug: "AcmeRobotics") == "greenhouse|acmerobotics")
        #expect(BoardConfig.key(kind: .smartRecruiters, slug: "MaplePay") == "smartrecruiters|MaplePay")
        // The catalog that ships decodes.
        #expect(BoardCatalog.bundled.boards.allSatisfy { $0.sourceKind != nil })
    }

    /// Job sites and agencies that repost other companies' jobs stay out.
    @Test func jobSitesAndAgenciesStayOut() {
        let reposting = BoardCatalog(
            checked: "2026-10-24",
            boards: [
                .init(kind: "lever", slug: "jobgether", name: "Jobgether", ca: 333, us: 1_004, jobs: 4_147),
                .init(kind: "lever", slug: "aogarciaagency", name: "Aogarciaagency", ca: 159, us: 3_593, jobs: 3_752),
                .init(kind: "greenhouse", slug: "northstaff", name: "North Staffing Group", ca: 5, us: 0, jobs: 5),
                .init(kind: "greenhouse", slug: "clutch", name: "Clutch Technologies Inc.", ca: 76, us: 0, jobs: 76),
            ])
        #expect(reposting.boards(in: [.canada]).map(\.slug) == ["clutch"])
        #expect(BoardCatalog.isAggregator("Remote Rocketship") && !BoardCatalog.isAggregator("Stripe"))
    }

    /// Syncing adds what's missing once; a board you added yourself, removed or paused stays as you left it.
    @Test func syncAddsWhatsMissingAndRespectsYou() async throws {
        let db = try await database()
        let sources = SourceRepository(db)
        let mine = try await sources.add(
            kind: .greenhouse, config: BoardConfig(slug: "AcmeRobotics", company: "Acme").json)
        let removed = try await sources.add(kind: .ashby, config: BoardConfig(slug: "rivet").json)
        try await sources.tombstone(removed.id)
        let watch = CatalogWatch(catalog: catalog, countries: [.canada])
        #expect(try await watch.sync(db) == 1)
        #expect(try await watch.sync(db) == 0)
        let all = try await sources.sources()
        #expect(all.count == 2 && all.contains { $0.id == mine.id })
        let added = try #require(all.first { $0.kind == .smartRecruiters })
        #expect(BoardConfig.decode(added.config)?.origin == "catalog" && added.enabled)
    }

    /// A catalog board with nothing open for you rests three days between checks; a board answering
    /// "not found" three fetches in a row is gone, and isn't asked again.
    @Test func quietBoardsRestAndGoneBoardsStop() async throws {
        let db = try await database()
        let sources = SourceRepository(db)
        let quiet = try await sources.add(
            kind: .greenhouse, config: BoardConfig(slug: "quiet", origin: "catalog").json)
        let missing = try await sources.add(kind: .lever, config: BoardConfig(slug: "missing").json)
        let quietBoard = Board(id: quiet.id, .success([]))
        let missingBoard = Board(id: missing.id, .failure(.notFound(endpoint: "api.lever.co/v0/postings/missing")))
        func fetch(at date: Date) async -> FetchRun.Progress {
            let run = FetchRun(
                db: db, now: { date },
                makeSource: { source in (source.id == quiet.id ? quietBoard : missingBoard, SourceQuery()) })
            var last = FetchRun.Progress()
            for await progress in run.start() { last = progress }
            return last
        }
        for hour in 0..<3 { _ = await fetch(at: day0.addingTimeInterval(Double(hour) * 3_600)) }
        #expect(quietBoard.asked.withLock { $0 } == 1)
        #expect(missingBoard.asked.withLock { $0 } == 3)
        #expect(try await sources.source(missing.id)?.health == .gone)
        let later = await fetch(at: day0.addingTimeInterval(4 * 86_400))
        #expect(quietBoard.asked.withLock { $0 } == 2 && missingBoard.asked.withLock { $0 } == 3)
        #expect(later.sourcesTotal == 1)
        let rested = await fetch(at: day0.addingTimeInterval(4 * 86_400 + 60))
        #expect(rested.quiet == 1 && rested.sourcesTotal == 0)
        // An empty run doesn't bring a gone board back.
        _ = try await sources.recordRun(of: missing.id, found: 0, at: day0)
        #expect(try await sources.source(missing.id)?.health == .gone)
    }

    /// Watching the catalog is on, as the owner chose, and older settings read it as on.
    @Test func watchingIsOnByDefault() throws {
        #expect(SearchPreferences().watchCatalog)
        let old = try JSONDecoder().decode(SearchPreferences.self, from: Data(#"{"roles":["qa"]}"#.utf8))
        #expect(old.watchCatalog)
        var off = SearchPreferences()
        off.watchCatalog = false
        #expect(try JSONDecoder().decode(SearchPreferences.self, from: JSONEncoder().encode(off)).watchCatalog == false)
    }
}
