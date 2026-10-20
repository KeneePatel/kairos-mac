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
            } else {
                Issue.record("\(file) isn't a writer reply")
            }
        }
    }
}
