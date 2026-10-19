import Foundation
import LLM
import Testing

@testable import MasterResume

/// Resume import end to end against real models, printing the exact outcome or failure.
/// Opt-in and live: `scripts/live-llm.sh LiveImport` (the Gemini key comes from your Keychain).
@Suite(
    "Live import", .enabled(if: ProcessInfo.processInfo.environment["KAIROS_LIVE_LLM"] == "1", "Set KAIROS_LIVE_LLM=1"))
struct LiveImportTests {
    /// A realistic resume for the design's sample persona: fixtures only.
    static let resume = """
        JORDAN RIVERA
        Toronto, ON · (416) 555-0123 · jordan.rivera@example.com · linkedin.com/in/jordan-rivera · github.com/jrivera

        SUMMARY
        Backend developer with 5+ years building event-driven services in Go and Java for logistics and fintech.

        EXPERIENCE
        Software Developer, Backend — Harbourline Logistics, Toronto, ON          Mar 2022 – Present
        • Built an event pipeline in Go handling 4.2M events/day with p99 under 120 ms.
        • Onboarded 11 carriers in 4 days instead of 3 weeks by designing a gRPC integration kit.
        • Migrated 14 services to Kubernetes with a shared Helm chart; deploys dropped from 25 to 6 minutes.
        • Led the five-person on-call rotation and cut repeat incidents by 40% over two quarters.

        Junior Developer — Rivet Studio, Toronto, ON                              Jun 2020 – Feb 2022
        • Shipped REST APIs in Django and PostgreSQL for 30+ client projects.
        • Introduced GitHub Actions CI, cutting release prep from a day to an hour.

        Developer Intern — Maplepay, Waterloo, ON                                 May 2019 – Aug 2019
        • Wrote reconciliation jobs in Java that matched 2M card transactions nightly.

        PROJECTS
        Dockyard — open-source Go CLI (2023 – Present)
        • Finds and removes dangling Docker images and volumes; 400+ stars.

        EDUCATION
        University of Waterloo — BMath, Computer Science, 2015 – 2019. Dean's list (3 terms).

        SKILLS
        Languages: Go, Java, Python, SQL · Infrastructure: Kubernetes, Docker, Helm, Terraform, AWS
        Data: PostgreSQL, Kafka, RabbitMQ, Redis · Tools: GitHub Actions, Grafana, Prometheus

        CERTIFICATIONS
        AWS Solutions Architect – Associate (2024)

        LANGUAGES
        English (native), French (conversational)
        """

    static func header() -> ResumeHeader {
        var header = ResumeHeader()
        header.fullName = "Jordan Rivera"
        header.email = "jordan.rivera@example.com"
        header.phone = "+14165550123"
        header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
        header.gitHubURL = "https://github.com/jrivera"
        return header
    }

    @Test func geminiFlash() async throws {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            print("live: GEMINI_API_KEY not set; skipping Gemini")
            return
        }
        let provider = OpenAICompatibleProvider(preset: .gemini, key: key)
        await Self.run(LLMClient(keys: [provider], policy: ClientPolicy(preset: .gemini)), model: "gemini-flash-latest")
    }

    @Test func ollama() async throws {
        let model = ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "qwen3.5:4B"
        let provider = OpenAICompatibleProvider(preset: .ollamaLocal, key: nil)
        guard (try? await provider.listModels())?.contains(model) == true else {
            print("live: Ollama isn't running or lacks \(model); skipping")
            return
        }
        await Self.run(LLMClient(keys: [provider], policy: ClientPolicy(preset: .ollamaLocal)), model: model)
    }

    static func run(_ client: LLMClient, model: String) async {
        let defaults = TaskDefaults.catalog[.importResume]!
        let options = RunOptions(
            model: model, budget: defaults.budget, temperature: defaults.temperature,
            timeoutSeconds: defaults.timeoutSeconds)
        do {
            let prepared = try ResumeImporter.prepare(resume, header: header())
            let result = try await client.run(ImportResumeTask(), input: prepared, options: options)
            let draft = ImportDraft(result.output)
            print(
                "live: \(model) · \(result.outcome.rawValue) · \(result.attempts) call(s) · tokens in "
                    + "\(result.inputTokens.map(String.init) ?? "?") out \(result.outputTokens.map(String.init) ?? "?") · \(result.latency)"
            )
            print(
                "live:   \(draft.entries.count) entries \(draft.entries.map(\.kind.rawValue)) · \(draft.skills.count) skills"
            )
            for entry in draft.entries {
                let dates =
                    "\(entry.start?.description ?? "?")–\(entry.isCurrent ? "now" : entry.end?.description ?? "?")"
                print(
                    "live:   \(String(describing: entry.fields).prefix(110)) · \(dates) · \(entry.bullets.count) bullets"
                )
            }
        } catch {
            print("live: \(model) · FAILED: \(error)")
        }
    }
}
