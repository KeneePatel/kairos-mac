import Foundation
import JobSources
import Store
import Synchronization
import Testing

@testable import Pipeline

private let day0 = Date(timeIntervalSince1970: 1_790_000_000)

private func posting(_ source: SourceID, _ path: String, _ title: String) -> Posting {
    Posting(
        sourceID: source, url: URL(string: "https://jobs.example/\(path)")!, company: "Acme Robotics", title: title,
        location: "Toronto, ON", postedAt: day0, descriptionHTML: "<p>\(title)</p>")
}

/// A company board: it lists everything it has open, answers "unchanged" to its last ETag, and
/// remembers what it was asked with.
private final class Board: JobSource, Sendable {
    let id: SourceID
    let answers: Mutex<[Result<FetchAnswer, SourceError>]>
    let asked = Mutex<[FetchMemo?]>([])

    init(id: SourceID, _ answers: [Result<FetchAnswer, SourceError>]) {
        self.id = id
        self.answers = Mutex(answers)
    }

    var listsEverything: Bool { true }

    func fetch(_ query: SourceQuery) async throws -> [Posting] { [] }

    func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        asked.withLock { $0.append(memo) }
        return try answers.withLock { $0.removeFirst() }.get()
    }
}

private func run(_ db: Database, _ board: Board, at date: Date, postedWithin: Int? = nil) async -> FetchRun.Progress {
    let fetch = FetchRun(
        db: db, now: { date }, postedWithinDays: postedWithin, makeSource: { _ in (board, SourceQuery()) })
    var last = FetchRun.Progress()
    for await progress in fetch.start() { last = progress }
    return last
}

/// A board that remembers what it was asked.
private final class Asked: JobSource, Sendable {
    let id: SourceID
    let queries = Mutex<[SourceQuery]>([])

    init(id: SourceID) { self.id = id }

    var listsEverything: Bool { true }

    func fetch(_ query: SourceQuery) async throws -> [Posting] {
        queries.withLock { $0.append(query) }
        return [posting(id, "1", "Backend Developer")]
    }
}

