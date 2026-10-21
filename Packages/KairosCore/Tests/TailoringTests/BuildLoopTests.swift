import Foundation
import LLM
import MasterResume
import Store
import Testing

@testable import Tailoring

private let request = BuildRequest(
    jobTitle: "Backend Developer II", company: "Northline Freight", requirements: WriterFixtures.requirements,
    locale: .canada)

/// With the default caps the selection is: Harbourline b1 pipeline, b2 Kubernetes, b3 carriers,
/// b4 on-call; Rivet b5 APIs, b6 CI; Maplepay b7 reconciliation. Projects: Dockyard, b1.
private let goodExperience = """
    {"entries":[
      {"id":"e1","bullets":[
        {"text":"Built a Go and Kafka event pipeline handling 4.2M events a day at p99 under 120 ms.","source_ids":["b1"]},
        {"text":"Moved 14 services to Kubernetes on a shared Helm chart, cutting deploys from 25 to 6 minutes.","source_ids":["b2"]},
        {"text":"Cut carrier onboarding from 3 weeks to 4 days with a gRPC integration kit.","source_ids":["b3"]},
        {"text":"Led a five-person on-call rotation that cut repeat incidents by 40% over two quarters.","source_ids":["b4"]}]},
      {"id":"e2","bullets":[
        {"text":"Shipped REST APIs in Django and PostgreSQL for 30+ client projects.","source_ids":["b5"]}]},
      {"id":"e3","bullets":[
        {"text":"Wrote Java reconciliation jobs that matched 2M card transactions nightly.","source_ids":["b7"]}]}]}
    """
private let weakExperience = """
    {"entries":[
      {"id":"e1","bullets":[{"text":"Worked on the event pipeline.","source_ids":["b1"]}]},
      {"id":"e2","bullets":[{"text":"Worked on client APIs.","source_ids":["b5"]}]},
      {"id":"e3","bullets":[{"text":"Worked on reconciliation jobs.","source_ids":["b7"]}]}]}
    """
private let inventedExperience = goodExperience.replacing("Go and Kafka", with: "Rust and Kafka")
private let projects =
    #"{"entries":[{"id":"e1","bullets":[{"text":"Built Dockyard, a Go CLI that removes dangling Docker images and volumes; 400+ stars.","source_ids":["b1"]}]}]}"#
private let summary =
    #"{"summary":"Backend developer with 5 years building Go, Kafka and PostgreSQL services.","source_ids":["b1"]}"#
private let skills =
    #"{"groups":[{"label":"Languages","skills":["Go","Java","Python"]},{"label":"Data and infrastructure","skills":["PostgreSQL","Kafka","Kubernetes","Docker","Helm"]}]}"#

private func loop(_ scripts: [TaskID: [FakeProvider.Reply]], master: MasterResume = Sample.resume) throws -> (
    BuildLoop, FakeProvider
) {
    let fake = FakeProvider(scripts)
    let db = try Database(path: ":memory:")
    let client = LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 })
    let routes = Dictionary(
        uniqueKeysWithValues: [
            TaskID.writeExperience, .writeProjects, .writeSummary, .writeSkills, .rewriteSection, .gapBullets,
            .coverLetter,
        ].map {
            ($0, [ModelRef(provider: "fake", model: "flash")])
        })
    let router = LLMRouter(clients: ["fake": client], routes: routes, budget: Budget(), log: CallLog(db), cache: nil)
    var settings = BuildLoop.Settings()
    settings.selector = Selector(now: Date(timeIntervalSince1970: 1_790_000_000))
    return (BuildLoop(router: router, master: master, settings: settings), fake)
}

private func migrated() async throws -> Database {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    return db
}

