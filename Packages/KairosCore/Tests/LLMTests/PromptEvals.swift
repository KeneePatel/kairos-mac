import Foundation
import LLM
import MasterResume
import Screening
import Store
import Testing

@testable import Tailoring

/// One of the 30 labelled postings in `Fixtures/evals/postings.json`.
struct EvalPosting: Decodable, Sendable {
    let id: String
    let title: String
    let company: String
    let location: String
    let country: String
    let description: String
    let musts: [String]
    let nices: [String]

    static func all() throws -> [EvalPosting] {
        struct File: Decodable { let postings: [EvalPosting] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/evals/postings.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).postings
    }

    var job: Job {
        Job(
            canonicalURL: "https://jobs.example.com/\(id)", sourceID: UUID(), url: "https://jobs.example.com/\(id)",
            dedupKey: id, company: company, title: title, location: location,
            country: Country(rawValue: country) ?? .canada, descriptionMarkdown: description, firstSeenAt: Date())
    }
}

/// Whether a requirement the model wrote is a hand label: they share a technology, or most of the
/// words of one appear in the other (so splitting "Apex and Lightning Web Components" in two, or
/// writing "Experience with Playwright or Selenium", still counts).
enum RequirementMatch {
    static func matches(_ predicted: String, _ label: String) -> Bool {
        let terms = Keywords.terms(in: label)
        if !terms.isEmpty, !terms.isDisjoint(with: Keywords.terms(in: predicted)) { return true }
        let labelWords = Keywords.keywords(in: label)
        let predictedWords = Keywords.keywords(in: predicted)
        guard !labelWords.isEmpty, !predictedWords.isEmpty else {
            return predicted.localizedCaseInsensitiveContains(label)
        }
        let shared = Double(labelWords.intersection(predictedWords).count)
        return shared >= max(1, Double(labelWords.count) / 2) || shared >= max(1, Double(predictedWords.count) / 2)
    }

    /// Predicted must-haves that are labels (precision's numerator) and labels found (recall's).
    static func score(predicted: [String], labels: [String]) -> (correct: [String], found: [String]) {
        (
            predicted.filter { text in labels.contains { matches(text, $0) } },
            labels.filter { label in predicted.contains { matches($0, label) } }
        )
    }
}

/// A task's first reply as the model wrote it: no check, so no repair (schema problems aside).
struct FirstWrite<Task: LLMTask>: LLMTask {
    typealias Input = Task.Input
    typealias Output = Task.Output
    static var id: TaskID { Task.id }
    static var promptVersion: Int { Task.promptVersion }
    static var outputSchema: JSONSchema { Task.outputSchema }

    let task: Task

    func messages(for input: Input, budget: TokenBudget) -> [ChatMessage] { task.messages(for: input, budget: budget) }
    func check(_ output: Output, for input: Input) throws {}
}

