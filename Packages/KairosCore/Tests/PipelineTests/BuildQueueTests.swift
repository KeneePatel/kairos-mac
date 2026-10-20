import Foundation
import LLM
import MasterResume
import Render
import Screening
import Store
import Tailoring
import Testing

@testable import Pipeline

// Sample persona and a made-up posting: fixtures only.

private let pipeline = ResumeBullet(
    text: "Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms.", skills: ["Go", "Kafka"])
private let apis = ResumeBullet(
    text: "Shipped REST APIs in Django and PostgreSQL for 30+ client projects.", skills: ["PostgreSQL"])

/// A ready master resume (S14): contact, one role with bullets, five Proven skills.
private func database(ready: Bool = true) async throws -> (Database, Job) {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    let resume = MasterResumeRepository(db)
    var header = ResumeHeader()
    header.fullName = "Jordan Rivera"
    header.email = "jordan.rivera@example.com"
    header.phone = ready ? "+14165550123" : ""
    header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
    header.totalYears = 5
    _ = try await resume.saveHeader(header)
    _ = try await resume.save([
        ResumeEntry(
            fields: .experience(.init(employer: "Harbourline Logistics", title: "Software Developer, Backend")),
            start: YearMonth(year: 2022, month: 3), isCurrent: true, bullets: [pipeline, apis])
    ])
    _ = try await resume.save(["Go", "Kafka", "PostgreSQL", "Kubernetes", "Docker"].map { Skill(name: $0) })
    let job = Job(
        canonicalURL: "https://jobs.example.com/northline/backend", sourceID: UUID(), url: "https://jobs.example.com/1",
        dedupKey: "northline|backend|toronto", company: "Northline Freight", title: "Backend Developer II",
        location: "Toronto, ON", region: "ON", country: .canada, remoteScope: .hybrid,
        descriptionMarkdown: "Go, PostgreSQL and Kafka.", firstSeenAt: Date())
    try await JobRepository(db).upsert(job)
    return (db, job)
}

private func analyse(_ job: Job, in db: Database) async throws {
    let analysis = JobAnalysis(
        requirements: [
            .init(text: "3+ years building services in Go", kind: .must, matchedSkill: "Go"),
            .init(text: "Strong PostgreSQL", kind: .must, matchedSkill: "PostgreSQL"),
            .init(text: "Kubernetes", kind: .nice, matchedSkill: "Kubernetes"),
        ], yearsRequired: 3, seniority: .mid, domains: ["logistics"],
        flags: .init(sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .hybrid))
    try await AnalysisRepository(db).save(
        analysis, for: job.id, model: "flash-lite", promptVersion: AnalyzeJobTask.promptVersion)
}

private let replies: [TaskID: [FakeProvider.Reply]] = [
    .writeExperience: [
        .reply(
            #"{"entries":[{"id":"e1","bullets":[{"text":"Built a Go and Kafka event pipeline handling 4.2M events a day at p99 under 120 ms.","source_ids":["b1"]},{"text":"Shipped REST APIs on PostgreSQL for 30+ client projects.","source_ids":["b2"]}]}]}"#
        )
    ],
    .writeSummary: [
        .reply(
            #"{"summary":"Backend developer with 5 years building Go and PostgreSQL services.","source_ids":["b1"]}"#)
    ],
    .writeSkills: [
        .reply(#"{"groups":[{"label":"Skills","skills":["Go","PostgreSQL","Kafka","Kubernetes","Docker"]}]}"#)
    ],
]

private func router(_ db: Database, _ fake: FakeProvider) -> LLMRouter {
    let client = LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 })
    let routes = Dictionary(
        uniqueKeysWithValues: [TaskID.writeExperience, .writeProjects, .writeSummary, .writeSkills, .rewriteSection].map
        {
            ($0, [ModelRef(provider: "fake", model: "flash")])
        })
    return LLMRouter(
        clients: ["fake": client], routes: routes, budget: Budget(), log: CallLog(db), cache: ResultCache(db))
}

/// A stand-in for typst: one page, fixed bytes.
private let render: BuildQueue.Render = { _ in RenderedPDF(data: Data("%PDF-1.7 sample".utf8), pageCount: 1) }

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "kairos-builds-\(UUID().uuidString)")
}

