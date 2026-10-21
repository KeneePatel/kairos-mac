import Foundation
import JobSources
import Store

/// One "Fetch now": every enabled source is fetched (a few at a time), each posting normalized,
/// postings outside Canada and the US and duplicates dropped, and the rest stored (SPEC §5.2, steps
/// 1–3). Progress arrives as an `AsyncStream`; stopping the stream cancels the run.
public struct FetchRun: Sendable {
    public struct Progress: Sendable, Equatable {
        public enum Phase: Sendable, Equatable { case running, finished, cancelled }
        public var phase: Phase = .running
        public var sourcesTotal = 0
        public var sourcesDone = 0
        /// Postings the boards returned.
        public var found = 0
        /// Dropped because every place they name is outside Canada and the US.
        public var outside = 0
        /// Dropped because they were stored before or are another board's copy.
        public var duplicates = 0
        public var added = 0
        public var failures: [Failure] = []

        public init() {}
    }

    public struct Failure: Sendable, Equatable {
        public let sourceID: UUID
        public let message: String
    }

    /// The `run.stats` JSON for a fetch.
    public struct Stats: Codable, Equatable, Sendable {
        public let sources: Int
        public let failed: Int
        public let found: Int
        public let outside: Int
        public let duplicates: Int
        public let added: Int

        public static func decode(_ json: String) -> Stats? {
            try? JSONDecoder().decode(Stats.self, from: Data(json.utf8))
        }
    }

    public typealias MakeSource = @Sendable (Source) throws -> (any JobSource, SourceQuery)

    let db: Database
    let makeSource: MakeSource
    let maxConcurrent: Int
    let now: @Sendable () -> Date

    /// At most 4 HTTP sources at a time (SPEC §5.2).
    public init(
        db: Database, maxConcurrent: Int = 4, now: @escaping @Sendable () -> Date = { Date() },
        makeSource: @escaping MakeSource
    ) {
        self.db = db
        self.makeSource = makeSource
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
    }

    public func start() -> AsyncStream<Progress> {
        AsyncStream { continuation in
            let task = Task { await perform(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ continuation: AsyncStream<Progress>.Continuation) async {
        var progress = Progress()
        let runs = RunRepository(db)
        let runID = try? await runs.begin(kind: "fetch")
        let sources = (try? await SourceRepository(db).sources(enabledOnly: true)) ?? []
        progress.sourcesTotal = sources.count
        continuation.yield(progress)

        // Company boards first, then search sources (Adzuna): a job on both keeps the board's full
        // posting rather than a search's snippet, since the first copy stored wins.
        let boards = sources.filter { !$0.kind.isSearch }
        let searches = sources.filter(\.kind.isSearch)
        for batch in [boards, searches] where !batch.isEmpty && !Task.isCancelled {
            await withTaskGroup(of: (Source, Result<[Posting], any Error>).self) { group in
                var pending = batch[...]
                func startNext() {
                    guard let source = pending.popFirst() else { return }
                    group.addTask { (source, await fetch(source)) }
                }
                for _ in 0..<maxConcurrent { startNext() }
                for await (source, result) in group {
                    guard !Task.isCancelled else { break }
                    await record(result, from: source, into: &progress)
                    progress.sourcesDone += 1
                    continuation.yield(progress)
                    startNext()
                }
            }
        }

        progress.phase = Task.isCancelled ? .cancelled : .finished
        if let runID {
            let stats = Stats(
                sources: progress.sourcesTotal, failed: progress.failures.count, found: progress.found,
                outside: progress.outside, duplicates: progress.duplicates, added: progress.added)
            let json = (try? JSONEncoder().encode(stats)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            try? await runs.finish(runID, stats: json, error: progress.phase == .cancelled ? "cancelled" : nil)
        }
        continuation.yield(progress)
        continuation.finish()
    }

    private func fetch(_ source: Source) async -> Result<[Posting], any Error> {
        do {
            let (jobSource, query) = try makeSource(source)
            return .success(try await jobSource.fetch(query))
        } catch {
            return .failure(error)
        }
    }

    private func record(_ result: Result<[Posting], any Error>, from source: Source, into progress: inout Progress)
        async
    {
        let sources = SourceRepository(db)
        switch result {
        case .failure(let error):
            progress.failures.append(Failure(sourceID: source.id, message: Self.message(for: error)))
            // A failed run found nothing, so it counts toward "degraded" too.
            _ = try? await sources.recordRun(of: source.id, found: 0, at: now())
        case .success(let postings):
            progress.found += postings.count
            do {
                let (added, outside, duplicates) = try await store(postings)
                progress.added += added
                progress.outside += outside
                progress.duplicates += duplicates
            } catch {
                progress.failures.append(Failure(sourceID: source.id, message: "Couldn't save the jobs: \(error)"))
            }
            _ = try? await sources.recordRun(of: source.id, found: postings.count, at: now())
        }
    }

    /// Normalizes, de-duplicates against what's stored (including jobs saved earlier in this run),
    /// and stores. Returns the counts of jobs added and postings dropped.
    private func store(_ postings: [Posting]) async throws -> (added: Int, outside: Int, duplicates: Int) {
        let seenAt = now()
        var jobs: [Job] = []
        var outside = 0
        for posting in postings {
            switch Normalizer.normalize(posting, firstSeenAt: seenAt) {
            case .job(let job): jobs.append(job)
            case .outsideCanadaAndUS: outside += 1
            }
        }
        let repository = JobRepository(db)
        let known = try await repository.knownIDs(among: jobs.map(\.id))
        let companies = Set(jobs.map { String($0.dedupKey.prefix { $0 != "|" }) })
        let existing = try await repository.dedupEntries(companies: companies).map {
            Deduplicator.Known(sourceID: $0.sourceID, dedupKey: $0.dedupKey)
        }
        let fresh = Deduplicator.newJobs(jobs, knownIDs: known, existing: existing)
        if !fresh.isEmpty { try await repository.upsert(fresh) }
        return (fresh.count, outside, jobs.count - fresh.count)
    }

    static func message(for error: any Error) -> String {
        if let error = error as? SourceError { return error.message }
        if error is CancellationError { return SourceError.cancelled.message }
        return "Something went wrong: \(error.localizedDescription)"
    }
}