/// The eval's applicant: a backend and data generalist (fictional), so every posting finds roles to
/// write from.
enum EvalPersona {
    static let resume: MasterResume = {
        var header = ResumeHeader()
        header.fullName = "Robin Ashford"
        header.totalYears = 6
        let shipyard = ResumeEntry(
            fields: .experience(.init(employer: "Shipyard Software", title: "Software Developer")),
            start: YearMonth(year: 2022, month: 1), isCurrent: true,
            bullets: [
                ResumeBullet(
                    text: "Built Go services on PostgreSQL handling 3M API requests a day at p95 under 80 ms.",
                    metrics: ["3M requests a day", "p95 under 80 ms"], skills: ["Go", "PostgreSQL"]),
                ResumeBullet(
                    text:
                        "Moved 9 services to Kubernetes on AWS with Terraform, cutting deploy time from 30 to 8 minutes.",
                    metrics: ["30 to 8 minutes"], skills: ["Kubernetes", "AWS", "Terraform"]),
                ResumeBullet(
                    text: "Added Kafka event streaming between billing and shipping, retiring 4 nightly batch jobs.",
                    skills: ["Kafka"]),
                ResumeBullet(text: "Mentored 3 junior developers and ran the weekly on-call review."),
            ])
        let fieldwork = ResumeEntry(
            fields: .experience(.init(employer: "Fieldwork Data", title: "Data Developer")),
            start: YearMonth(year: 2019, month: 6), end: YearMonth(year: 2021, month: 12),
            bullets: [
                ResumeBullet(
                    text: "Wrote Python and Airflow pipelines loading 40 GB a day into Snowflake.",
                    metrics: ["40 GB a day"], skills: ["Python", "Airflow", "Snowflake"]),
                ResumeBullet(
                    text: "Built React and TypeScript dashboards used by 120 analysts.",
                    skills: ["React", "TypeScript"]),
                ResumeBullet(
                    text: "Tuned SQL reports, cutting the slowest from 6 minutes to 40 seconds.", skills: ["SQL"]),
            ])
        let tally = ResumeEntry(
            fields: .project(.init(name: "Tally", tech: ["Swift", "SwiftUI"])),
            start: YearMonth(year: 2023, month: 3), isCurrent: true,
            bullets: [
                ResumeBullet(text: "A SwiftUI budgeting app with 2,000 downloads.", skills: ["Swift", "SwiftUI"])
            ])
        let skills = [
            "Go", "Python", "PostgreSQL", "SQL", "Kubernetes", "AWS", "Terraform", "Kafka", "Airflow", "Snowflake",
            "React", "TypeScript", "Swift", "SwiftUI", "Docker",
        ]
        return MasterResume(
            header: header, entries: [shipyard, fieldwork, tally],
            skills: skills.map { Skill(name: $0) } + [Skill(name: "Rust", level: .canDiscuss)])
    }()
}

@Suite("Prompt eval fixtures")
struct PromptEvalFixtureTests {
    @Test func thereAreThirtyLabelledPostings() throws {
        let postings = try EvalPosting.all()
        #expect(postings.count == 30 && Set(postings.map(\.id)).count == 30)
        for posting in postings {
            #expect(posting.musts.count >= 3, "\(posting.id) has too few must-have labels")
            #expect(posting.description.count >= 150, "\(posting.id) is too short to be a posting")
        }
    }

    @Test func matchingIsByTechnologyOrMostOfTheWords() {
        #expect(RequirementMatch.matches("3+ years building services in Go", "3+ years of Go or Java"))
        #expect(RequirementMatch.matches("Experience with Playwright or Selenium", "Playwright or Selenium"))
        #expect(RequirementMatch.matches("Apex", "Apex and Lightning Web Components"))
        #expect(
            RequirementMatch.matches("Must be legally entitled to work in Canada", "Legally entitled to work in Canada")
        )
        #expect(!RequirementMatch.matches("Kubernetes", "PostgreSQL"))
        #expect(!RequirementMatch.matches("Strong communication skills", "Tableau or Power BI"))
        let scored = RequirementMatch.score(
            predicted: ["Go", "PostgreSQL", "A sense of humour"], labels: ["Go", "SQL", "Kafka"])
        #expect(scored.correct == ["Go", "PostgreSQL"] && scored.found == ["Go", "SQL"])
    }
}

/// One posting's scores, from its analysis and the writer's first reply. The live eval and the
/// offline replay share this, so a recorded run scores exactly as it did live.
struct PostingResult: Encodable {
    let id: String
    var predictedMusts: [String] = []
    var labels: [String] = []
    var wrongMusts: [String] = []
    var missedLabels: [String] = []
    var bullets = 0
    var bulletsPassing = 0
    var violations: [String] = []
    var error: String?
}

struct EvalReport: Encodable {
    let date: String
    let models: [String: String]
    let promptVersions: [String: Int]
    var thresholds = ["mustPrecision": 0.85, "mustRecall": 0.80, "firstWritePassRate": 0.95]
    var mustPrecision = 0.0
    var mustRecall = 0.0
    var firstWritePassRate = 0.0
    var meetsThresholds = false
    var postings: [PostingResult] = []

