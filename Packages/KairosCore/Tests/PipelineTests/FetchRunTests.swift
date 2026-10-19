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
