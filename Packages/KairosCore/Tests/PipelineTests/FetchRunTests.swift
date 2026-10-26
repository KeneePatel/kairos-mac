import Foundation
import JobSources
import Store
import Synchronization
import Testing

@testable import Pipeline

private struct FakeSource: JobSource {
    let id: SourceID
    let reply: @Sendable () async throws -> [Posting]
    func fetch(_ query: SourceQuery) async throws -> [Posting] { try await reply() }
}

private let seenAt = Date(timeIntervalSince1970: 1_760_000_000)

private func posting(_ source: SourceID, _ title: String, _ location: String, path: String) -> Posting {
    Posting(
        sourceID: source, url: URL(string: "https://jobs.example/\(path)")!, company: "Acme Robotics", title: title,
        location: location, postedAt: seenAt, descriptionHTML: "<p>\(title)</p>")
}

private func database() async throws -> Database {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    return db
}

/// Runs the fetch and returns every progress update, the last one being the outcome.
private func collect(_ run: FetchRun) async -> [FetchRun.Progress] {
    var updates: [FetchRun.Progress] = []
    for await progress in run.start() { updates.append(progress) }
    return updates
}

private func fetchRun(_ db: Database, maxConcurrent: Int = 4, _ replies: [UUID: FakeSource]) -> FetchRun {
    FetchRun(
        db: db, maxConcurrent: maxConcurrent, now: { seenAt },
        makeSource: { source in
            guard let fake = replies[source.id] else { throw SourceError.invalidConfiguration("no fake") }
            return (fake, SourceQuery())
        })
}

@Suite("Fetch run")
struct FetchRunTests {
    @Test func storesNewJobsAndDropsForeignPostingsAndCopies() async throws {
        let db = try await database()
        let sources = SourceRepository(db)
        let board = try await sources.add(kind: .greenhouse)
        let aggregator = try await sources.add(kind: .lever)
        let replies = [
            board.id: FakeSource(id: board.id) {
                [
                    posting(board.id, "Senior Backend Engineer", "Toronto, ON", path: "gh/1"),
                    posting(board.id, "Platform Engineer", "Berlin, Germany", path: "gh/2"),
                    posting(board.id, "Data Engineer", "New York, NY", path: "gh/3"),
                ]
            },
            aggregator.id: FakeSource(id: aggregator.id) {
                [
                    posting(aggregator.id, "Sr. Backend Engineer", "Toronto, Ontario", path: "lv/9"),  // a copy
                    posting(aggregator.id, "Mobile Developer", "Vancouver, BC", path: "lv/10"),
                ]
            },
        ]

        let updates = await collect(fetchRun(db, maxConcurrent: 1, replies))  // one at a time: a fixed order
        let last = try #require(updates.last)

        #expect(last.phase == .finished)
        #expect(last.sourcesTotal == 2 && last.sourcesDone == 2)
        #expect(last.found == 5 && last.outside == 1 && last.duplicates == 1 && last.added == 3)
        #expect(last.failures.isEmpty)
        #expect(updates.map(\.sourcesDone) == [0, 1, 2, 2])
        let titles = try await JobRepository(db).jobs().map(\.title).sorted()
        #expect(titles == ["Data Engineer", "Mobile Developer", "Senior Backend Engineer"])

        let run = try #require(try await RunRepository(db).runs(kind: "fetch").first)
        #expect(run.finishedAt != nil && run.error == nil)
        let stats = try JSONDecoder().decode(FetchRun.Stats.self, from: Data(run.stats.utf8))
        #expect(stats == FetchRun.Stats(sources: 2, failed: 0, found: 5, outside: 1, duplicates: 1, added: 3))
        #expect(try await sources.source(board.id)?.lastRunAt == seenAt)
    }

