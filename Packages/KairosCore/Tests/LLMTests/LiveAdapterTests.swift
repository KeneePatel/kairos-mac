import Foundation
import Testing

@testable import LLM

/// T20a: the spike's open items, re-checked through the real adapter and client rather than the
/// spike harness. Opt-in and live; run it in your own terminal so the key stays out of transcripts:
///
///     KAIROS_LIVE_LLM=1 GEMINI_API_KEY=… swift test --package-path Packages/KairosCore --filter LiveAdapter
@Suite(
    "Live adapter (T20a)",
    .enabled(if: ProcessInfo.processInfo.environment["KAIROS_LIVE_LLM"] == "1", "Set KAIROS_LIVE_LLM=1"))
struct LiveAdapterTests {
    /// The spike's posting and schema, as a typed task.
    struct SampleTask: LLMTask {
        struct Requirement: Decodable, Sendable {
            let text: String
            let kind: String
        }
        struct Output: Decodable, Sendable {
            let requirements: [Requirement]
            let yearsRequired: Int
        }
        static let id = TaskID.analyzeJob
        static let promptVersion = 1
        static let outputSchema = LiveStructuredOutputTests.schema
        func messages(for input: String, budget: TokenBudget) -> [ChatMessage] {
            [.system(LiveStructuredOutputTests.system), .user("<job_posting>\n\(input)\n</job_posting>")]
        }
        func check(_ output: Output, for input: String) throws {}
    }

    @Test func geminiFlashAndFlashLiteThroughTheClient() async throws {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            print("live: GEMINI_API_KEY not set; skipping Gemini")
            return
        }
        let provider = OpenAICompatibleProvider(preset: .gemini, key: key)
        let client = LLMClient(keys: [provider], policy: ClientPolicy(preset: .gemini))
        for model in ["gemini-flash-latest", "gemini-flash-lite-latest"] {
            await Self.run(client, model: model, label: "gemini")
        }
    }

    @Test func ollamaThroughTheClient() async throws {
        let model = ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "qwen3.5:4B"
        let capabilities = ModelCapabilities()
        let provider = OpenAICompatibleProvider(preset: .ollamaLocal, key: nil, capabilities: capabilities)
        guard (try? await provider.listModels())?.contains(model) == true else {
            print("live: Ollama isn't running or lacks \(model); skipping")
            return
        }
        let client = LLMClient(keys: [provider], policy: ClientPolicy(preset: .ollamaLocal))
        await Self.run(client, model: model, label: "ollama")
        print("live: ollama \(model) learned mode: \(capabilities.mode(for: model, preset: .jsonMode).rawValue)")
    }

    /// One typed run; prints the outcome rather than failing, since the point is to record behaviour.
    static func run(_ client: LLMClient, model: String, label: String) async {
        let options = RunOptions(
            model: model, budget: TokenBudget(input: 7_000, output: 1_500), temperature: 0, timeoutSeconds: 60)
        do {
            let result = try await client.run(SampleTask(), input: LiveStructuredOutputTests.posting, options: options)
            print(
                "live: \(label) \(model) · \(result.outcome.rawValue) · \(result.attempts) call(s) · "
                    + "\(result.output.requirements.count) requirements, \(result.output.yearsRequired) years · "
                    + "tokens in \(result.inputTokens.map(String.init) ?? "?") out \(result.outputTokens.map(String.init) ?? "?")"
                    + " (out includes hidden thinking) · \(result.latency)")
            for requirement in result.output.requirements { print("live:   \(requirement.kind): \(requirement.text)") }
        } catch {
            print("live: \(label) \(model) · failed: \(error) (\(error.code))")
        }
    }
}