@Suite("Build loop")
struct BuildLoopTests {
    @Test func aBuildWritesPolishesAndScores() async throws {
        let (loop, fake) = try loop([
            .writeExperience: [.reply(goodExperience)], .writeProjects: [.reply(projects)],
            .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
        ])
        let outcome = try await loop.run(request)
        #expect(fake.requests.count == 4 && outcome.rewrites == 0 && outcome.fellBack.isEmpty)
        let resume = outcome.resume
        #expect(resume.header.name == "Jordan Rivera")
        #expect(resume.experience.map(\.organization) == ["Harbourline Logistics", "Rivet Studio", "Maplepay"])
        #expect(resume.experience[0].dates == "Mar 2022 – Present")
        #expect(resume.experience[0].bullets[0].sourceIDs == [Sample.pipeline.id])
        #expect(resume.experience[0].bullets[0].rank > resume.experience[0].bullets[3].rank)  // pipeline beats on-call
        #expect(resume.projects.first?.title == "Dockyard" && resume.projects.first?.organization == "Go, Docker")
        #expect(
            resume.education.first?.title == "BMath, Computer Science" && resume.education.first?.dates == "2015 – 2019"
        )
        #expect(resume.certifications.first?.title == "AWS Solutions Architect – Associate")
        #expect(resume.skills.map(\.label) == ["Languages", "Data and infrastructure"])
        #expect((outcome.score.score(.experience) ?? 0) >= 70 && outcome.score.total > 70)
        // Every bullet still passes the verifier after polishing.
        let verifier = Verifier(resume: Sample.resume, hiringCompany: "Northline Freight")
        #expect(resume.experience.flatMap(\.bullets).allSatisfy { verifier.check($0).isEmpty })
    }

    /// SPEC §5.3: a section under 70 gets `rewriteSection`, and the better version is kept.
    @Test func aWeakSectionIsRewrittenAndTheBetterVersionKept() async throws {
        let (loop, fake) = try loop([
            .writeExperience: [.reply(weakExperience)], .writeProjects: [.reply(projects)],
            .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
            .rewriteSection: [.reply(goodExperience)],
        ])
        let outcome = try await loop.run(request)
        #expect(outcome.rewrites == 1)
        #expect(outcome.resume.experience[0].bullets.count == 4)  // the rewrite won
        let rewrite = try #require(fake.requests.first { $0.task == .rewriteSection })
        let prompt = rewrite.messages.last?.content ?? ""
        #expect(prompt.contains("<current>") && prompt.contains("Worked on the event pipeline. (cites b1)"))
        #expect(prompt.contains("“worked on”"))  // the findings
    }

    @Test func aRewriteThatIsntBetterIsDropped() async throws {
        let (loop, fake) = try loop([
            .writeExperience: [.reply(weakExperience)], .writeProjects: [.reply(projects)],
            .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
            .rewriteSection: [.reply(weakExperience)],
        ])
        let outcome = try await loop.run(request)
        #expect(outcome.rewrites == 1)  // no improvement, so no second pass
        #expect(outcome.resume.experience[0].bullets.map(\.text) == ["Worked on the event pipeline."])
        #expect(fake.requests.count { $0.task == .rewriteSection } == 1)
    }

    /// A writer that still fails after its repair: your bullets, word for word.
    @Test func aFailingWriterFallsBackToYourBullets() async throws {
        let (loop, _) = try loop([
            .writeExperience: [.reply(inventedExperience), .reply(inventedExperience)],
            .writeProjects: [.reply(projects)], .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
        ])
        let outcome = try await loop.run(request)
        #expect(outcome.fellBack == [.experience])
        #expect(outcome.resume.experience[0].bullets.map(\.text).first == Sample.pipeline.text)
        #expect(outcome.resume.experience.flatMap(\.bullets).count == 7)
    }

    /// Each entry carries its dates as numbers as well as text, so a template can write them its own
    /// way: Harvard spells the months out on both ends, which parsers read exactly.
    @Test func everyEntryCarriesItsDatesAsNumbers() async throws {
        let (loop, _) = try loop([
            .writeExperience: [.reply(goodExperience)], .writeProjects: [.reply(projects)],
            .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
        ])
        let resume = try await loop.run(request).resume
        typealias Month = TailoredResume.Period.Month
        #expect(resume.experience[0].period == .init(start: Month(year: 2022, month: 3), isCurrent: true))
        #expect(
            resume.experience[1].period == .init(start: Month(year: 2020, month: 6), end: Month(year: 2022, month: 2)))
        #expect(resume.projects.first?.period == .init(start: Month(year: 2023, month: 1), isCurrent: true))
        #expect(
            resume.education.first?.period
                == .init(start: Month(year: 2015, month: 9), end: Month(year: 2019, month: 4)))
        #expect(resume.education.first?.dates == "2015 – 2019")  // the text stays as it was
        #expect(resume.certifications.first?.period == nil)  // no date, no period
    }

    /// A template without a summary (Harvard's): no call is spent on one, and the score doesn't
    /// count words the PDF won't show.
    @Test func aBuildWithoutASummaryWritesNone() async throws {
        let (loop, fake) = try loop([
            .writeExperience: [.reply(goodExperience)], .writeProjects: [.reply(projects)],
            .writeSkills: [.reply(skills)],
        ])
        var noSummary = request
        noSummary.summary = false
        let outcome = try await loop.run(noSummary)
        #expect(!fake.requests.map(\.task).contains(.writeSummary))
        #expect(outcome.resume.summary == nil && outcome.fellBack.isEmpty)
        #expect(outcome.score.score(.summary) == nil && outcome.score.score(.experience) != nil)
    }

    @Test func liteModeWritesOnlyTheSummaryAndSkills() async throws {
        let (loop, fake) = try loop([.writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)]])
        var lite = request
        lite.mode = .lite
        let outcome = try await loop.run(lite)
        #expect(Set(fake.requests.map(\.task)) == [.writeSummary, .writeSkills])
        #expect(outcome.resume.experience[1].bullets.map(\.text) == [Sample.apis.text, Sample.ci.text])
    }

    /// Over the page budget: the lowest-ranked bullets go first, and every entry keeps one.
    @Test func pageFittingDropsTheLowestRankedBullets() async throws {
        let (loop, _) = try loop([
            .writeExperience: [.reply(goodExperience)], .writeProjects: [.reply(projects)],
            .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
        ])
        let outcome = try await loop.run(request) { resume in resume.allBullets.count > 5 ? 2 : 1 }
        #expect(outcome.pages == 1 && outcome.dropped == 2)
        let kept = outcome.resume.experience.flatMap(\.bullets).map(\.sourceIDs).flatMap { $0 }
        #expect(!kept.contains(Sample.onCall.id))  // the lowest-ranked went first
        #expect(outcome.resume.experience.allSatisfy { !$0.bullets.isEmpty })
        #expect(outcome.score.breakdown.structure > 2)
    }

    @Test func runningOutOfBudgetStopsTheBuild() async throws {
        let (loop, _) = try loop([
            .writeExperience: [.reply(goodExperience)], .writeProjects: [.reply(projects)],
            .writeSummary: [.failure(.budgetReached)], .writeSkills: [.reply(skills)],
        ])
        await #expect(throws: LLMError.budgetReached) { try await loop.run(request) }
    }

    // MARK: - Stretch mode

    private static let writers: [TaskID: [FakeProvider.Reply]] = [
        .writeExperience: [.reply(goodExperience)], .writeProjects: [.reply(projects)],
        .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
    ]
    private static let gaps = """
        {"bullets":[
          {"role":"e1","covers":"r1","text":"Wrote Terraform modules for the event pipeline's three environments."},
          {"role":"e2","covers":"r2","text":"Prototyped a Rust service that rate-limited client API calls."}]}
        """

    private var stretch: BuildRequest {
        var stretch = request
        stretch.requirements = WriterFixtures.stretchRequirements
        stretch.mode = .stretch
        return stretch
    }

    /// After the rewrites, gap bullets cover what's still missing with Can-discuss skills, flagged.
    @Test func stretchModeAddsFlaggedGapBulletsForWhatsStillUncovered() async throws {
        var scripts = Self.writers
        scripts[.gapBullets] = [.reply(Self.gaps)]
        let (loop, fake) = try loop(scripts)
        let outcome = try await loop.run(stretch)
        #expect(fake.requests.map(\.task).last == .gapBullets)
        let harbourline = try #require(outcome.resume.experience.first)
        let added = try #require(harbourline.bullets.last)
        #expect(added.gap && !added.verified && added.covers == "Infrastructure as code with Terraform")
        #expect(harbourline.bullets.dropLast().allSatisfy { $0.verified })
        #expect(outcome.resume.experience[1].bullets.last?.covers == "Rust")
        #expect(outcome.resume.allBullets.count { $0.gap } == 2)
        #expect(outcome.score.breakdown.niceToHaves == 10)  // Kubernetes, gRPC, Terraform, Rust
    }

    /// A reply still failing after its repair is dropped: the build goes on without gap bullets.
    @Test func gapBulletsThatFailTheirChecksAreDropped() async throws {
        let claimed = Self.gaps.replacing("Wrote Terraform modules", with: "Earned a Terraform certification")
        var scripts = Self.writers
        scripts[.gapBullets] = [.reply(claimed), .reply(claimed)]
        let (loop, fake) = try loop(scripts)
        let outcome = try await loop.run(stretch)
        #expect(fake.requests.count { $0.task == .gapBullets } == 2)
        #expect(outcome.resume.allBullets.allSatisfy { $0.verified })
    }

    @Test func strictModeNeverAsksForGapBullets() async throws {
        let (loop, fake) = try loop(Self.writers)
        var strict = stretch
        strict.mode = .strict
        let outcome = try await loop.run(strict)
        #expect(!fake.requests.contains { $0.task == .gapBullets })
        #expect(outcome.resume.allBullets.allSatisfy { $0.verified })
    }

    /// Over the page budget, gap bullets go before any bullet your master resume backs.
    @Test func pageFittingDropsGapBulletsFirst() async throws {
        var scripts = Self.writers
        scripts[.gapBullets] = [.reply(Self.gaps)]
        let (loop, _) = try loop(scripts)
        let outcome = try await loop.run(stretch) { resume in resume.allBullets.count > 7 ? 2 : 1 }
        #expect(outcome.dropped == 2 && outcome.pages == 1)
        #expect(outcome.resume.allBullets.allSatisfy { $0.verified })
        #expect(outcome.resume.allBullets.count == 7)
    }
}

