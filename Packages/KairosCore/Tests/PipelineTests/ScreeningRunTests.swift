import Foundation
import JobSources
import LLM
import MasterResume
import Screening
import Store
import Synchronization
import Testing

@testable import Pipeline

// Sample persona and made-up postings: fixtures only.

private let seenAt = Date(timeIntervalSince1970: 1_790_000_000)

private struct FakeSource: JobSource {
    let id: SourceID
    let reply: @Sendable () async throws -> [Posting]
    func fetch(_ query: SourceQuery) async throws -> [Posting] { try await reply() }
}

/// Answers `analyzeJob` by the job title in the prompt, so analyses can run in any order.
private final class FakeAnalyst: LLMProvider {
    let name = "fake"
    private let replies: [String: String]
    private let delay: Duration
    private let state = Mutex(0)

    init(_ replies: [String: String], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    var calls: Int { state.withLock { $0 } }

    func complete(_ request: ChatRequest) async throws(LLMError) -> ChatResponse {
        state.withLock { $0 += 1 }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { throw .cancelled }
        }
        let prompt = request.messages.last?.content ?? ""
        guard let title = replies.keys.first(where: { prompt.contains("Title: \($0)\n") }), let text = replies[title]
        else { throw .noScriptedReply(request.task) }
        return ChatResponse(text: text, model: request.model, inputTokens: 700, outputTokens: 150)
    }
}

/// An analysis reply whose must-haves are (text, your matching skill).
private func reply(_ musts: [(String, String?)]) -> String {
    let requirements = musts.map { text, skill in
        #"{"text":"\#(text)","kind":"must"\#(skill.map { #","matched_skill":"\#($0)""# } ?? "")}"#
    }
    return """
        {"requirements":[\(requirements.joined(separator: ","))],"years_required":3,"seniority":"unspecified",
         "domains":["logistics"],"flags":{"sponsorship":"not_mentioned","clearance":"not_mentioned",
         "french":"not_mentioned","remote_scope":"onsite"}}
        """
}

private let strong = reply([("Go", "Go"), ("PostgreSQL", "PostgreSQL"), ("Kafka", "Kafka")])
private let partial = reply([("Go", "Go"), ("Rust", nil)])
private let weak = reply([("Go", "Go"), ("Rust", nil), ("Scala", nil)])

/// Jordan's master resume, preferences and work profile.
private func database() async throws -> Database {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    let resume = MasterResumeRepository(db)
    _ = try await resume.save([Skill(name: "Go"), Skill(name: "PostgreSQL"), Skill(name: "Kafka")])
    _ = try await resume.save([ResumeEntry(fields: .language(.init(language: "English", proficiency: .native)))])
    var header = ResumeHeader()
    header.totalYears = 5
    _ = try await resume.saveHeader(header)
    var preferences = SearchPreferences()
    preferences.titleExclude = ["sales"]
    try await SettingsRepository(db).save(preferences, for: SearchPreferences.storageKey)
    try await PrivateSettingsRepository(db).save(
        WorkProfile(authorization: [.canada: .citizen, .unitedStates: .needsSponsorship]), for: WorkProfile.storageKey)
    return db
}

private func router(_ db: Database, _ analyst: FakeAnalyst, budget: Budget = Budget()) -> LLMRouter {
    let client = LLMClient(keys: [analyst], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 })
    return LLMRouter(
        clients: ["fake": client], routes: [.analyzeJob: [ModelRef(provider: "fake", model: "flash-lite")]],
        budget: budget, log: CallLog(db), cache: ResultCache(db))
}

private func job(_ title: String, _ location: String, country: Country = .canada, region: String, seen: Double = 0)
    -> Job
{
    Job(
        canonicalURL: "https://jobs.example/\(title)/\(location)", sourceID: UUID(), url: "https://jobs.example/1",
        dedupKey: "harbourline|\(title)|\(location)", company: "Harbourline Logistics", title: title,
        location: location, region: region, country: country, remoteScope: .onsite,
        descriptionMarkdown: "Build services in Go and PostgreSQL.", firstSeenAt: seenAt.addingTimeInterval(seen))
}

private func screen(_ db: Database, router: LLMRouter?, maxConcurrent: Int = 2) async -> [ScreeningRun.Progress] {
    var updates: [ScreeningRun.Progress] = []
    for await progress in ScreeningRun(db: db, router: router, maxConcurrent: maxConcurrent).start() {
        updates.append(progress)
    }
    return updates
}

