import Foundation
import LLM
import MasterResume
import Testing

@testable import Tailoring

/// The four writers against a real model, for the sample resume and the T28 sample posting. Each
/// reply is saved to `Tests/Fixtures/writers/` for `RecordedWriterTests`.
/// Opt-in and live: `scripts/live-llm.sh LiveWriter` (the Gemini key comes from your Keychain).
@Suite(
    "Live writers", .enabled(if: ProcessInfo.processInfo.environment["KAIROS_LIVE_LLM"] == "1", "Set KAIROS_LIVE_LLM=1")
)
struct LiveWriterTests {
    static let model = ProcessInfo.processInfo.environment["KAIROS_WRITER_MODEL"] ?? "gemini-flash-lite-latest"

    @Test func allFourWritersOnGemini() async throws {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            print("live: GEMINI_API_KEY not set; skipping")
            return
        }
        let client = LLMClient(
            keys: [OpenAICompatibleProvider(preset: .gemini, key: key)], policy: ClientPolicy(preset: .gemini))
        let inputs = WriterFixtures.inputs()
        let polish = Polish(locale: .canada)

        let experience = try await run(client, WriteExperienceTask(), inputs.experience)
        for entry in WriteExperienceTask.written(experience.output, input: inputs.experience) {
            for bullet in polish.bullets(entry.bullets.map(\.text)) { print("live:   • \(bullet)") }
        }
        let projects = try await run(client, WriteProjectsTask(), inputs.projects)
        for entry in WriteProjectsTask.written(projects.output, input: inputs.projects) {
            for bullet in polish.bullets(entry.bullets.map(\.text)) { print("live:   • \(bullet)") }
        }
        let summary = try await run(client, WriteSummaryTask(), inputs.summary)
        print("live:   \(polish.text(summary.output.summary))")
        let skills = try await run(client, WriteSkillsTask(), inputs.skills)
        for group in WriteSkillsTask.groups(skills.output, input: inputs.skills) {
            print("live:   \(group.label): \(group.skills.joined(separator: ", "))")
        }
    }

    /// The cover letter for the sample posting. `scripts/live-llm.sh coverLetterOnGemini`
    @Test func coverLetterOnGemini() async throws {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            print("live: GEMINI_API_KEY not set; skipping")
            return
        }
        let client = LLMClient(
            keys: [OpenAICompatibleProvider(preset: .gemini, key: key)], policy: ClientPolicy(preset: .gemini))
        let input = WriterFixtures.coverLetterInput()
        let result = try await run(client, CoverLetterTask(), input)
        let letter = CoverLetterTask.letter(
            result.output, input: input, header: TailoredResume.Header(Sample.resume.header), date: Date())
        print("live:   \(letter.greeting)")
        for paragraph in letter.paragraphs { print("live:   \(paragraph)") }
    }

    /// Stretch mode's gap bullets for the two requirements only Can-discuss skills answer.
    /// `scripts/live-llm.sh gapBulletsOnGemini`
    @Test func gapBulletsOnGemini() async throws {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            print("live: GEMINI_API_KEY not set; skipping")
            return
        }
        let client = LLMClient(
            keys: [OpenAICompatibleProvider(preset: .gemini, key: key)], policy: ClientPolicy(preset: .gemini))
        let input = WriterFixtures.gapInput(perRole: 2)
        let result = try await run(client, GapBulletsTask(), input)
        for (entry, bullets) in GapBulletsTask.written(result.output, input: input) {
            let role = input.roles.first { $0.entryID == entry }?.organization ?? "?"
            for bullet in bullets { print("live:   • [\(role) · \(bullet.covers ?? "")] \(bullet.text)") }
        }
    }

    private func run<T: LLMTask>(_ client: LLMClient, _ task: T, _ input: T.Input) async throws -> LLMResult<T.Output> {
        let defaults = TaskDefaults.catalog[T.id]!
        let result = try await client.run(
            task, input: input,
            options: RunOptions(
                model: Self.model, budget: defaults.budget, temperature: defaults.temperature,
                timeoutSeconds: defaults.timeoutSeconds))
        print(
            "live: \(T.id) · \(result.outcome.rawValue) · \(result.attempts) call(s) · out "
                + "\(result.outputTokens.map(String.init) ?? "?") · \(result.latency)")
        try Data(result.json.utf8).write(
            to: RecordedWriterTests.folder.appending(path: "\(T.id.rawValue)-\(Self.model).json"))
        return result
    }
}

/// The inputs the live run used, rebuilt the same way for the offline checks.
enum WriterFixtures {
    static let requirements = JobRequirements(
        musts: [
            "3+ years building services in Go or Java", "Strong PostgreSQL",
            "Experience with message queues such as RabbitMQ or Kafka", "Legally entitled to work in Canada",
        ], nices: ["Kubernetes", "gRPC", "French"], domains: ["logistics"])

