import Foundation
import Testing

@testable import LLM
@testable import Screening

/// `analyzeJob` against real models on the sample posting. Each reply is saved to
/// `Tests/Fixtures/screening/` for `RecordedAnalysisTests`; replies hold the model's answer only.
/// Opt-in and live: `scripts/live-llm.sh LiveAnalyzeJob` (the Gemini key comes from your Keychain).
@Suite(
    "Live job analysis",
    .enabled(if: ProcessInfo.processInfo.environment["KAIROS_LIVE_LLM"] == "1", "Set KAIROS_LIVE_LLM=1"))
struct LiveAnalyzeJobTests {
    @Test func geminiFlashLite() async throws {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            print("live: GEMINI_API_KEY not set; skipping Gemini")
            return
        }
        let provider = OpenAICompatibleProvider(preset: .gemini, key: key)
        await Self.run(
            LLMClient(keys: [provider], policy: ClientPolicy(preset: .gemini)), model: "gemini-flash-lite-latest",
            effort: nil, fixture: "analyzeJob-gemini-flash-lite-latest.json")
    }

    /// Local models run with thinking off by default (decided 2026-10-19).
    @Test func ollamaThinkingOff() async throws {
        await Self.ollama(effort: ReasoningEffort.none)
    }

    /// The T20 re-check of the merged nice-to-haves. Thinking is slow on a 4B model, so this one
    /// call gets 15 minutes and no retries.
    @Test func ollamaThinkingOn() async throws {
        await Self.ollama(effort: .medium)
    }

    static func ollama(effort: ReasoningEffort) async {
        let model = ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "qwen3.5:4B"
        let local = ProviderPreset.ollamaLocal
        let preset =
            effort == ReasoningEffort.none
            ? local
            : ProviderPreset(
                id: local.id, name: local.name, baseURL: local.baseURL, needsKey: false, isLocal: true,
                structuredOutput: local.structuredOutput, acceptsReasoningEffort: true,
                maxTokensField: local.maxTokensField, defaultModels: [:], requestsPerMinute: 30, timeoutSeconds: 900)
        let provider = OpenAICompatibleProvider(preset: preset, key: nil)
        guard (try? await provider.listModels())?.contains(model) == true else {
            print("live: Ollama isn't running or lacks \(model); skipping")
            return
        }
        var policy = ClientPolicy(preset: preset)
        policy.attempts = effort == ReasoningEffort.none ? policy.attempts : 1
        await run(
            LLMClient(keys: [provider], policy: policy), model: model, effort: effort,
            fixture:
                "analyzeJob-\(model.replacing(":", with: "_"))-thinking-\(effort == ReasoningEffort.none ? "off" : "on").json"
        )
    }

    static func run(_ client: LLMClient, model: String, effort: ReasoningEffort?, fixture: String) async {
        let defaults = TaskDefaults.catalog[.analyzeJob]!
        // Thinking spends hidden output tokens (about 2,000 per posting in T20) before the answer.
        let thinking = effort != nil && effort != ReasoningEffort.none
        let budget = thinking ? TokenBudget(input: defaults.budget.input, output: 6_000) : defaults.budget
        let options = RunOptions(
            model: model, budget: budget, temperature: defaults.temperature, reasoningEffort: effort,
            timeoutSeconds: defaults.timeoutSeconds)
        do {
            let input = sampleInput()
            let result = try await client.run(AnalyzeJobTask(), input: input, options: options)
            let analysis = JobAnalysis(result.output, input: input)
            print(
                "live: \(fixture) · \(result.outcome.rawValue) · \(result.attempts) call(s) · tokens in "
                    + "\(result.inputTokens.map(String.init) ?? "?") out \(result.outputTokens.map(String.init) ?? "?")"
                    + " · \(result.latency)")
            for requirement in analysis.requirements {
                print(
                    "live:   \(requirement.kind.rawValue)/\(requirement.category?.rawValue ?? "-") \(requirement.text)"
                        + " → \(requirement.effectiveMatch.rawValue) \(requirement.evidence ?? [])")
            }
            print(
                "live:   years \(analysis.yearsRequired.map(String.init) ?? "-") · \(analysis.seniority?.rawValue ?? "-")"
                    + " · \(analysis.domains) · \(analysis.flags)")
            try Data(result.json.utf8).write(to: RecordedAnalysisTests.folder.appending(path: fixture))
        } catch {
            print("live: \(fixture) · FAILED: \(error)")
        }
    }
}
