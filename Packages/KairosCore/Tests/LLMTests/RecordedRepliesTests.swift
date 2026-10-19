import Foundation
import Testing

@testable import LLM

/// Offline checks on the real replies captured by spike T20 (`Tests/Fixtures/llm/`): every success
/// passes our schema validator, and its requirements match a hand labelling of the sample posting.
@Suite("Recorded replies (T20)")
struct RecordedRepliesTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/llm")

    /// The sample posting, labelled by hand: what each requirement is about, and must or nice.
    static var labels: [(topic: String, pattern: Regex<Substring>, kind: String)] {
        [
            ("Go or Java", /\bgo\b|\bjava\b/, "must"),
            ("PostgreSQL", /postgres/, "must"),
            ("message queues", /rabbitmq|kafka|message queue/, "must"),
            ("work authorization", /canada|entitled|authori[sz]|sponsor/, "must"),
            ("Kubernetes", /kubernetes/, "nice"),
            ("gRPC", /grpc/, "nice"),
            ("French", /french/, "nice"),
        ]
    }

    static func replies() throws -> [(name: String, body: JSONValue)] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path()).filter { $0.hasSuffix(".json") }.sorted()
            .map { name in
                let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
                return (name, try JSONValue(parsing: text))
            }
    }

    @Test func everySuccessfulReplyPassesTheSchema() throws {
        let successes = try Self.replies().compactMap { reply in
            LiveStructuredOutputTests.content(of: reply.body).map { (reply.name, $0) }
        }
        #expect(successes.count >= 3, "expected Gemini and Ollama successes in the fixtures")
        for (name, content) in successes {
            let value = try JSONValue(parsing: Self.unfenced(content))
            let issues = SchemaValidator.issues(in: value, against: LiveStructuredOutputTests.schema)
            #expect(issues.isEmpty, "\(name): \(issues)")
        }
    }

    @Test func everySuccessfulReplyFindsTheRequirements() throws {
        for reply in try Self.replies() {
            guard let content = LiveStructuredOutputTests.content(of: reply.body),
                case .object(let fields) = try JSONValue(parsing: Self.unfenced(content)),
                case .array(let requirements)? = fields["requirements"]
            else { continue }
            var found: Set<String> = []
            var wrong: [String] = []
            for case .object(let requirement) in requirements {
                guard case .string(let text)? = requirement["text"], case .string(let kind)? = requirement["kind"]
                else {
                    continue
                }
                let label = Self.labels.first { text.lowercased().contains($0.pattern) }
                if let label, label.kind == kind {
                    found.insert(label.topic)
                } else {
                    wrong.append(text)
                }
            }
            let precision = Double(found.count) / Double(max(requirements.count, 1))
            let recall = Double(found.count) / Double(Self.labels.count)
            print("recorded: \(reply.name) precision \(precision) recall \(recall) extra: \(wrong)")
            // The prompt-eval bar from SPEC §5.5, applied to this one posting.
            #expect(precision >= 0.85, "\(reply.name): \(wrong)")
            if let reason = Self.knownMerges[reply.name] {
                withKnownIssue(Comment(rawValue: reason)) {
                    #expect(recall >= 0.80, "\(reply.name): found \(found.sorted())")
                }
            } else {
                #expect(recall >= 0.80, "\(reply.name): found \(found.sorted())")
            }
            #expect(fields["years_required"] == .number(3), "\(reply.name)")
        }
    }

    /// Replies that fall short for a reason we've recorded, so the record stays honest without
    /// failing the build. If a re-recorded reply no longer shows the problem, the test says so.
    static let knownMerges: [String: String] = [
        "ollama-plain-qwen3.5_4B.json":
            "qwen3.5:4B with thinking merged \"Kubernetes, gRPC, French\" into one requirement (2026-10-19). "
            + "analyzeJob's prompt (T28) must ask for one requirement per item."
    ]

    @Test func theErrorShapesTheAdapterMustParseAreRecorded() throws {
        let replies = Dictionary(uniqueKeysWithValues: try Self.replies().map { ($0.name, $0.body) })
        // Gemini's OpenAI-compatible endpoint wraps errors in an array, and a model with no
        // free-tier quota answers 429 with a retry delay of hours.
        guard case .array(let geminiErrors)? = replies["gemini-error-429-free-tier-limit-0.json"],
            case .object(let wrapper)? = geminiErrors.first, case .object(let error)? = wrapper["error"]
        else {
            Issue.record("Gemini 429 fixture missing or reshaped")
            return
        }
        #expect(error["code"] == .number(429))
        #expect(error["status"] == .string("RESOURCE_EXHAUSTED"))
        // Ollama refuses `response_format` for models without structured output (HTTP 501).
        guard case .object(let ollama)? = replies["ollama-schema-qwen3.5_4B.json"],
            case .object(let ollamaError)? = ollama["error"]
        else {
            Issue.record("Ollama structured-output fixture missing or reshaped")
            return
        }
        #expect(ollamaError["message"] == .string("structured output is unavailable"))
    }

    @Test func noFixtureHoldsAKeyOrASignature() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.folder.path()) {
            let text = try String(contentsOf: Self.folder.appending(path: name), encoding: .utf8)
            #expect(!text.contains(/AIza[0-9A-Za-z_\-]{20,}/), "\(name) holds something shaped like a Google key")
            #expect(!text.contains(/"thought_signature"\s*:\s*"(?!redacted)/), "\(name) holds a thought signature")
        }
    }

    /// Replies sometimes come wrapped in a Markdown code fence (Ollama with thinking off did).
    static func unfenced(_ content: String) -> String {
        content.replacing(/^\s*```(?:json)?\s*|\s*```\s*$/, with: "")
    }
}
