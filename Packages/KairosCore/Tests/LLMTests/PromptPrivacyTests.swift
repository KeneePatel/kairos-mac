import Foundation
import LLM
import MasterResume
import Screening
import Store
import Tailoring
import Testing

/// A fixture user with every contact detail filled in, some of them repeated where people put them
/// anyway (a bullet linking their GitHub, a business in their own name), and private settings that
/// must stay on this Mac. Fictional.
private enum Avery {
    static let header: ResumeHeader = {
        var header = ResumeHeader()
        header.fullName = "Avery Quill"
        header.email = "avery.quill@example.com"
        header.phone = "+14165550199"
        header.linkedInURL = "https://www.linkedin.com/in/avery-quill-77"
        header.gitHubURL = "https://github.com/averyquill"
        header.portfolioURL = "https://averyquill.dev"
        header.city = "Halifax"
        header.region = "NS"
        header.headline = "Data engineer"
        header.totalYears = 6
        return header
    }()

    /// Each contact value as it might be written.
    static let contactValues = [
        "Avery Quill", "Quill, Avery", "avery.quill@example.com", "4165550199", "416-555-0199", "(416) 555-0199",
        "416 555 0199", "416.555.0199", "linkedin.com/in/avery-quill-77", "averyquill",
    ]

    /// The private settings, as stored and as a resume might say them.
    static let privateValues = [
        "citizen", "permanent_resident", "permanent resident", "work_permit", "work permit", "needs_sponsorship",
        "sponsorship", "clearance", "hasClearance",
    ]

    static let profile = WorkProfile(
        authorization: [.canada: .citizen, .unitedStates: .needsSponsorship], hasClearance: true)

    static let resume: MasterResume = {
        let tidewater = ResumeEntry(
            fields: .experience(
                .init(employer: "Tidewater Analytics", title: "Data Engineer", location: "Halifax, NS")),
            start: YearMonth(year: 2021, month: 4), isCurrent: true,
            bullets: [
                ResumeBullet(
                    text: "Built Airflow pipelines in Python loading 80 GB a day into PostgreSQL.",
                    metrics: ["80 GB a day"], skills: ["Airflow", "Python", "PostgreSQL"]),
                ResumeBullet(
                    text:
                        "Open-sourced our data-quality checks at github.com/averyquill/tidy-checks, now used by 3 teams.",
                    skills: ["Python"]),
                ResumeBullet(text: "Cut dashboard load times from 9 s to 2 s with materialized views in PostgreSQL."),
            ])
        let consulting = ResumeEntry(
            fields: .experience(.init(employer: "Avery Quill Consulting", title: "Freelance Developer")),
            start: YearMonth(year: 2019, month: 1), end: YearMonth(year: 2021, month: 3),
            bullets: [ResumeBullet(text: "Built Django apps for 12 local clients.", skills: ["Django"])])
        let dockhand = ResumeEntry(
            fields: .project(
                .init(
                    name: "Dockhand", tech: ["Go", "Docker"], projectURL: "https://averyquill.dev/dockhand",
                    repoURL: "https://github.com/averyquill/dockhand")),
            start: YearMonth(year: 2023, month: 2), isCurrent: true,
            bullets: [
                ResumeBullet(text: "Go CLI that prunes stale Docker images; 250+ stars.", skills: ["Go", "Docker"])
            ])
        let college = ResumeEntry(
            fields: .education(.init(institution: "Northshore College", credential: "BSc", field: "Computer Science")))
        let english = ResumeEntry(fields: .language(.init(language: "English", proficiency: .native)))
        return MasterResume(
            header: header, entries: [tidewater, consulting, dockhand, college, english],
            skills: ["Python", "PostgreSQL", "Airflow", "Django", "Go", "Docker"].map { Skill(name: $0) } + [
                Skill(name: "dbt", level: .canDiscuss), Skill(name: "Snowflake", level: .canDiscuss),
            ])
    }()

    /// What the import reads: a resume as people write it, contact line, status line and all.
    static let resumeText = """
        Avery Quill
        avery.quill@example.com | (416) 555-0199 | linkedin.com/in/avery-quill-77 | github.com/averyquill | averyquill.dev
        Halifax, NS · Canadian citizen · Secret clearance · Will need sponsorship for US roles

        EXPERIENCE
        Data Engineer, Tidewater Analytics (Apr 2021 – present)
        - Built Airflow pipelines in Python loading 80 GB a day into PostgreSQL.
        - Open-sourced our data-quality checks at github.com/averyquill/tidy-checks.
        Freelance Developer, Avery Quill Consulting (2019 – 2021)
        - Built Django apps for 12 local clients, including a visa appointment tracker.
        """

    /// Mostly things Avery's bullets don't show, so the experience section scores low and the
    /// rewrite pass runs too; dbt is a Can-discuss skill, so Stretch adds a gap bullet.
    static let requirements = JobRequirements(
        musts: ["4+ years with Python", "Kubernetes", "Terraform", "Kafka", "Spark"],
        nices: ["dbt", "Go"], domains: ["analytics"])

