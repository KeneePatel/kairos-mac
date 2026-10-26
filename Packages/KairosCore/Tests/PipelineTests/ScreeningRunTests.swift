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

/// An analysis reply whose must-haves are (text, your matching skill), in prompt v2's shape: a
/// matching skill is a yes citing its profile id (Go is "s1", PostgreSQL "s2", Kafka "s3").
private func reply(_ musts: [(String, String?)]) -> String {
    let ids = ["Go": "s1", "PostgreSQL": "s2", "Kafka": "s3"]
    let requirements = musts.map { text, skill in
        let match = skill.flatMap { ids[$0] }.map { #""match":"yes","evidence":["\#($0)"]"# } ?? #""match":"no""#
        return #"{"text":"\#(text)","kind":"must","category":"skill",\#(match)}"#
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

private func screen(
    _ db: Database, router: LLMRouter?, scope: ScreeningRun.Scope = .waiting, maxConcurrent: Int = 2
) async -> [ScreeningRun.Progress] {
    var updates: [ScreeningRun.Progress] = []
    for await progress in ScreeningRun(db: db, router: router, scope: scope, maxConcurrent: maxConcurrent).start() {
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

    /// Re-evaluate (P2): a fresh analysis even with one stored and a cached reply, and its verdict
    /// recorded on top of the old one.
    @Test func reevaluateAsksAgainAndRecordsTheNewVerdict() async throws {
        let db = try await database()
        let posting = job("Platform Engineer", "Vancouver, BC", region: "BC")
        try await JobRepository(db).upsert(posting)
        let analyst = FakeAnalyst(["Platform Engineer": partial])
        _ = await screen(db, router: router(db, analyst))
        let screened = try await JobRepository(db).job(posting.id)
        #expect(analyst.calls == 1 && screened?.verdict == .maybe)

        let better = FakeAnalyst(["Platform Engineer": strong])
        let result = await ScreeningRun(db: db, router: router(db, better)).reevaluate(posting.id)
        #expect(result == .verdict(.yes) && better.calls == 1)  // not the stored analysis, not the cache
        #expect(try await JobRepository(db).job(posting.id)?.verdict == .yes)
        let trail = try await ScreeningRepository(db).trail(for: posting.id)
        #expect(trail.map(\.verdict) == [.maybe, .yes])
    }

    /// Re-evaluate applies your current settings first: a job they now rule out never reaches the AI.
    @Test func reevaluateRunsThePrefilterFirst() async throws {
        let db = try await database()
        let posting = job("Sales Engineer", "Toronto, ON", region: "ON")
        try await JobRepository(db).upsert(posting)
        let analyst = FakeAnalyst([:])
        let outcome = await ScreeningRun(db: db, router: router(db, analyst)).reevaluate(posting.id)
        #expect(outcome == .verdict(.no) && analyst.calls == 0)
        let backend = job("Backend Developer", "Toronto, ON", region: "ON")
        try await JobRepository(db).upsert(backend)
        let stopped = await ScreeningRun(db: db, router: nil).reevaluate(backend.id)
        #expect(stopped == .stopped("AI isn't set up yet. Add a key in Settings, AI providers."))
    }

    /// Applying retires the posting's other copies waiting in the Inbox (2026-10-26): the same job
    /// under a slightly different title at that company, or the same title and text under another
    /// name. They go to Filtered out as "already applied"; other roles stay; done once.
    @Test func applyingRetiresThePostingsOtherCopies() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let source = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000bb")!
        let text = String(repeating: "Run the fleet's clusters and the Vac DST pipeline. ", count: 6)
        func job(_ n: Int, _ title: String, company: String, text: String, verdict: Verdict? = .maybe) -> Job {
            Job(
                canonicalURL: "https://jobs.example/\(n)", sourceID: source, url: "https://jobs.example/\(n)",
                dedupKey: "\(company.lowercased())|\(title.lowercased())|toronto", company: company, title: title,
                country: .canada, descriptionMarkdown: text, verdict: verdict,
                verdictSource: verdict.map { _ in .analysis },
                firstSeenAt: seenAt)
        }
        let applied = job(1, "DevOps Engineer (Vac DST)", company: "Institute of Free Technology", text: text)
        let sameCompany = job(
            2, "DevOps Engineer - Vac DST", company: "Institute of Free Technology", text: "Other words.")
        let otherName = job(3, "DevOps Engineer (Vac DST)", company: "Logos", text: text)
        let otherRole = job(4, "MLOps Engineer Internship", company: "Institute of Free Technology", text: text)
        try await JobRepository(db).upsert([applied, sameCompany, otherName, otherRole])
        try await ApplicationRepository(db).apply(job: applied.id, at: seenAt)
        let run = ScreeningRun(db: db, router: nil)
        #expect(await run.retireCopies(of: applied.id) == 2)
        let after = Dictionary(uniqueKeysWithValues: try await JobRepository(db).jobs().map { ($0.id, $0) })
        #expect(after[sameCompany.id]?.verdict == .no && after[sameCompany.id]?.verdictSource == .prefilter)
        #expect(after[otherName.id]?.verdict == .no && after[otherName.id]?.verdictSource == .prefilter)
        #expect(after[otherRole.id]?.verdict == .maybe && after[otherRole.id]?.verdictSource == .analysis)
        #expect(after[applied.id]?.state == .applied)
        let trail = try await ScreeningRepository(db).trail(for: otherName.id)
        #expect(
            trail.last?.ruleID == "already_applied"
                && trail.last?.reasons.first?.contains("Institute of Free Technology") == true)
        #expect(await run.retireCopies(of: applied.id) == 0)
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

    /// "Re-check filters" (2026-10-22) runs without the AI: a job with a stored analysis still gets
    /// its verdict from it, for free; only jobs never analysed wait.
    @Test func withoutAIAStoredAnalysisStillDecides() async throws {
        let db = try await database()
        let analysed = job("Backend Developer", "Toronto, ON", region: "ON")
        let fresh = job("Platform Engineer", "Vancouver, BC", region: "BC")
        try await JobRepository(db).upsert([analysed, fresh])
        let analyst = FakeAnalyst(["Backend Developer": strong])  // the other fails, unanalysed
        _ = await screen(db, router: router(db, analyst))
        try await JobRepository(db).clearScreening()

        let last = try #require(await screen(db, router: nil).last)
        #expect(last.analyzed == 1 && last.yes == 1 && last.waiting == 1)
        #expect(last.stopped?.contains("AI isn't set up") == true)
        #expect(try await JobRepository(db).job(analysed.id)?.verdict == .yes)
        #expect(try await JobRepository(db).job(fresh.id)?.verdict == nil)
    }

    /// "Bring back" (2026-10-22): a job the filters dropped goes to the AI, and stays out of the
    /// filters' reach on every later re-screen.
    @Test func aBroughtBackJobSkipsTheFiltersForGood() async throws {
        let db = try await database()
        let sales = job("Sales Engineer", "Toronto, ON", region: "ON")  // your titles exclude "sales"
        try await JobRepository(db).upsert(sales)
        let analyst = FakeAnalyst(["Sales Engineer": strong])
        _ = await screen(db, router: router(db, analyst))
        #expect(try await JobRepository(db).job(sales.id)?.verdictSource == .prefilter)

        let outcome = await ScreeningRun(db: db, router: router(db, analyst)).bringBack(sales.id)
        #expect(outcome == .verdict(.yes) && analyst.calls == 1)
        #expect(try await JobRepository(db).job(sales.id)?.verdictSource == .analysis)

        try await JobRepository(db).clearScreening()
        let last = try #require(await screen(db, router: router(db, analyst)).last)
        #expect(last.prefiltered == 0 && analyst.calls == 1)  // the stored analysis decides again
        #expect(try await JobRepository(db).job(sales.id)?.verdict == .yes)
    }

    /// Without the AI, a brought-back job waits for it rather than going back to the filters.
    @Test func aBroughtBackJobWaitsWithoutAI() async throws {
        let db = try await database()
        let sales = job("Sales Engineer", "Toronto, ON", region: "ON")
        try await JobRepository(db).upsert(sales)
        _ = await screen(db, router: nil)
        let outcome = await ScreeningRun(db: db, router: nil).bringBack(sales.id)
        #expect(outcome == .stopped("AI isn't set up yet. Add a key in Settings, AI providers."))
        let waiting = try #require(try await JobRepository(db).job(sales.id))
        #expect(waiting.verdict == nil && waiting.verdictSource == nil)
        let context = try await ScreeningContext.load(from: db)
        #expect(context.broughtBack == [sales.id])
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

    /// "Screen waiting jobs" (2026-10-26): a run picks up only the jobs still without a verdict, so
    /// resuming after a stop never spends a call on a job that already has one.
    @Test func screeningTheWaitingLeavesJudgedJobsAlone() async throws {
        let db = try await database()
        let judged = job("Platform Engineer", "Vancouver, BC", region: "BC")
        let waiting = job("Backend Developer", "Toronto, ON", region: "ON")
        try await JobRepository(db).upsert([judged, waiting])
        _ = try await JobRepository(db).setVerdict(.maybe, source: .analysis, rank: 1, for: judged.id)
        let analyst = FakeAnalyst(["Backend Developer": strong, "Platform Engineer": strong])

        let last = try #require(await screen(db, router: router(db, analyst)).last)
        #expect(last.total == 1 && last.yes == 1 && analyst.calls == 1)
        #expect(try await JobRepository(db).job(judged.id)?.verdict == .maybe)
        #expect(try await JobRepository(db).job(waiting.id)?.verdict == .yes)
    }

    /// Re-screen all (2026-10-26) judges every job again in place: a job keeps its verdict until it
    /// gets a new one, so Review's counts never drop to zero mid-run, and one the AI can't judge
    /// again now (no AI, or a failed call) keeps the verdict it had.
    @Test func reScreeningKeepsEachVerdictUntilItGetsANewOne() async throws {
        let db = try await database()
        let analysed = job("Backend Developer", "Toronto, ON", region: "ON")
        let older = job("Platform Engineer", "Vancouver, BC", region: "BC")  // judged by an older prompt
        try await JobRepository(db).upsert([analysed, older])
        _ = await screen(db, router: router(db, FakeAnalyst(["Backend Developer": strong])))
        _ = try await JobRepository(db).setVerdict(.maybe, source: .analysis, rank: 1, for: older.id)

        let withoutAI = try #require(await screen(db, router: nil, scope: .everything).last)
        #expect(withoutAI.total == 2 && withoutAI.analyzed == 1 && withoutAI.yes == 1)
        #expect(withoutAI.kept == 1 && withoutAI.waiting == 0)
        #expect(try await JobRepository(db).job(older.id)?.verdict == .maybe)

        let failing = try #require(await screen(db, router: router(db, FakeAnalyst([:])), scope: .everything).last)
        #expect(failing.failed == 1 && failing.yes == 1)  // the stored analysis still decides the other
        #expect(try await JobRepository(db).job(older.id)?.verdict == .maybe)
        #expect(try await JobRepository(db).job(analysed.id)?.verdict == .yes)
    }

    /// Re-screen all applies changed filters in place: a job they now drop becomes a No, and one
    /// they used to drop leaves Filtered out and waits for the AI.
    @Test func reScreeningAppliesChangedFiltersInPlace() async throws {
        let db = try await database()
        let backend = job("Backend Developer", "Toronto, ON", region: "ON")
        let sales = job("Sales Engineer", "Toronto, ON", region: "ON")  // your titles exclude "sales"
        try await JobRepository(db).upsert([backend, sales])
        _ = await screen(db, router: router(db, FakeAnalyst(["Backend Developer": strong])))
        #expect(try await JobRepository(db).job(sales.id)?.verdictSource == .prefilter)
        var preferences = SearchPreferences()
        preferences.titleExclude = ["backend"]
        try await SettingsRepository(db).save(preferences, for: SearchPreferences.storageKey)

        let last = try #require(await screen(db, router: nil, scope: .everything).last)
        #expect(last.prefiltered == 1 && last.waiting == 1)
        let dropped = try #require(try await JobRepository(db).job(backend.id))
        #expect(dropped.verdict == .no && dropped.verdictSource == .prefilter)
        let letThrough = try #require(try await JobRepository(db).job(sales.id))
        #expect(letThrough.verdict == nil && letThrough.verdictSource == nil)
    }

    /// Your own verdict is never screened again, by either scope.
    @Test func reScreeningNeverTouchesYourVerdict() async throws {
        let db = try await database()
        let sales = job("Sales Engineer", "Toronto, ON", region: "ON")
        try await JobRepository(db).upsert(sales)
        try await JobRepository(db).setUserVerdict(.yes, rank: 1, for: sales.id)

        let last = try #require(await screen(db, router: nil, scope: .everything).last)
        #expect(last.total == 0)
        let yours = try #require(try await JobRepository(db).job(sales.id))
        #expect(yours.verdict == .yes && yours.verdictSource == .user)
    }

    /// Stopping a Re-screen all part way leaves every verdict where it was.
    @Test func stoppingAReScreenLosesNoVerdict() async throws {
        let db = try await database()
        let posting = job("Platform Engineer", "Vancouver, BC", region: "BC")
        try await JobRepository(db).upsert(posting)
        _ = try await JobRepository(db).setVerdict(.maybe, source: .analysis, rank: 1, for: posting.id)
        let analyst = FakeAnalyst(["Platform Engineer": strong], delay: .seconds(30))
        let run = ScreeningRun(db: db, router: router(db, analyst), scope: .everything)
        for await progress in run.start() where progress.total > 0 {
            break
        }
        #expect(try await JobRepository(db).job(posting.id)?.verdict == .maybe)
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