    static func inputs() -> (
        experience: WriteSectionInput, projects: WriteSectionInput, summary: WriteSummaryInput,
        skills: WriteSkillsInput
    ) {
        let brief = WriterBrief(jobTitle: "Backend Developer II", requirements: requirements, locale: .canada)
        let selection = Selector(now: Date(timeIntervalSince1970: 1_790_000_000)).select(
            from: Sample.resume, for: requirements)
        let verifier = Verifier(resume: Sample.resume, hiringCompany: "Northline Freight")
        return (
            WriteSectionInput(
                brief: brief, entries: selection.experience, skills: selection.skills, verifier: verifier),
            WriteSectionInput(brief: brief, entries: selection.projects, skills: selection.skills, verifier: verifier),
            WriteSummaryInput(brief: brief, selection: selection, totalYears: 5, verifier: verifier),
            WriteSkillsInput(brief: brief, skills: selection.skills)
        )
    }

    /// The writer fixtures' posting plus two requirements only Can-discuss skills answer.
    static let stretchRequirements = JobRequirements(
        musts: requirements.musts, nices: requirements.nices + ["Infrastructure as code with Terraform", "Rust"],
        domains: requirements.domains)

    /// A written resume: the sample's first two roles with one bullet each.
    static func written() -> TailoredResume {
        TailoredResume(
            header: .init(name: "Jordan Rivera"), summary: nil, skills: [],
            experience: [
                .init(
                    entryID: Sample.harbourline.id, title: "Software Developer, Backend",
                    organization: "Harbourline Logistics", dates: "Mar 2022 – Present",
                    bullets: [TailoredBullet(text: Sample.pipeline.text, sourceIDs: [Sample.pipeline.id])]),
                .init(
                    entryID: Sample.rivet.id, title: "Junior Developer", organization: "Rivet Studio",
                    dates: "Jun 2020 – Feb 2022",
                    bullets: [TailoredBullet(text: Sample.apis.text, sourceIDs: [Sample.apis.id])]),
            ], projects: [], education: [], certifications: [], languages: nil)
    }

    /// The letter for the same posting, with one of Northline's products to keep out.
    static func coverLetterInput() -> CoverLetterInput {
        let selection = Selector(now: Date(timeIntervalSince1970: 1_790_000_000)).select(
            from: Sample.resume, for: requirements)
        return CoverLetterInput(
            brief: WriterBrief(jobTitle: "Backend Developer II", requirements: requirements, locale: .canada),
            company: "Northline Freight", entries: selection.experience + selection.projects,
            skills: selection.skills, totalYears: 5,
            verifier: Verifier(resume: Sample.resume, companyProducts: ["FreightOS"]))
    }

    static func gapInput(perRole: Int = 1, requirements: JobRequirements = stretchRequirements) -> GapBulletsInput {
        GapBulletsInput(
            brief: WriterBrief(jobTitle: "Backend Developer II", requirements: requirements, locale: .canada),
            written: written(), master: Sample.resume, perRole: perRole,
            verifier: Verifier(resume: Sample.resume, mode: .stretch, hiringCompany: "Northline Freight"))
    }
}

/// Offline: every recorded writer reply still passes its task's checks, the strict verifier included.
@Suite("Recorded writer replies")
struct RecordedWriterTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/writers")

    @Test func everyRecordedReplyStillPasses() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path()).filter {
            $0.hasSuffix(".json")
        }
        #expect(files.count >= 4, "record replies with scripts/live-llm.sh LiveWriter")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let inputs = WriterFixtures.inputs()
        for file in files {
            let data = try Data(contentsOf: Self.folder.appending(path: file))
            if file.hasPrefix("writeExperience-") {
                try WriteExperienceTask().check(
                    try decoder.decode(SectionOutput.self, from: data), for: inputs.experience)
            } else if file.hasPrefix("writeProjects-") {
                try WriteProjectsTask().check(try decoder.decode(SectionOutput.self, from: data), for: inputs.projects)
            } else if file.hasPrefix("writeSummary-") {
                try WriteSummaryTask().check(try decoder.decode(SummaryOutput.self, from: data), for: inputs.summary)
            } else if file.hasPrefix("writeSkills-") {
                try WriteSkillsTask().check(try decoder.decode(SkillsOutput.self, from: data), for: inputs.skills)
            } else if file.hasPrefix("coverLetter-") {
                try CoverLetterTask().check(
                    try decoder.decode(CoverLetterOutput.self, from: data), for: WriterFixtures.coverLetterInput())
            } else if file.hasPrefix("gapBullets-") {
                try GapBulletsTask().check(
                    try decoder.decode(GapBulletsOutput.self, from: data), for: WriterFixtures.gapInput(perRole: 2))
            } else {
                Issue.record("\(file) isn't a writer reply")
            }
        }
    }
}