    static let job = Job(
        canonicalURL: "https://jobs.example.com/harbourline/data", sourceID: UUID(), url: "https://jobs.example.com/2",
        dedupKey: "harbourline|data|toronto", company: "Harbourline Logistics", title: "Data Engineer",
        location: "Toronto, ON", region: "ON", country: .canada, remoteScope: .hybrid,
        descriptionMarkdown: "## Requirements\n- 4+ years with Python\n- Airflow\n- PostgreSQL\n## Nice to have\n- dbt",
        firstSeenAt: Date())
}

@Suite("Prompt privacy")
struct PromptPrivacyTests {
    /// Every prompt Kairos can send for Avery, by task: the import tasks and the analysis rendered
    /// directly, and the build's tasks as a whole Stretch build with a letter sends them.
    private func prompts() async throws -> [TaskID: [[ChatMessage]]] {
        var prompts: [TaskID: [[ChatMessage]]] = [:]
        let budget = TokenBudget(input: 10_000, output: 6_000)

        let text = try ResumeImporter.prepare(Avery.resumeText, header: Avery.header)
        prompts[.importResume] = [ImportResumeTask().messages(for: text, budget: budget)]

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let repo = try decoder.decode(
            GitHubRepo.self,
            from: Data(
                #"{"name":"dockhand","full_name":"averyquill/dockhand","description":"By Avery Quill, avery.quill@example.com","language":"Go","fork":false,"archived":false,"stargazers_count":250,"html_url":"https://github.com/averyquill/dockhand","created_at":"2023-02-01T00:00:00Z","pushed_at":"2026-09-01T00:00:00Z","topics":["docker"]}"#
                    .utf8))
        let readme = "# Dockhand\nMade by Avery Quill. Docs at https://averyquill.dev/dockhand, or call 416-555-0199."
        let input = ImportGitHubRepoTask.Input(repo: repo, languages: ["Go"], readme: readme, header: Avery.header)
        prompts[.importGitHubRepo] = [ImportGitHubRepoTask().messages(for: input, budget: budget)]

        let context = ScreeningContext(
            profile: Avery.profile, skills: Avery.resume.skills,
            languages: [.init(language: "English", proficiency: .native)], totalYears: 6)
        prompts[.analyzeJob] = [AnalyzeJobTask().messages(for: context.analysisInput(for: Avery.job), budget: budget)]

        // A Stretch build with a letter, every reply unusable, so each writer also falls back and
        // the rewrite pass runs: every build task sends at least once.
        let fake = FakeProvider(
            Dictionary(
                uniqueKeysWithValues: [
                    TaskID.writeExperience, .writeProjects, .writeSummary, .writeSkills, .rewriteSection, .gapBullets,
                    .coverLetter,
                ].map { ($0, Array(repeating: FakeProvider.Reply.reply("{}"), count: 12)) }))
        let client = LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 })
        let routes = Dictionary(
            uniqueKeysWithValues: TaskID.catalog.map { ($0, [ModelRef(provider: "fake", model: "flash")]) })
        let router = LLMRouter(
            clients: ["fake": client], routes: routes, budget: Budget(), log: CallLog(try Database(path: ":memory:")),
            cache: nil)
        _ = try await BuildLoop(router: router, master: Avery.resume).run(
            BuildRequest(
                jobTitle: Avery.job.title, company: Avery.job.company, requirements: Avery.requirements,
                locale: .canada, mode: .stretch, coverLetter: true))
        for request in fake.requests { prompts[request.task, default: []].append(request.messages) }
        return prompts
    }

    /// A task with a prompt must be in this test; one without (not built yet) can't send anything.
    @Test func everyTaskWithAPromptIsChecked() async throws {
        let checked = Set(try await prompts().keys)
        for task in TaskID.catalog where !checked.contains(task) {
            #expect(
                PromptLibrary.instructions(for: task, version: 1) == nil,
                "\(task.rawValue) has a prompt but isn't checked")
        }
        #expect(checked.count >= 10)
    }

    /// SPEC S15: no prompt ever contains a contact value, wherever the user wrote it.
    @Test func noPromptCarriesAContactValue() async throws {
        for (task, sent) in try await prompts() {
            let text = sent.flatMap { $0 }.map(\.content).joined(separator: "\n")
            for value in Avery.contactValues {
                #expect(!text.localizedCaseInsensitiveContains(value), "\(task.rawValue) sends “\(value)”")
            }
        }
    }

    /// Work authorization and clearance stay on this Mac, even when a resume states them.
    @Test func noPromptCarriesAPrivateSetting() async throws {
        for (task, sent) in try await prompts() {
            let data = sent.flatMap { $0 }.filter { $0.role == .user }.map(\.content).joined(separator: "\n")
            for value in Avery.privateValues {
                #expect(!data.localizedCaseInsensitiveContains(value), "\(task.rawValue) sends “\(value)”")
            }
        }
    }

    /// Only status phrases go: a resume about building a visa portal keeps its words.
    @Test func workStatusRedactionLeavesOrdinaryWorkAlone() {
        let text = "Built a visa appointment tracker and a clearance-sale banner for a citizen-science app."
        #expect(ContactRedactor.redactWorkStatus(text) == text)
        #expect(
            ContactRedactor.redactWorkStatus("Permanent resident of Canada; eligible to work in the US.")
                == "[removed]; [removed].")
    }
}