@Suite("Build repository")
struct BuildRepositoryTests {
    @Test func bothTablesAreStrictAndSync() async throws {
        let db = try await migrated()
        for table in ["build", "artifact"] {
            let strict = try await db.query("SELECT strict FROM pragma_table_list WHERE name = ?", [.text(table)])
            #expect(strict.first?.int("strict") == 1, "\(table) is not STRICT")
            let columns = try await db.query("SELECT name FROM pragma_table_info(?)", [.text(table)])
                .compactMap { $0.string("name") }
            #expect(columns.contains("updated_hlc") && columns.contains("deleted"), "\(table) can't sync")
        }
    }

    @Test func aBuildRecordsItsVersionModeResultAndFiles() async throws {
        let db = try await migrated()
        let repo = BuildRepository(db)
        let job = JobID(canonicalURL: "https://jobs.example.com/northline")
        let id = try await repo.create(job: job, mode: .strict, masterVersion: 7)
        #expect(try await repo.build(id)?.status == .queued)
        try await repo.start(id)
        #expect(try await repo.builds(status: [.queued, .running]).map(\.id) == [id])
        let resume = TailoredResume(header: .init(name: "Jordan Rivera"), summary: "Backend developer.")
        let score = MatchScore.score(resume, for: WriterFixtures.requirements)
        try await repo.finish(id, content: resume, score: score, iterations: 2)
        let done = try #require(try await repo.build(id))
        #expect(done.status == .done && done.masterVersion == 7 && done.mode == .strict && done.iterations == 2)
        #expect(done.content == resume && done.score == score && done.finishedAt != nil)
        _ = try await repo.addArtifact(build: id, kind: "resume", sha256: "abc", localPath: "/tmp/x.pdf")
        #expect(try await repo.artifacts(for: id).map(\.kind) == ["resume"])

        let second = try await repo.create(job: job, mode: .lite, masterVersion: 8)
        try await repo.fail(second, error: "Daily AI budget reached")
        #expect(try await repo.builds(for: job).map(\.id) == [second, id])  // newest first
        #expect(try await repo.build(second)?.error == "Daily AI budget reached")
        let other = try await repo.create(
            job: JobID(canonicalURL: "https://jobs.example.com/maplepay"), mode: .strict, masterVersion: 8)
        #expect(try await repo.recent(limit: 2).map(\.id) == [other, second])  // every job, newest first
    }

    /// A build started again after a quit saves its PDF again: the new record replaces the old.
    @Test func aBuildKeepsOneFileOfEachKind() async throws {
        let db = try await migrated()
        let repo = BuildRepository(db)
        let id = try await repo.create(
            job: JobID(canonicalURL: "https://jobs.example.com/northline"), mode: .strict, masterVersion: 1)
        _ = try await repo.addArtifact(build: id, kind: "resume", sha256: "first", localPath: "/tmp/r.pdf")
        _ = try await repo.addArtifact(build: id, kind: "cover_letter", sha256: "letter", localPath: "/tmp/c.pdf")
        let again = try await repo.addArtifact(build: id, kind: "resume", sha256: "second", localPath: "/tmp/r.pdf")
        let files = try await repo.artifacts(for: id)
        #expect(files.map(\.kind) == ["cover_letter", "resume"])
        #expect(files.last?.id == again && files.last?.sha256 == "second")
    }
}
