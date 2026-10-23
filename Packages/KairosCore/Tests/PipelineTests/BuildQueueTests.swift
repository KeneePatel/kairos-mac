import Foundation
import LLM
import MasterResume
import Render
import Screening
import Store
import Synchronization
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
        uniqueKeysWithValues: [
            TaskID.writeExperience, .writeProjects, .writeSummary, .writeSkills, .rewriteSection, .gapBullets,
            .coverLetter,
        ].map {
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

/// What a fake render was asked to print, safe to share with the queue's workers.
private final class Printed: Sendable {
    private let kinds = Mutex<[String]>([])

    private let layouts = Mutex<[ResumeTemplate]>([])

    func record(_ printable: Printable) {
        kinds.withLock {
            if case .letter = printable { $0.append("letter") } else { $0.append("resume") }
        }
        if case .resume(let document) = printable { layouts.withLock { $0.append(document.template) } }
    }

    /// The template of each resume printed.
    var templates: [ResumeTemplate] { layouts.withLock { $0 } }

    var last: String? { kinds.withLock { $0.last } }
}

/// Holds the first print until opened and ignores cancellation, like the typst wait that froze a
/// build for hours (2026-10-20). Later prints pass straight through.
private final class StuckFirstPrint: Sendable {
    private struct State {
        var prints = 0
        var opened = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func pass() async {
        await withCheckedContinuation { continuation in
            let hold = state.withLock { state in
                state.prints += 1
                guard state.prints == 1, !state.opened else { return false }
                state.waiting.append(continuation)
                return true
            }
            if !hold { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.opened = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

@Suite("Build queue")
struct BuildQueueTests {
    /// A build stuck in a step that never returns fails at its deadline, frees its worker for the
    /// next build, and stays failed when the step ends later.
    @Test func aStuckBuildFailsAtItsDeadlineAndFreesItsWorker() async throws {
        let (db, job) = try await database()
        try await analyse(job, in: db)
        let stuck = StuckFirstPrint()
        // Every build in this queue gets the limit, including the one after the stuck build, so it
        // must allow a normal build on a busy CI runner: 0.5 s failed there (2026-10-21).
        let limit = Duration.seconds(3)
        let queue = BuildQueue(
            db: db, router: router(db, FakeProvider(replies)), folder: folder(), workers: 1, maxDuration: limit
        ) { printable in
            await stuck.pass()
            return try await render(printable)
        }
        let first = try await queue.enqueue(job: job.id)
        let second = try await queue.enqueue(job: job.id)
        #expect(await outcome(of: first, in: queue) == .failed(first, BuildError.tookTooLong(limit).message))
        guard case .finished? = await outcome(of: second, in: queue) else {
            Issue.record("the build after the stuck one didn't run")
            return
        }

        stuck.open()
        try await Task.sleep(for: .milliseconds(300))
        let record = try #require(try await BuildRepository(db).build(first))
        #expect(record.status == .failed && record.error == BuildError.tookTooLong(limit).message)
    }

    /// The app's queue prints with Harvard's template, which has no summary, so none is written.
    @Test func aHarvardBuildPrintsHarvardsLayoutWithoutASummary() async throws {
        let (db, job) = try await database()
        try await analyse(job, in: db)
        let fake = FakeProvider(replies)
        let printed = Printed()
        let queue = BuildQueue(db: db, router: router(db, fake), folder: folder(), template: .harvard) { printable in
            printed.record(printable)
            return try await render(printable)
        }
        let id = try await queue.enqueue(job: job.id)
        guard case .finished? = await outcome(of: id, in: queue) else {
            Issue.record("the build didn't finish")
            return
        }
        #expect(Set(fake.requests.map(\.task)) == [.writeExperience, .writeSkills])
        #expect(try await BuildRepository(db).build(id)?.content?.summary == nil)
        #expect(printed.templates.allSatisfy { $0 == .harvard } && !printed.templates.isEmpty)
    }

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

        // A key added after the queue started: the next build uses it.
        let late = BuildQueue(db: db, router: nil, folder: folder(), render: render)
        await late.setRouter(router(db, FakeProvider(replies)))
        try await analyse(job, in: db)
        let afterKey = try await late.enqueue(job: job.id)
        guard case .finished? = await outcome(of: afterKey, in: late) else {
            Issue.record("the build with the new router didn't finish")
            return
        }

        let noAI = BuildQueue(db: db, router: nil, folder: folder(), render: render)
        try await analyse(job, in: db)
        let without = try await noAI.enqueue(job: job.id)
        #expect(await outcome(of: without, in: noAI) == .failed(without, BuildError.noAI.message))
    }

    /// Stretch is opt-in: off, a stretch build doesn't run. On, its gap bullets are stored flagged.
    @Test func aStretchBuildNeedsStretchModeAndStoresItsGapBulletsFlagged() async throws {
        let (db, job) = try await database()
        _ = try await MasterResumeRepository(db).save([Skill(name: "Terraform", level: .canDiscuss)])
        let analysis = JobAnalysis(
            requirements: [
                .init(text: "3+ years building services in Go", kind: .must, matchedSkill: "Go"),
                .init(text: "Terraform", kind: .nice, matchedSkill: nil),
            ], yearsRequired: 3, seniority: .mid, domains: [],
            flags: .init(
                sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .hybrid))
        try await AnalysisRepository(db).save(
            analysis, for: job.id, model: "flash-lite", promptVersion: AnalyzeJobTask.promptVersion)
        var scripts = replies
        scripts[.gapBullets] = [
            .reply(
                #"{"bullets":[{"role":"e1","covers":"r1","text":"Wrote Terraform modules for the pipeline's three environments."}]}"#
            )
        ]
        let fake = FakeProvider(scripts)
        let queue = BuildQueue(db: db, router: router(db, fake), folder: folder(), render: render)

        let off = try await queue.enqueue(job: job.id, mode: .stretch)
        #expect(await outcome(of: off, in: queue) == .failed(off, BuildError.stretchOff.message))
        #expect(fake.requests.isEmpty)

        try await SettingsRepository(db).save(StretchSettings(enabled: true), for: StretchSettings.storageKey)
        let on = try await queue.enqueue(job: job.id, mode: .stretch)
        guard case .finished? = await outcome(of: on, in: queue) else {
            Issue.record("the stretch build didn't finish")
            return
        }
        let row = try #require(
            try await db.query("SELECT content FROM build WHERE id = ?", [.text(on.lowercased)]).first)
        let content = try #require(row.string("content"))
        #expect(content.contains(#""verified":false"#) && content.contains(#""covers":"Terraform""#))
        let stored = try #require(try await BuildRepository(db).build(on)?.content)
        #expect(stored.experience.first?.bullets.last?.gap == true)
    }

    /// A letter asked for with the build is saved as its own PDF, and its state stays on the build.
    @Test func aBuildCanAlsoWriteItsCoverLetter() async throws {
        let (db, job) = try await database()
        try await analyse(job, in: db)
        let paragraphs = [
            "I'm applying for the Backend Developer II role at Northline Freight. For the past 5 years I've built backend services in Go and PostgreSQL for a logistics company, and the work in your posting is close to what I do every day.",
            "At Harbourline Logistics I built an event pipeline in Go that handles 4.2M events a day with p99 under 120 ms. Before that I shipped REST APIs on PostgreSQL for 30+ client projects, so I'm used to owning a service from its schema to its API.",
            "I care about services that are simple to run: clear interfaces, careful data models and measurements that show where the time goes. That habit is what kept the pipeline fast as its traffic grew, and it's how I'd approach the systems on your team.",
            "This role interests me because reliable data sits at the centre of it. I'd welcome a conversation about how I could help your team.",
        ]
        let letter = String(decoding: try JSONEncoder().encode(["paragraphs": paragraphs]), as: UTF8.self)
        var scripts = replies
        scripts[.coverLetter] = [.reply(letter)]
        let printed = Printed()
        let render: BuildQueue.Render = { printable in
            printed.record(printable)
            return RenderedPDF(data: Data("%PDF-1.7 sample".utf8), pageCount: 1)
        }
        let queue = BuildQueue(db: db, router: router(db, FakeProvider(scripts)), folder: folder(), render: render)
        let id = try await queue.enqueue(job: job.id, coverLetter: true)
        #expect(try await BuildRepository(db).build(id)?.coverLetter == .requested)
        let event = await outcome(of: id, in: queue)
        guard case .finished? = event else {
            Issue.record("the build didn't finish: \(String(describing: event))")
            return
        }
        let record = try #require(try await BuildRepository(db).build(id))
        #expect(record.coverLetter?.status == .done)
        #expect(record.coverLetter?.letter?.greeting == "Dear Northline Freight hiring team,")
        #expect(record.coverLetter?.letter?.header.contact.first?.text == "jordan.rivera@example.com")
        let kinds = try await BuildRepository(db).artifacts(for: id).map(\.kind)
        #expect(kinds == ["resume", "cover_letter"])
        #expect(printed.last == "letter")

        // A letter failing its checks twice is left out, and the build still finishes. A fresh
        // database, so the first letter doesn't come back from the result cache.
        let (other, otherJob) = try await database()
        try await analyse(otherJob, in: other)
        let invented = String(
            decoding: try JSONEncoder().encode(["paragraphs": paragraphs + ["I also write Rust services."]]),
            as: UTF8.self)
        scripts[.coverLetter] = [.reply(invented), .reply(invented)]
        let failing = BuildQueue(
            db: other, router: router(other, FakeProvider(scripts)), folder: folder(), render: render)
        let second = try await failing.enqueue(job: otherJob.id, coverLetter: true)
        guard case .finished? = await outcome(of: second, in: failing) else {
            Issue.record("a build whose letter failed didn't finish")
            return
        }
        let left = try #require(try await BuildRepository(other).build(second))
        #expect(left.status == .done && left.coverLetter?.status == .failed)
        #expect(left.coverLetter?.error?.hasPrefix("The cover letter didn't pass its checks") == true)
        #expect(left.coverLetter?.error?.contains("What the checks found:") == true)  // and why
        #expect(left.coverLetter?.error?.contains("Rust") == true)
        #expect(try await BuildRepository(other).artifacts(for: second).map(\.kind) == ["resume"])
    }
}

@Suite("Build requirements")
struct BuildRequirementsTests {
    /// Only skills and experience reach the writers and the score: the 1Password postings' "Humility"
    /// and "Teamwork" must-haves are screening's, as are location and enrolment. A spoken-language
    /// requirement shows your languages, and a certification ask is passed on as written.
    @Test func aBuildAnswersOnlyWhatABulletCanShow() {
        let analysis = JobAnalysis(
            requirements: [
                .init(text: "Working knowledge of React", kind: .must, category: .skill, match: .yes),
                .init(text: "Humility: you ask questions", kind: .must, category: .soft, match: .notJudged),
                .init(text: "Remote within Canada or the US", kind: .must, category: .location, match: .notJudged),
                .init(text: "Enrolled in a co-op program", kind: .must, category: .enrolment, match: .notJudged),
                .init(text: "2+ years with TypeScript", kind: .nice, category: .experience, match: .partial),
                .init(text: "Bilingual in English and French", kind: .nice, category: .language, match: .no),
                .init(text: "AWS certification an asset", kind: .nice, category: .education, match: .no),
            ], yearsRequired: nil, seniority: .intern, domains: ["security"],
            flags: .init(
                sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .remote))
        let requirements = BuildQueue.requirements(analysis)
        #expect(requirements.musts == ["Working knowledge of React"])
        #expect(requirements.nices == ["2+ years with TypeScript"] && requirements.domains == ["security"])
        #expect(requirements.asksForLanguages && requirements.certificationAsks == ["AWS certification an asset"])
        let plain = BuildQueue.requirements(
            JobAnalysis(
                requirements: [.init(text: "Go", kind: .must, category: .skill, match: .yes)], yearsRequired: nil,
                seniority: .mid, domains: [], flags: analysis.flags))
        #expect(!plain.asksForLanguages && plain.certificationAsks.isEmpty)
    }
}