/// Job collection v2 inside a fetch: ETags, closing, failures and the fetch log.
@Suite("Fetch run: lifecycle")
struct FetchRunLifecycleTests {
    /// The second fetch asks with the first answer's ETag; "unchanged" keeps every job open and
    /// seen, and the board isn't counted as empty.
    @Test func anUnchangedBoardKeepsItsJobs() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let source = try await SourceRepository(db).add(kind: .greenhouse)
        let board = Board(
            id: source.id,
            [
                .success(.postings([posting(source.id, "1", "Backend Developer")], memo: FetchMemo(etag: "v1"))),
                .success(.unchanged), .success(.unchanged), .success(.unchanged),
            ])
        let first = await run(db, board, at: day0)
        #expect(first.added == 1 && first.unchanged == 0)
        let later = day0.addingTimeInterval(86_400)
        var last = FetchRun.Progress()
        for n in 1...3 { last = await run(db, board, at: later.addingTimeInterval(Double(n))) }
        #expect(last.unchanged == 1 && last.found == 0 && last.closed == 0)
        #expect(
            board.asked.withLock { $0 } == [nil, FetchMemo(etag: "v1"), FetchMemo(etag: "v1"), FetchMemo(etag: "v1")])
        let job = try #require(try await JobRepository(db).jobs().first)
        #expect(job.isOpen && job.lastSeenAt == later.addingTimeInterval(3))
        #expect(try await SourceRepository(db).source(source.id)?.health == .ok)
        let log = try await FetchLog(db).entries(of: source.id, since: .distantPast)
        #expect(log.map(\.outcome) == [.unchanged, .unchanged, .unchanged, .ok])
        #expect(log.last?.items == 1 && log.last?.added == 1)
        let stats = try #require(
            try await RunRepository(db).runs(kind: "fetch").first.flatMap { FetchRun.Stats.decode($0.stats) })
        #expect(stats.unchanged == 1)
    }

    /// Each board is told which of its jobs Kairos already has open, and your roles.
    @Test func boardsHearWhatsKnownAndYourRoles() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let source = try await SourceRepository(db).add(kind: .smartRecruiters)
        let board = Asked(id: source.id)
        let roles = RoleMatcher(families: [.software])
        for _ in 0..<2 {
            let fetch = FetchRun(db: db, now: { day0 }, roles: roles, makeSource: { _ in (board, SourceQuery()) })
            for await _ in fetch.start() {}
        }
        let queries = board.queries.withLock { $0 }
        #expect(queries.map(\.knownURLs) == [[], ["https://jobs.example/1"]])
        #expect(queries.allSatisfy { $0.roles == roles })
    }

    /// Adzuna gets what's left of its plan from the fetch log, and the time of its last good
    /// fetch; with nothing left it isn't asked, which isn't a failure.
    @Test func adzunaSpendsWhatsLeftOfItsPlan() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let source = try await SourceRepository(db).add(kind: .adzuna)
        let search = Asked(id: source.id)
        func fetch(at date: Date) async -> FetchRun.Progress {
            let run = FetchRun(db: db, now: { date }, makeSource: { _ in (search, SourceQuery(titles: ["x"])) })
            var last = FetchRun.Progress()
            for await progress in run.start() { last = progress }
            return last
        }
        _ = await fetch(at: day0)
        try await FetchLog(db).record(
            FetchLogEntry(runID: nil, sourceID: source.id, at: day0, request: "search", outcome: .ok, requests: 150))
        let later = day0.addingTimeInterval(3_600)
        _ = await fetch(at: later)
        let queries = search.queries.withLock { $0 }
        #expect(queries.first?.callBudget == 80 && queries.first?.since == nil)
        // 151 used today (one from the first fetch): 49 left.
        #expect(queries.last?.callBudget == 49 && queries.last?.since == day0)

        try await FetchLog(db).record(
            FetchLogEntry(runID: nil, sourceID: source.id, at: later, request: "search", outcome: .ok, requests: 60))
        let skipped = await fetch(at: later.addingTimeInterval(60))
        #expect(skipped.searchesSkipped == 1 && skipped.failures.isEmpty)
        #expect(search.queries.withLock { $0.count } == 2)
        #expect(try await FetchLog(db).entries(of: source.id, since: later).first?.outcome == .skipped)
    }

    /// An ETag taken under another "Posted" limit isn't used: the board is read in full.
    @Test func aNewPostedLimitReadsBoardsInFull() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let source = try await SourceRepository(db).add(kind: .lever)
        let answer = FetchAnswer.postings([posting(source.id, "1", "Engineer")], memo: FetchMemo(etag: "v1"))
        let board = Board(id: source.id, [.success(answer), .success(answer), .success(.unchanged)])
        _ = await run(db, board, at: day0, postedWithin: 7)
        _ = await run(db, board, at: day0, postedWithin: 30)
        _ = await run(db, board, at: day0, postedWithin: 30)
        #expect(board.asked.withLock { $0 } == [nil, nil, FetchMemo(etag: "v1")])
    }

    /// A board that fails closes nothing; a complete answer missing a job twice closes it, and the
    /// run's stats say so.
    @Test func failuresCloseNothingAndCompleteAnswersDo() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let source = try await SourceRepository(db).add(kind: .ashby)
        let both = FetchAnswer.postings(
            [posting(source.id, "1", "Backend Developer"), posting(source.id, "2", "Data Engineer")], memo: nil)
        let one = FetchAnswer.postings([posting(source.id, "1", "Backend Developer")], memo: nil)
        let board = Board(
            id: source.id,
            [.success(both), .failure(.offline), .failure(.offline), .success(one), .success(one)])
        for n in 0..<3 { _ = await run(db, board, at: day0.addingTimeInterval(Double(n) * 3_600)) }
        #expect(try await JobRepository(db).jobs().allSatisfy(\.isOpen))
        #expect(try await FetchLog(db).state(of: source.id).failRuns == 2)
        _ = await run(db, board, at: day0.addingTimeInterval(4 * 3_600))
        let last = await run(db, board, at: day0.addingTimeInterval(5 * 3_600))
        #expect(last.closed == 1)
        #expect(
            try await JobRepository(db).jobs(matching: JobFilter(openOnly: true)).map(\.title) == ["Backend Developer"])
        #expect(try await FetchLog(db).state(of: source.id).failRuns == 0)
        let stats = try #require(
            try await RunRepository(db).runs(kind: "fetch").first.flatMap { FetchRun.Stats.decode($0.stats) })
        #expect(stats.closed == 1 && stats.changed == nil)
    }
}
