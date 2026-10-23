import Foundation
import LLM
import MasterResume
import Render
import Store
import Tailoring
import Testing

/// One whole build against a real model and the real typst, for the sample persona and the T28
/// sample posting. Writes the PDF to `KAIROS_BUILD_OUT` (or the temporary folder) to look at.
/// Opt-in and live: `scripts/live-llm.sh LiveBuild` (the Gemini key comes from your Keychain).
@Suite(
    "Live build", .enabled(if: ProcessInfo.processInfo.environment["KAIROS_LIVE_LLM"] == "1", "Set KAIROS_LIVE_LLM=1"))
struct LiveBuildTests {
    @Test func aWholeBuildOnGeminiFlashLite() async throws {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            print("live: GEMINI_API_KEY not set; skipping")
            return
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let typst = repo.appending(path: "Vendor/typst/typst")
        guard FileManager.default.isExecutableFile(atPath: typst.path()) else {
            print("live: run scripts/fetch-typst.sh first")
            return
        }
        let db = try Database(path: ":memory:")
        let client = LLMClient(
            keys: [OpenAICompatibleProvider(preset: .gemini, key: key)], policy: ClientPolicy(preset: .gemini))
        let routes = Dictionary(
            uniqueKeysWithValues: [
                TaskID.writeExperience, .writeProjects, .writeSummary, .writeSkills, .rewriteSection,
            ]
            .map { ($0, [ModelRef(provider: "gemini", model: "gemini-flash-lite-latest")]) })
        let router = LLMRouter(
            clients: ["gemini": client], routes: routes, budget: Budget(), log: CallLog(db), cache: nil)
        let renderer = ResumeRenderer(runner: TypstRunner(executable: typst))
        let loop = BuildLoop(router: router, master: LiveSample.resume)
        let request = BuildRequest(
            jobTitle: "Backend Developer II", company: "Northline Freight",
            requirements: JobRequirements(
                musts: [
                    "3+ years building services in Go or Java", "Strong PostgreSQL",
                    "Experience with message queues such as RabbitMQ or Kafka", "Legally entitled to work in Canada",
                ], nices: ["Kubernetes", "gRPC", "French"], domains: ["logistics"]),
            locale: .canada)
        let started = ContinuousClock.now
        let outcome = try await loop.run(
            request, measure: { try await renderer.render(ResumeDocument($0)).pageLayout },
            progress: { print("live: step \($0)") })
        print("live: score \(outcome.score.total) · \(outcome.score.breakdown) · sections \(outcome.score.sections)")
        print(
            "live: rewrites \(outcome.rewrites) · fell back \(outcome.fellBack) · pages \(outcome.pages ?? -1) · "
                + "dropped \(outcome.dropped) · \(ContinuousClock.now - started)")
        let pdf = try await renderer.render(ResumeDocument(outcome.resume))
        let folder =
            ProcessInfo.processInfo.environment["KAIROS_BUILD_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let file = folder.appending(path: "live-build.pdf")
        try pdf.data.write(to: file)
        print("live: PDF \(file.path()) · \(pdf.pageCount) page(s)")
        #expect(outcome.resume.experience.allSatisfy { !$0.bullets.isEmpty })
    }
}

/// The design's sample persona with contact details (fixtures only).
enum LiveSample {
    static let resume: MasterResume = {
        var header = ResumeHeader()
        header.fullName = "Jordan Rivera"
        header.email = "jordan.rivera@example.com"
        header.phone = "+14165550123"
        header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
        header.gitHubURL = "https://github.com/jrivera"
        header.city = "Toronto"
        header.region = "ON"
        header.totalYears = 5
        func bullet(_ text: String, _ skills: [String] = []) -> ResumeBullet {
            ResumeBullet(text: text, skills: skills)
        }
        let entries = [
            ResumeEntry(
                fields: .experience(
                    .init(
                        employer: "Harbourline Logistics", title: "Software Developer, Backend", location: "Toronto, ON"
                    )),
                start: YearMonth(year: 2022, month: 3), isCurrent: true,
                bullets: [
                    bullet(
                        "Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms.",
                        ["Go", "Kafka"]),
                    bullet(
                        "Onboarded 11 carriers in 4 days instead of 3 weeks by designing a gRPC integration kit.",
                        ["gRPC"]),
                    bullet(
                        "Migrated 14 services to Kubernetes with a shared Helm chart; deploys dropped from 25 to 6 minutes.",
                        ["Kubernetes", "Helm"]),
                    bullet("Led the five-person on-call rotation and cut repeat incidents by 40% over two quarters."),
                ]),
            ResumeEntry(
                fields: .experience(
                    .init(employer: "Rivet Studio", title: "Junior Developer", location: "Toronto, ON")),
                start: YearMonth(year: 2020, month: 6), end: YearMonth(year: 2022, month: 2),
                bullets: [
                    bullet(
                        "Shipped REST APIs in Django and PostgreSQL for 30+ client projects.", ["Django", "PostgreSQL"]),
                    bullet("Introduced GitHub Actions CI, cutting release prep from a day to an hour."),
                ]),
            ResumeEntry(
                fields: .experience(.init(employer: "Maplepay", title: "Developer Intern", location: "Waterloo, ON")),
                start: YearMonth(year: 2019, month: 5), end: YearMonth(year: 2019, month: 8),
                bullets: [
                    bullet("Wrote reconciliation jobs in Java that matched 2M card transactions nightly.", ["Java"])
                ]),
            ResumeEntry(
                fields: .project(.init(name: "Dockyard", tech: ["Go", "Docker"])),
                start: YearMonth(year: 2023, month: 1),
                isCurrent: true,
                bullets: [bullet("Finds and removes dangling Docker images and volumes; 400+ stars.", ["Docker"])]),
            ResumeEntry(
                fields: .education(
                    .init(institution: "University of Waterloo", credential: "BMath", field: "Computer Science")),
                start: YearMonth(year: 2015, month: 9), end: YearMonth(year: 2019, month: 4)),
            ResumeEntry(
                fields: .certification(.init(name: "AWS Solutions Architect – Associate", issuer: "AWS")),
                start: YearMonth(year: 2024, month: 1)),
            ResumeEntry(fields: .language(.init(language: "English", proficiency: .native))),
            ResumeEntry(fields: .language(.init(language: "French", proficiency: .conversational))),
        ]
        let skills = ["Go", "Java", "Python", "PostgreSQL", "Kafka", "Kubernetes", "Docker", "gRPC", "Django", "Helm"]
        return MasterResume(header: header, entries: entries, skills: skills.map { Skill(name: $0) }, version: 1)
    }()
}