@Suite("Screening run")
struct ScreeningRunTests {
    /// SPEC §5.2 end to end: fetch, normalize, de-duplicate, prefilter, analyze, verdict, rank.
    @Test func aFetchIsScreenedEndToEnd() async throws {
        let db = try await database()
        let board = try await SourceRepository(db).add(kind: .greenhouse)
        let postings = [
            ("Backend Developer", "Toronto, ON"), ("Backend Developer", "Seattle, WA"),
            ("Platform Engineer", "Vancouver, BC"), ("Data Engineer", "Ottawa, ON"), ("Sales Engineer", "Toronto, ON"),
        ].enumerated().map { index, posting in
            Posting(
                sourceID: board.id, url: URL(string: "https://jobs.example/gh/\(index)")!,
                company: "Harbourline Logistics", title: posting.0, location: posting.1, postedAt: seenAt,
                descriptionHTML: "<p>Build services in Go and PostgreSQL.</p>")
        }
        let fetch = FetchRun(
            db: db, now: { seenAt },
            makeSource: { _ in (FakeSource(id: board.id) { postings }, SourceQuery()) })
        let analyst = FakeAnalyst([
            "Backend Developer": strong, "Platform Engineer": partial, "Data Engineer": weak,
        ])
        let pipeline = PipelineRun(fetch: fetch, screening: ScreeningRun(db: db, router: router(db, analyst)))

        var events: [PipelineEvent] = []
        for await event in pipeline.start() { events.append(event) }

        // Fetching first, then screening, each ending in its outcome.
        let fetched = events.compactMap { if case .fetching(let progress) = $0 { progress } else { nil } }
        let screened = events.compactMap { if case .screening(let progress) = $0 { progress } else { nil } }
        #expect(fetched.last?.added == 5 && fetched.last?.phase == .finished)
        #expect(events.firstIndex { if case .screening = $0 { true } else { false } }! > fetched.count - 1)
        let last = try #require(screened.last)
        #expect(last.phase == .finished && last.total == 5 && last.done == 5)
        #expect(last.prefiltered == 1 && last.analyzed == 4 && last.failed == 0 && last.waiting == 0)
        #expect(last.yes == 2 && last.maybe == 1 && last.no == 2)
        #expect(analyst.calls == 4)  // the prefiltered job never reached the model

        // Verdicts and ranks: yes before maybe before no, Canada before the US.
        let jobs = try await JobRepository(db).jobs().sorted { ($0.rank ?? -1) > ($1.rank ?? -1) }
        #expect(
            jobs.map { "\($0.title) · \($0.location)" } == [
                "Backend Developer · Toronto, ON", "Backend Developer · Seattle, WA",
                "Platform Engineer · Vancouver, BC",
                "Data Engineer · Ottawa, ON", "Sales Engineer · Toronto, ON",
            ])
        #expect(jobs.map(\.verdict) == [.yes, .yes, .maybe, .no, .no])
        #expect(jobs.map(\.verdictSource) == [.analysis, .analysis, .analysis, .analysis, .prefilter])