/// Waits for the build's last event.
private func outcome(of id: UUID, in queue: BuildQueue) async -> BuildQueue.Event? {
    for await event in queue.events {
        switch event {
        case .finished(id, _, _), .failed(id, _): return event
        default: continue
        }
    }
    return nil
}

@Suite("Build queue")
struct BuildQueueTests {
    @Test func aBuildRunsAndLeavesAPDFAndItsRecord() async throws {
        let (db, job) = try await database()
        try await analyse(job, in: db)
        let fake = FakeProvider(replies)
        let output = folder()
        let queue = BuildQueue(db: db, router: router(db, fake), folder: output, render: render)
        let id = try await queue.enqueue(job: job.id)
        guard case .finished(_, let score, let pdf)? = await outcome(of: id, in: queue) else {
            Issue.record("the build didn't finish")
            return
        }
        #expect(score > 0 && FileManager.default.fileExists(atPath: pdf.path()))
        let record = try #require(try await BuildRepository(db).build(id))
        #expect(record.status == .done && record.mode == .strict && record.masterVersion > 0)
        #expect(record.content?.experience.first?.bullets.first?.sourceIDs == [pipeline.id])
        #expect(record.content?.header.contact.first?.text == "jordan.rivera@example.com")  // from code, not the model
        let artifact = try #require(try await BuildRepository(db).artifacts(for: id).first)
        #expect(artifact.kind == "resume" && artifact.localPath == pdf.path() && artifact.sha256.count == 64)
        #expect(Set(fake.requests.map(\.task)) == [.writeExperience, .writeSummary, .writeSkills])
    }

    /// A build a crash left running starts again, and the writers' replies come from the cache.
    @Test func anInterruptedBuildResumesFromCachedSteps() async throws {
        let (db, job) = try await database()
        try await analyse(job, in: db)
        let fake = FakeProvider(replies)
        let first = BuildQueue(db: db, router: router(db, fake), folder: folder(), render: render)
        let done = try await first.enqueue(job: job.id)
        _ = await outcome(of: done, in: first)
        let calls = fake.requests.count

        // As if Kairos quit mid-build: a build left running.
        let builds = BuildRepository(db)
        let interrupted = try await builds.create(job: job.id, mode: .strict, masterVersion: 1)
        try await builds.start(interrupted)
        let restarted = BuildQueue(db: db, router: router(db, fake), folder: folder(), render: render)
        #expect(try await restarted.resumeInterrupted() == [interrupted])
        guard case .finished? = await outcome(of: interrupted, in: restarted) else {
            Issue.record("the interrupted build didn't finish")
            return
        }
        #expect(fake.requests.count == calls)  // every step came from the cache
        #expect(try await builds.build(interrupted)?.status == .done)
    }

    @Test func aBuildNeedsAnAnalysisAndAReadyResume() async throws {
        let (db, job) = try await database()
        let queue = BuildQueue(db: db, router: router(db, FakeProvider(replies)), folder: folder(), render: render)
        let unanalysed = try await queue.enqueue(job: job.id)
        #expect(await outcome(of: unanalysed, in: queue) == .failed(unanalysed, BuildError.notAnalysed.message))

        let (notReady, otherJob) = try await database(ready: false)
        try await analyse(otherJob, in: notReady)
        let blocked = BuildQueue(
            db: notReady, router: router(notReady, FakeProvider(replies)), folder: folder(), render: render)
        let id = try await blocked.enqueue(job: otherJob.id)
        guard case .failed(_, let message)? = await outcome(of: id, in: blocked) else {
            Issue.record("a build without a phone number ran")
            return
        }
        #expect(message.hasPrefix("Your master resume isn't ready"))
        #expect(try await BuildRepository(notReady).build(id)?.status == .failed)

        let noAI = BuildQueue(db: db, router: nil, folder: folder(), render: render)
        try await analyse(job, in: db)
        let without = try await noAI.enqueue(job: job.id)
        #expect(await outcome(of: without, in: noAI) == .failed(without, BuildError.noAI.message))
    }
}