    /// Totals over every posting, then whether they meet the thresholds.
    mutating func total() {
        let predicted = postings.reduce(0) { $0 + $1.predictedMusts.count }
        let wrong = postings.reduce(0) { $0 + $1.wrongMusts.count }
        let labels = postings.reduce(0) { $0 + $1.labels.count }
        let missed = postings.reduce(0) { $0 + $1.missedLabels.count }
        let bullets = postings.reduce(0) { $0 + $1.bullets }
        let passing = postings.reduce(0) { $0 + $1.bulletsPassing }
        mustPrecision = predicted == 0 ? 0 : Double(predicted - wrong) / Double(predicted)
        mustRecall = labels == 0 ? 0 : Double(labels - missed) / Double(labels)
        firstWritePassRate = bullets == 0 ? 0 : Double(passing) / Double(bullets)
        meetsThresholds = mustPrecision >= 0.85 && mustRecall >= 0.80 && firstWritePassRate >= 0.95
    }

    var bullets: Int { postings.reduce(0) { $0 + $1.bullets } }
}

enum EvalScoring {
    /// Fixed, so the selection (and so the writer's bullet ids) is the same when a recorded run is
    /// replayed later.
    static let selector = Selector(now: Date(timeIntervalSince1970: 1_792_497_600))

    /// What `writeExperience` gets for a posting, from its analysis.
    static func writerInput(for posting: EvalPosting, analysis: AnalyzeJobTask.Output) -> WriteSectionInput {
        let requirements = JobRequirements(
            musts: analysis.requirements.filter { $0.kind == .must }.map(\.text),
            nices: analysis.requirements.filter { $0.kind == .nice }.map(\.text), domains: analysis.domains)
        let selection = selector.select(from: EvalPersona.resume, for: requirements)
        return WriteSectionInput(
            brief: WriterBrief(
                jobTitle: posting.title, requirements: requirements,
                locale: SpellingLocale(country: posting.job.country)),
            entries: selection.experience, skills: selection.skills,
            verifier: Verifier(resume: EvalPersona.resume, hiringCompany: posting.company))
    }

    static func score(_ posting: EvalPosting, analysis: AnalyzeJobTask.Output, written: SectionOutput) -> PostingResult
    {
        var result = PostingResult(id: posting.id, labels: posting.musts)
        let musts = analysis.requirements.filter { $0.kind == .must }.map(\.text)
        let scored = RequirementMatch.score(predicted: musts, labels: posting.musts)
        result.predictedMusts = musts
        result.wrongMusts = musts.filter { !scored.correct.contains($0) }
        result.missedLabels = posting.musts.filter { !scored.found.contains($0) }
        let input = writerInput(for: posting, analysis: analysis)
        for entry in WriteExperienceTask.written(written, input: input) {
            for bullet in entry.bullets {
                let found = input.verifier.check(bullet)
                result.bullets += 1
                if found.isEmpty {
                    result.bulletsPassing += 1
                } else {
                    result.violations += found.map { "“\(bullet.text.prefix(50))…”: \($0.detail)" }
                }
            }
        }
        return result
    }