    @Test func aSecondFetchAddsOnlyWhatsNew() async throws {
        let db = try await database()
        let board = try await SourceRepository(db).add(kind: .ashby)
        let first = [board.id: FakeSource(id: board.id) { [posting(board.id, "Engineer", "Toronto, ON", path: "a/1")] }]
        _ = await collect(fetchRun(db, first))
        let second = [
            board.id: FakeSource(id: board.id) {
                [
                    posting(board.id, "Engineer", "Toronto, ON", path: "a/1"),
                    posting(board.id, "Designer", "Ottawa", path: "a/2"),
                ]
            }
        ]
        let last = try #require(await collect(fetchRun(db, second)).last)
        #expect(last.added == 1 && last.duplicates == 1)
        #expect(try await JobRepository(db).jobs().count == 2)
    }

    @Test func aFailingSourceIsReportedAndCountsAsAnEmptyRun() async throws {
        let db = try await database()
        let sources = SourceRepository(db)
        let broken = try await sources.add(kind: .greenhouse)
        let working = try await sources.add(kind: .lever)
        let replies = [
            broken.id: FakeSource(id: broken.id) { throw SourceError.notFound(endpoint: "boards-api.greenhouse.io/x") },
            working.id: FakeSource(id: working.id) { [posting(working.id, "Engineer", "Calgary, AB", path: "w/1")] },
        ]
        let last = try #require(await collect(fetchRun(db, replies)).last)
        #expect(
            last.failures == [
                FetchRun.Failure(sourceID: broken.id, message: SourceError.notFound(endpoint: "").message)
            ])
        #expect(last.added == 1)
        #expect(try await sources.source(broken.id)?.emptyRuns == 1)
        #expect(try await sources.source(working.id)?.emptyRuns == 0)
    }

    @Test func disabledSourcesAreSkipped() async throws {
        let db = try await database()
        let off = try await SourceRepository(db).add(kind: .greenhouse, enabled: false)
        let replies = [
            off.id: FakeSource(id: off.id) {
                Issue.record("fetched a disabled source")
                return []
            }
        ]
        let last = try #require(await collect(fetchRun(db, replies)).last)
        #expect(last.sourcesTotal == 0 && last.phase == .finished)
    }

    /// Your "posted within" limit applies while fetching: an older posting is never stored, a
    /// posting with no date is kept (its age can't be told), and the run says how many it skipped.
    @Test func postingsOlderThanYourLimitAreNeverStored() async throws {
        let db = try await database()
        let source = try await SourceRepository(db).add(kind: .lever)
        func dated(_ path: String, daysAgo: Double?) -> Posting {
            var posting = posting(source.id, "Engineer \(path)", "Toronto, ON", path: path)
            posting.postedAt = daysAgo.map { seenAt.addingTimeInterval(-$0 * 86_400) }
            return posting
        }
        let postings = [
            dated("fresh", daysAgo: 3), dated("edge", daysAgo: 7), dated("old", daysAgo: 10),
            dated("undated", daysAgo: nil),
        ]
        let replies = [source.id: FakeSource(id: source.id) { postings }]
        let run = FetchRun(
            db: db, now: { seenAt }, postedWithinDays: 7,
            makeSource: { source in
                guard let fake = replies[source.id] else { throw SourceError.invalidConfiguration("no fake") }
                return (fake, SourceQuery())
            })
        let last = try #require(await collect(run).last)
        #expect(last.found == 4 && last.tooOld == 1 && last.added == 3)
        #expect(
            try await JobRepository(db).jobs().map(\.title).sorted() == [
                "Engineer edge", "Engineer fresh", "Engineer undated",
            ])
        let stats = try #require(
            try await RunRepository(db).runs(kind: "fetch", limit: 1).first.flatMap { FetchRun.Stats.decode($0.stats) })
        #expect(stats.tooOld == 1)
    }

    /// T46: a fetch ends by retiring old jobs you never engaged with, and records how many.
    @Test func aFetchEndsByRetiringOldJobs() async throws {
        let db = try await database()
        let source = try await SourceRepository(db).add(kind: .lever)
        func job(_ name: String, seenDaysAgo days: Double) -> Job {
            Job(
                canonicalURL: "https://jobs.example/\(name)", sourceID: source.id, url: "https://jobs.example/\(name)",
                dedupKey: "acme robotics|\(name)|toronto", company: "Acme Robotics", title: name,
                firstSeenAt: seenAt.addingTimeInterval(-days * 86_400))
        }
        try await JobRepository(db).upsert([job("old", seenDaysAgo: 130), job("stale", seenDaysAgo: 70)])
        let last = try #require(
            await collect(fetchRun(db, [source.id: FakeSource(id: source.id) { [] }])).last)
        #expect(last.retired == Retention.Outcome(archived: 1, removed: 1))
        let stats = try #require(
            try await RunRepository(db).runs(kind: "fetch", limit: 1).first.flatMap { FetchRun.Stats.decode($0.stats) })
        #expect(stats.archived == 1 && stats.removed == 1)
        #expect(
            FetchRun.Stats.decode(#"{"sources":1,"failed":0,"found":0,"outside":0,"duplicates":0,"added":0}"#)?.archived
                == nil)
    }

    /// A search source (Adzuna) runs after every company board, so when both list a job the board's
    /// full posting is the one kept, however fast the search answers.
    /// A board Kairos reads behind a search result's links names a company to watch (v3, C1): it
    /// becomes a source in the same fetch, read right away, with the search as its origin.
    @Test func boardsBehindASearchsLinksAreWatchedAndReadNow() async throws {
        let db = try await database()
        let google = try await SourceRepository(db).add(kind: .googleJobs)
        let board = URL(string: "https://boards.greenhouse.io/acme/jobs/1")!
        let run = FetchRun(
            db: db, now: { seenAt },
            makeSource: { source in
                if source.id == google.id {
                    var found = posting(google.id, "Backend Developer", "Toronto, ON", path: "google/1")
                    found.url = URL(string: "https://ca.indeed.com/viewjob?jk=1")!
                    found.links = [board]
                    let reply = found
                    return (FakeSource(id: google.id, reply: { [reply] }), SourceQuery())
                }
                guard source.kind == .greenhouse else { throw SourceError.invalidConfiguration("unexpected") }
                var own = posting(source.id, "Backend Developer", "Toronto, ON", path: "gh/1")
                own.url = board
                let reply = own
                return (FakeSource(id: source.id, reply: { [reply] }), SourceQuery())
            })
        let outcome = try #require(await collect(run).last)
        #expect(outcome.boardsFound == 1 && outcome.sourcesTotal == 2 && outcome.sourcesDone == 2)
        let sources = try await SourceRepository(db).sources()
        let added = try #require(sources.first { $0.kind == .greenhouse })
        let config = try #require(BoardConfig.decode(added.config))
        #expect(config.slug == "acme" && config.company == "Acme Robotics" && config.origin == "google_jobs")
        // The board's copy of the posting attached to the job the search found.
        let listings = try await db.query("SELECT COUNT(*) AS n FROM listing WHERE deleted = 0").first?.int("n")
        #expect(try await JobRepository(db).jobs().count == 1 && listings == 2)
    }

    /// A search that sends snippets (Adzuna) gives leads, never jobs (v3, C2): company names at
    /// your roles, counted and kept 30 days; the Inbox sees none of them.
    @Test func snippetSearchesGiveLeadsNotJobs() async throws {
        let db = try await database()
        let adzuna = try await SourceRepository(db).add(kind: .adzuna)
        let run = FetchRun(
            db: db, now: { seenAt }, roles: RoleMatcher(families: [.software]),
            makeSource: { source in
                var developer = posting(source.id, "Backend Developer", "Toronto, ON", path: "ad/1")
                developer.url = URL(string: "https://www.adzuna.ca/land/ad/1")!
                var nurse = posting(source.id, "Registered Nurse", "Toronto, ON", path: "ad/2")
                nurse.url = URL(string: "https://www.adzuna.ca/land/ad/2")!
                let reply = [developer, nurse]
                return (FakeSource(id: source.id, reply: { reply }), SourceQuery())
            })
        let outcome = try #require(await collect(run).last)
        #expect(outcome.leads == 1 && outcome.otherRoles == 1 && outcome.added == 0 && outcome.found == 2)
        #expect(try await JobRepository(db).jobs().isEmpty)
        let leads = try await LeadRepository(db).leads()
        #expect(leads.map(\.company) == ["Acme Robotics"] && leads.first?.sourceID == adzuna.id)
        // The run's record says so, and a second fetch adds nothing.
        let stats = try await RunRepository(db).runs(kind: "fetch", limit: 1).first.flatMap {
            FetchRun.Stats.decode($0.stats)
        }
        #expect(stats?.leads == 1)
        #expect(try #require(await collect(run).last).leads == 0)
    }

    @Test func searchSourcesRunAfterTheBoards() async throws {
        let db = try await database()
        let sources = SourceRepository(db)
        let adzuna = try await sources.add(kind: .adzuna)
        let board = try await sources.add(kind: .greenhouse)
        let order = Mutex<[String]>([])
        let replies: [UUID: FakeSource] = [
            adzuna.id: FakeSource(id: adzuna.id) {
                order.withLock { $0.append("adzuna") }
                return [posting(adzuna.id, "Backend Developer", "Toronto, ON", path: "adzuna/1")]
            },
            board.id: FakeSource(id: board.id) {
                try await Task.sleep(for: .milliseconds(50))
                order.withLock { $0.append("board") }
                return [posting(board.id, "Backend Developer", "Toronto, ON", path: "board/1")]
            },
        ]
        let last = try #require(await collect(fetchRun(db, replies)).last)
        #expect(order.withLock { $0 } == ["board", "adzuna"])
        // Adzuna's copy is a lead now (v3, C2), not a duplicate.
        #expect(last.added == 1 && last.leads == 1 && last.sourcesDone == 2)
        #expect(try await JobRepository(db).jobs().map(\.sourceID) == [board.id])
    }

    @Test func noMoreThanTheLimitFetchAtOnce() async throws {
        let db = try await database()
        let gauge = Mutex((now: 0, peak: 0))
        var replies: [UUID: FakeSource] = [:]
        for _ in 0..<6 {
            let source = try await SourceRepository(db).add(kind: .lever)
            replies[source.id] = FakeSource(id: source.id) {
                gauge.withLock {
                    $0.now += 1
                    $0.peak = max($0.peak, $0.now)
                }
                try await Task.sleep(for: .milliseconds(20))
                gauge.withLock { $0.now -= 1 }
                return []
            }
        }
        let last = try #require(await collect(fetchRun(db, maxConcurrent: 2, replies)).last)
        #expect(last.sourcesDone == 6)
        #expect(gauge.withLock { $0.peak } == 2)
    }

    @Test func stoppingTheStreamCancelsTheRun() async throws {
        let db = try await database()
        let slow = try await SourceRepository(db).add(kind: .greenhouse)
        let replies = [
            slow.id: FakeSource(id: slow.id) {
                try await Task.sleep(for: .seconds(30))
                return [posting(slow.id, "Never stored", "Toronto, ON", path: "s/1")]
            }
        ]
        let consumer = Task {
            for await progress in fetchRun(db, replies).start() where progress.sourcesTotal == 1 {
                return  // leaving the loop ends the stream, which cancels the run
            }
        }
        await consumer.value

        var run: Run?
        for _ in 0..<200 {  // the run writes its last row after the cancellation lands
            run = try await RunRepository(db).runs(kind: "fetch").first
            if run?.finishedAt != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(run?.error == "cancelled")
        #expect(try await JobRepository(db).jobs().isEmpty)
    }
}