        // The trail says why, and the run's stats keep the drop rate and the new yes and maybe counts.
        let sales = try #require(jobs.last)
        #expect(try await ScreeningRepository(db).trail(for: sales.id).map(\.ruleID) == ["title_exclude"])
        let run = try #require(try await RunRepository(db).runs(kind: "screen").first)
        let stats = try #require(ScreeningRun.Stats.decode(run.stats))
        #expect(
            stats == ScreeningRun.Stats(screened: 5, prefiltered: 1, analyzed: 4, failed: 0, yes: 2, maybe: 1, no: 2))
        #expect(stats.dropRate == 0.2 && run.error == nil)
    }

    @Test func aStoredAnalysisIsReused() async throws {
        let db = try await database()
        let posting = job("Backend Developer", "Toronto, ON", region: "ON")
        try await JobRepository(db).upsert(posting)
        let analysis = JobAnalysis(
            requirements: [.init(text: "Go", kind: .must, matchedSkill: "Go")], yearsRequired: 3, seniority: nil,
            domains: [],
            flags: .init(
                sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .onsite))
        try await AnalysisRepository(db).save(
            analysis, for: posting.id, model: "flash-lite", promptVersion: AnalyzeJobTask.promptVersion)
        let analyst = FakeAnalyst([:])

        let last = try #require(await screen(db, router: router(db, analyst)).last)
        #expect(analyst.calls == 0 && last.analyzed == 1 && last.yes == 1)
        #expect(try await JobRepository(db).job(posting.id)?.verdict == .yes)
    }

    @Test func withoutAIOnlyThePrefilterRuns() async throws {
        let db = try await database()
        try await JobRepository(db).upsert([
            job("Sales Engineer", "Toronto, ON", region: "ON"), job("Backend Developer", "Toronto, ON", region: "ON"),
        ])
        let last = try #require(await screen(db, router: nil).last)
        #expect(last.prefiltered == 1 && last.waiting == 1 && last.analyzed == 0)
        #expect(last.stopped?.contains("AI isn't set up") == true)
        let verdicts = try await JobRepository(db).jobs().map { "\($0.title): \($0.verdict?.rawValue ?? "-")" }.sorted()
        #expect(verdicts == ["Backend Developer: -", "Sales Engineer: no"])  // it waits for the next run
    }

    /// SPEC §5.5, Budget: when it's reached, analysis pauses and the rest of the pipeline continues.
    @Test func theBudgetPausesAnalysisAndTheRestWait() async throws {
        let db = try await database()
        try await JobRepository(db).upsert([
            job("Backend Developer", "Toronto, ON", region: "ON"),
            job("Platform Engineer", "Vancouver, BC", region: "BC", seen: 1),
        ])
        let analyst = FakeAnalyst(["Backend Developer": strong, "Platform Engineer": partial])
        let last = try #require(
            await screen(db, router: router(db, analyst, budget: Budget(dailyCalls: 1)), maxConcurrent: 1).last)
        #expect(last.analyzed == 1 && last.yes == 1 && last.waiting == 1 && analyst.calls == 1)
        #expect(last.stopped?.contains("Daily AI budget reached") == true)
        let stats = try #require(
            ScreeningRun.Stats.decode(try await RunRepository(db).runs(kind: "screen").first?.stats ?? ""))
        #expect(stats.budgetReached)
    }

    @Test func aFailedAnalysisLeavesTheJobForNextTime() async throws {
        let db = try await database()
        try await JobRepository(db).upsert([
            job("Backend Developer", "Toronto, ON", region: "ON"), job("Mystery Role", "Toronto, ON", region: "ON"),
        ])
        let analyst = FakeAnalyst(["Backend Developer": strong])  // nothing scripted for the mystery role
        let last = try #require(await screen(db, router: router(db, analyst)).last)
        #expect(last.failed == 1 && last.yes == 1 && last.phase == .finished && last.stopped == nil)
        let mystery = try await JobRepository(db).jobs().first { $0.title == "Mystery Role" }
        #expect(mystery?.verdict == nil)
    }

    @Test func errorsThatHitEveryJobStopAnalysis() {
        let stops: [LLMError] = [
            .budgetReached, .noProvider(.analyzeJob), .noKey(provider: "Gemini"), .keyRejected(provider: "Gemini"),
            .rateLimited(retryAfterSeconds: 29_000), .modelNotOnPlan("flash-lite"), .cancelled,
        ]
        for error in stops {
            guard case .stop = ScreeningRun.outcome(of: error) else {
                Issue.record("\(error) should stop analysis")
                continue
            }
        }
        for error in [LLMError.invalidOutput("x"), .server(status: 500), .timedOut, .badRequest("y")] {
            guard case .failed = ScreeningRun.outcome(of: error) else {
                Issue.record("\(error) should fail one job only")
                continue
            }
        }
    }

    @Test func stoppingTheStreamCancelsTheRun() async throws {
        let db = try await database()
        try await JobRepository(db).upsert(job("Backend Developer", "Toronto, ON", region: "ON"))
        let analyst = FakeAnalyst(["Backend Developer": strong], delay: .seconds(30))
        for await progress in ScreeningRun(db: db, router: router(db, analyst)).start() where progress.total > 0 {
            break  // the first update: stop here
        }
        var run: Run?
        for _ in 0..<100 {
            run = try await RunRepository(db).runs(kind: "screen").first
            if run?.finishedAt != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(run?.error == "cancelled")
        #expect(try await JobRepository(db).jobs().first?.verdict == nil)
    }
}