    /// `Fixtures/evals/replies/<model>/`: each posting's two replies, as the model sent them.
    static func replies(_ model: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/evals/replies/\(model)")
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

/// Offline: the recorded run, scored again with today's matcher and verifier. It must still meet
/// the thresholds, and every bullet must still pass: the 30 jobs of success criterion S9 (strict).
@Suite("Recorded prompt eval")
struct RecordedEvalTests {
    @Test func theRecordedRunStillMeetsTheThresholds() throws {
        let folder = EvalScoring.replies(PromptEvals.model)
        var report = EvalReport(date: "", models: [:], promptVersions: [:])
        for posting in try EvalPosting.all() {
            let analysis = folder.appending(path: "\(posting.id).analyzeJob.json")
            let written = folder.appending(path: "\(posting.id).writeExperience.json")
            guard FileManager.default.fileExists(atPath: written.path()) else { continue }
            report.postings.append(
                EvalScoring.score(
                    posting,
                    analysis: try EvalScoring.decoder().decode(
                        AnalyzeJobTask.Output.self, from: Data(contentsOf: analysis)),
                    written: try EvalScoring.decoder().decode(SectionOutput.self, from: Data(contentsOf: written))))
        }
        report.total()
        #expect(report.postings.count == 30, "record the run with scripts/live-llm.sh PromptEvals")
        #expect(report.meetsThresholds)
        #expect(report.postings.allSatisfy { $0.violations.isEmpty }, "\(report.postings.flatMap(\.violations))")
    }
}

/// SPEC §5.5's prompt evals, against a real model: must-have extraction precision and recall over
/// the 30 labelled postings, and the share of experience bullets that pass the strict verifier on
/// the writer's first reply. Writes `evals/<date>-<model>.json` and records each reply under
/// `Fixtures/evals/replies/<model>/` for the offline replay. Opt-in and live:
/// `scripts/live-llm.sh PromptEvals` (about 60 calls; the model is `KAIROS_EVAL_MODEL`, Flash-Lite
/// by default, so the free tier's Flash limit isn't spent).
@Suite(
    "Prompt evals",
    .enabled(if: ProcessInfo.processInfo.environment["KAIROS_LIVE_LLM"] == "1", "Set KAIROS_LIVE_LLM=1"),
    .serialized)
struct PromptEvals {
    static let model = ProcessInfo.processInfo.environment["KAIROS_EVAL_MODEL"] ?? "gemini-flash-lite-latest"
    static let writerModel = ProcessInfo.processInfo.environment["KAIROS_EVAL_WRITER_MODEL"] ?? model

    @Test func extractionAndFirstWriteMeetTheThresholds() async throws {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            print("eval: GEMINI_API_KEY not set; skipping")
            return
        }
        let client = LLMClient(
            keys: [OpenAICompatibleProvider(preset: .gemini, key: key)], policy: ClientPolicy(preset: .gemini))
        let persona = EvalPersona.resume
        let folder = EvalScoring.replies(Self.model)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = EvalReport(
            date: Date().formatted(.iso8601.year().month().day()),
            models: ["analyzeJob": Self.model, "writeExperience": Self.writerModel],
            promptVersions: [
                "analyzeJob": AnalyzeJobTask.promptVersion, "writeExperience": WriteExperienceTask.promptVersion,
            ])

        for posting in try EvalPosting.all() {
            var result = PostingResult(id: posting.id, labels: posting.musts)
            do {
                let analysis = try await run(
                    client, AnalyzeJobTask(),
                    AnalyzeJobTask.Input(job: posting.job, skills: persona.skills, languages: []), model: Self.model)
                try Data(analysis.json.utf8).write(to: folder.appending(path: "\(posting.id).analyzeJob.json"))
                let written = try await run(
                    client, FirstWrite(task: Redacted(WriteExperienceTask(), header: persona.header)),
                    EvalScoring.writerInput(for: posting, analysis: analysis.output), model: Self.writerModel)
                try Data(written.json.utf8).write(to: folder.appending(path: "\(posting.id).writeExperience.json"))
                result = EvalScoring.score(posting, analysis: analysis.output, written: written.output)
            } catch {
                result.error = String(describing: error)
            }
            print(
                "eval: \(posting.id) · musts \(result.predictedMusts.count) · bullets \(result.bulletsPassing)/\(result.bullets)"
            )
            report.postings.append(result)
        }

        report.total()
        try write(report)
        print(
            "eval: precision \(report.mustPrecision.formatted(.percent.precision(.fractionLength(1)))) · recall "
                + "\(report.mustRecall.formatted(.percent.precision(.fractionLength(1)))) · first-write pass "
                + "\(report.firstWritePassRate.formatted(.percent.precision(.fractionLength(1)))) over \(report.bullets) bullets"
        )

        #expect(report.postings.allSatisfy { $0.error == nil }, "some postings failed; see the report")
        #expect(report.mustPrecision >= 0.85)
        #expect(report.mustRecall >= 0.80)
        #expect(report.firstWritePassRate >= 0.95)
    }

    private func run<T: LLMTask>(_ client: LLMClient, _ task: T, _ input: T.Input, model: String) async throws
        -> LLMResult<T.Output>
    {
        let defaults = TaskDefaults.catalog[T.id] ?? TaskDefaults.fallback
        return try await client.run(
            task, input: input,
            options: RunOptions(
                model: model, budget: defaults.budget, temperature: defaults.temperature,
                timeoutSeconds: defaults.timeoutSeconds))
    }

    /// `evals/<date>-<model>.json` at the repository root, committed for comparison.
    private func write(_ report: EvalReport) throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "evals")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: folder.appending(path: "\(report.date)-\(Self.model).json"))
    }
}
