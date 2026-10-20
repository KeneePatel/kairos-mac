import Foundation
import LLM
import Testing

@testable import Screening

/// Offline checks on real `analyzeJob` replies to the sample posting, recorded by
/// `LiveAnalyzeJobTests`: each passes the schema and the task's checks, and its requirements match
/// a hand labelling of the posting at the SPEC §5.5 prompt-eval bar.
@Suite("Recorded job analyses")
struct RecordedAnalysisTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/screening")

    /// The sample posting, labelled by hand: each requirement's topic, must or nice, and the skill
    /// of yours that covers it.
    static var labels: [(topic: String, pattern: Regex<Substring>, kind: JobAnalysis.Requirement.Kind, skill: String?)]
    {
        [
            ("Go or Java", /\bgo\b|\bjava\b/, .must, "Go"), ("PostgreSQL", /postgres/, .must, "PostgreSQL"),
            ("message queues", /rabbitmq|kafka|message queue/, .must, "Kafka"),
            ("work authorization", /canada|entitled|authori[sz]|sponsor/, .must, nil),
            ("Kubernetes", /kubernetes/, .nice, nil), ("gRPC", /grpc/, .nice, nil), ("French", /french/, .nice, nil),
        ]
    }

    /// Replies that fall short for a reason we've recorded, so the record stays honest without
    /// failing the build. If a re-recorded reply no longer shows the gap, the test says so.
    static let knownGaps: [String: String] = [
        "analyzeJob-qwen3.5_4B-thinking-off.json":
            "qwen3.5:4B with thinking off lists every must-have but none of the nice-to-haves, even when the prompt "
            + "names them (2026-10-19). Gemini Flash-Lite lists all seven."
    ]

    static func replies() throws -> [(name: String, text: String)] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path()).filter { $0.hasSuffix(".json") }.sorted()
            .map { ($0, try String(contentsOf: folder.appending(path: $0), encoding: .utf8)) }
    }

    @Test func everyRecordedReplyIsAnAccurateAnalysis() throws {
        let replies = try Self.replies()
        #expect(replies.count >= 2, "expected Gemini and Ollama replies in Fixtures/screening")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        for (name, text) in replies {
            #expect(
                SchemaValidator.issues(in: try JSONValue(parsing: text), against: AnalyzeJobTask.outputSchema).isEmpty)
            let output = try decoder.decode(AnalyzeJobTask.Output.self, from: Data(text.utf8))
            let input = sampleInput()
            try AnalyzeJobTask().check(output, for: input)
            let analysis = JobAnalysis(output, input: input)

            // SPEC §5.5's bar is for must-haves: precision over the musts listed, recall over the labelled ones.
            var found: Set<String> = []
            var wrong: [String] = []
            for requirement in analysis.requirements {
                let label = Self.labels.first { requirement.text.lowercased().contains($0.pattern) }
                if let label, label.kind == requirement.kind, requirement.matchedSkill == label.skill {
                    found.insert(label.topic)
                } else {
                    wrong.append(
                        "\(requirement.kind.rawValue) \(requirement.text) → \(requirement.matchedSkill ?? "-")")
                }
            }
            let musts = Self.labels.filter { $0.kind == .must }.map(\.topic)
            let nices = Self.labels.filter { $0.kind == .nice }.map(\.topic)
            let listedMusts = analysis.requirements.filter { $0.kind == .must }.count
            let mustPrecision = Double(found.intersection(musts).count) / Double(max(listedMusts, 1))
            let mustRecall = Double(found.intersection(musts).count) / Double(musts.count)
            let niceRecall = Double(found.intersection(nices).count) / Double(nices.count)
            print("recorded: \(name) must precision \(mustPrecision) recall \(mustRecall) · nice recall \(niceRecall)")
            #expect(mustPrecision >= 0.85, "\(name): \(wrong)")
            #expect(mustRecall >= 0.80, "\(name): found \(found.sorted())")
            #expect(wrong.isEmpty, "\(name): \(wrong)")
            if let reason = Self.knownGaps[name] {
                withKnownIssue(Comment(rawValue: reason)) {
                    #expect(niceRecall >= 0.80, "\(name): found \(found.sorted())")
                }
            } else {
                #expect(niceRecall >= 0.80, "\(name): found \(found.sorted())")
            }
            #expect(analysis.yearsRequired == 3, "\(name)")
            #expect(analysis.flags.sponsorship == .notOffered && analysis.flags.french == .asset, "\(name)")
            #expect(analysis.flags.remoteScope == .hybrid, "\(name)")
        }
    }
}
