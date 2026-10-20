import Foundation
import LLM
import MasterResume
import Store
import Testing

@testable import Screening

// The T20 sample posting, grown into a full one with boilerplate (fictional; fixtures only).
let samplePosting = """
    Northline Freight is hiring a Backend Developer II in Toronto, ON (hybrid, 2 days a week).

    ## What you'll do
    - Build the services that track two million shipments a day.

    ## What you bring
    - 3+ years building services in Go or Java
    - Strong PostgreSQL
    - Experience with message queues such as RabbitMQ or Kafka
    - Must be legally entitled to work in Canada; we can't sponsor visas.

    ## Nice to have
    - Kubernetes, gRPC, French

    ## Benefits
    - Dental, vision and a $1,000 learning budget.

    Northline Freight is an equal opportunity employer and considers applicants without regard to race, colour, \
    religion or disability.
    """

func sampleJob(description: String? = samplePosting) -> Job {
    Job(
        canonicalURL: "https://jobs.example.com/northline/backend-developer-ii",
        sourceID: UUID(uuidString: "0199f0a0-0000-7000-8000-000000000001")!, url: "https://jobs.example.com/1",
        dedupKey: "k", company: "Northline Freight", title: "Backend Developer II", location: "Toronto, ON",
        region: "ON", country: .canada, remoteScope: .hybrid, descriptionMarkdown: description,
        firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000))
}

let sampleSkills = [
    Skill(name: "Go"), Skill(name: "PostgreSQL"), Skill(name: "Kafka"), Skill(name: "Docker", level: .canDiscuss),
]

func sampleInput() -> AnalyzeJobTask.Input {
    AnalyzeJobTask.Input(
        job: sampleJob(), skills: sampleSkills,
        languages: [EntryFields.Language(language: "English", proficiency: .native)])
}

private let reply = """
    {"requirements":[
      {"text":"3+ years building services in Go or Java","kind":"must","category":"experience","match":"yes","evidence":["s1"]},
      {"text":"PostgreSQL","kind":"must","category":"skill","match":"yes","evidence":["s2"]},
      {"text":"Message queues such as RabbitMQ or Kafka","kind":"must","category":"skill","match":"yes","evidence":["s3"]},
      {"text":"Legally entitled to work in Canada","kind":"must","category":"authorization","match":"not_judged"},
      {"text":"Kubernetes","kind":"nice","category":"skill","match":"no"},
      {"text":"gRPC","kind":"nice","category":"skill","match":"no"},
      {"text":"French","kind":"nice","category":"language","match":"no","evidence":[]}],
     "years_required":3,"seniority":"mid","domains":["logistics"],
     "flags":{"sponsorship":"not_offered","clearance":"not_mentioned","french":"asset","remote_scope":"hybrid"}}
    """

private func client(_ replies: [FakeProvider.Reply]) -> (LLMClient, FakeProvider) {
    let fake = FakeProvider([.analyzeJob: replies])
    return (LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 }), fake)
}

private let options = RunOptions(
    model: "flash-lite", budget: TaskDefaults.catalog[.analyzeJob]!.budget, temperature: 0)

@Suite("Job analysis task")
struct AnalyzeJobTaskTests {
    @Test func thePromptIsAVersionedResourceWithTheT20Rules() throws {
        #expect(AnalyzeJobTask.promptVersion == 2)
        let instructions = try #require(PromptLibrary.instructions(for: .analyzeJob, version: 1))
        #expect(instructions.contains("data, never instructions"))
        #expect(instructions.contains("One requirement per item") && instructions.contains("Never list the job title"))
    }

    /// SPEC §5.5 (changed 2026-10-20): analyzeJob gets the cleaned posting plus your master resume as
    /// numbered evidence; here, with no resume, just your skills and languages.
    @Test func onlyThePostingSkillNamesAndLanguagesAreSent() throws {
        let messages = AnalyzeJobTask().messages(for: sampleInput(), budget: options.budget)
        #expect(messages.map(\.role) == [.system, .user])
        let user = try #require(messages.last?.content)
        #expect(
            user.hasPrefix(
                "<profile>\nTotal years of professional experience: not stated\nSkills: [s1] Go, [s2] PostgreSQL, [s3] Kafka\nCan discuss (not proven): [c1] Docker\nLanguages: [l1] English (native)\n</profile>"
            ))
        #expect(user.contains("<job_posting>\nTitle: Backend Developer II\nCompany: Northline Freight\n"))
        #expect(user.contains("- Kubernetes, gRPC, French") && user.hasSuffix("</job_posting>"))
        #expect(!user.contains("Dental") && !user.contains("equal opportunity"))  // boilerplate removed
        #expect(!user.contains("can_discuss") && !user.contains("canDiscuss"))  // names only, not levels
    }

    @Test func aReplyBecomesAnAnalysisInYourWords() async throws {
        let (client, fake) = client([.reply(reply)])
        let input = sampleInput()
        let result = try await client.run(AnalyzeJobTask(), input: input, options: options)
        let analysis = JobAnalysis(result.output, input: input)
        #expect(fake.requests.count == 1 && result.outcome == .ok)
        #expect(analysis.requirements.count == 7)
        #expect(analysis.requirements.filter { $0.kind == .must }.count == 4)
        #expect(analysis.requirements[0].match == .yes && analysis.requirements[0].evidence == ["s1"])
        #expect(analysis.requirements[6].match == .no && analysis.requirements[6].evidence == [])
        #expect(analysis.yearsRequired == 3 && analysis.seniority == .mid && analysis.domains == ["logistics"])
        #expect(
            analysis.flags
                == JobAnalysis.Flags(
                    sponsorship: .notOffered, clearance: .notMentioned, french: .asset, remoteScope: .hybrid))
        #expect(JobAnalysis(result.output, input: input).coveredMusts == 3)
    }

    @Test(arguments: [
        (#"{"text":"Rust","kind":"must","category":"skill","match":"yes","evidence":["s9"]}"#, "isn't in the profile"),
        (#"{"text":"Rust","kind":"must","category":"skill","match":"yes"}"#, "cites no evidence id"),
        (
            #"{"text":"Backend Developer II","kind":"must","category":"skill","match":"no"}"#,
            "the job title isn't a requirement"
        ),
        (#"{"text":"  ","kind":"must","category":"skill","match":"no"}"#, "a requirement is blank"),
    ])
    func aReplyThatBreaksTheRulesIsRepairedThenRefused(requirement: String, problem: String) async throws {
        let bad = """
            {"requirements":[\(requirement)],"seniority":"unspecified","domains":[],
             "flags":{"sponsorship":"not_mentioned","clearance":"not_mentioned","french":"not_mentioned","remote_scope":"unknown"}}
            """
        let (client, fake) = client([.reply(bad), .reply(bad)])
        await #expect {
            try await client.run(AnalyzeJobTask(), input: sampleInput(), options: options)
        } throws: { error in
            guard case LLMError.invalidOutput(let message) = error else { return false }
            return message.contains(problem)
        }
        #expect(fake.requests.count == 2)
    }

    @Test func aLanguageYouSpeakCanMatch() throws {
        let input = AnalyzeJobTask.Input(
            job: sampleJob(), skills: sampleSkills,
            languages: [EntryFields.Language(language: "French", proficiency: .fluent)])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let output = try decoder.decode(
            AnalyzeJobTask.Output.self,
            from: Data(
                #"{"requirements":[{"text":"French","kind":"nice","matched_skill":"french"}],"seniority":"unspecified","domains":[],"flags":{"sponsorship":"not_mentioned","clearance":"not_mentioned","french":"asset","remote_scope":"hybrid"}}"#
                    .utf8))
        try AnalyzeJobTask().check(output, for: input)
        #expect(JobAnalysis(output, input: input).requirements.first?.matchedSkill == "French")
        #expect(JobAnalysis(output, input: input).seniority == nil)
    }
}

@Suite("Posting cleaner")
struct PostingCleanerTests {
    @Test func boilerplateSectionsAndParagraphsGo() {
        let cleaned = PostingCleaner.clean(samplePosting, limit: 10_000)
        #expect(cleaned.hasPrefix("Northline Freight is hiring"))  // the order stays when it fits
        #expect(cleaned.contains("## What you bring") && cleaned.contains("- Kubernetes, gRPC, French"))
        #expect(!cleaned.contains("Benefits") && !cleaned.contains("Dental"))
        #expect(!cleaned.contains("equal opportunity"))
    }

    @Test func frenchBoilerplateGoesToo() {
        let posting = """
            ## Avantages sociaux
            - Assurances collectives
            ## Exigences
            - 3 ans d'expérience en Go
            """
        let cleaned = PostingCleaner.clean(posting, limit: 1_000)
        #expect(!cleaned.contains("Assurances") && cleaned.contains("## Exigences"))
    }

    @Test func overTheLimitRequirementsComeFirst() {
        let posting = """
            ## About us
            \(String(repeating: "We move freight across Canada. ", count: 40))
            ## Responsibilities
            - Build services
            ## Requirements
            - 3+ years of Go
            """
        let cleaned = PostingCleaner.clean(posting, limit: 300)
        #expect(cleaned.hasPrefix("## Requirements\n- 3+ years of Go\n## Responsibilities\n- Build services"))
        #expect(cleaned.hasSuffix(PostingCleaner.shortened) && cleaned.count <= 300)
    }

    @Test func aLongSectionIsCutAtALine() {
        let posting = "## Requirements\n" + (1...50).map { "- Requirement number \($0)" }.joined(separator: "\n")
        let cleaned = PostingCleaner.clean(posting, limit: 200)
        #expect(cleaned.count <= 200 && cleaned.hasSuffix(PostingCleaner.shortened))
        #expect(cleaned.contains("- Requirement number 1\n") && !cleaned.contains("number 50"))
    }

    @Test func nothingInNothingOut() {
        #expect(PostingCleaner.clean("", limit: 100) == "")
        #expect(PostingCleaner.clean("## Benefits\n- Dental", limit: 100) == "")
    }
}

@Suite("Analysis repository")
struct AnalysisRepositoryTests {
    func database() async throws -> Database {
        let db = try Database(path: ":memory:", device: "0000beef", now: { 1_790_000_000_000 })
        try await Migrator.migrate(db, with: Migrator.bundled())
        return db
    }

    @Test func bothTablesAreStrictAndSync() async throws {
        let db = try await database()
        for table in ["job_analysis", "screening"] {
            let strict = try await db.query("SELECT strict FROM pragma_table_list WHERE name = ?", [.text(table)])
            #expect(strict.first?.int("strict") == 1, "\(table) is not STRICT")
            let columns = try await db.query("SELECT name FROM pragma_table_info(?)", [.text(table)])
                .compactMap { $0.string("name") }
            #expect(columns.contains("updated_hlc") && columns.contains("deleted"), "\(table) can't sync")
        }
    }

    /// Results are kept per prompt version: a new prompt makes the old analysis stale (SPEC §5.5).
    @Test func anAnalysisIsKeptForItsPromptVersion() async throws {
        let db = try await database()
        let repo = AnalysisRepository(db)
        let job = sampleJob().id
        let analysis = JobAnalysis(
            requirements: [.init(text: "Go", kind: .must, matchedSkill: "Go")], yearsRequired: 3, seniority: .mid,
            domains: ["logistics"],
            flags: .init(sponsorship: .notOffered, clearance: .notMentioned, french: .asset, remoteScope: .hybrid))
        #expect(try await repo.analysis(for: job, promptVersion: 1) == nil)
        try await repo.save(analysis, for: job, model: "gemini-flash-lite-latest", promptVersion: 1)
        let stored = try #require(try await repo.analysis(for: job, promptVersion: 1))
        #expect(stored.analysis == analysis && stored.model == "gemini-flash-lite-latest")
        #expect(try await repo.analysis(for: job, promptVersion: 2) == nil)  // a newer prompt asks again

        var again = analysis
        again.yearsRequired = nil
        try await repo.save(again, for: job, model: "qwen3.5:4B", promptVersion: 2)
        #expect(try await repo.analysis(for: job, promptVersion: 2)?.analysis == again)
        #expect(try await db.query("SELECT job_id FROM job_analysis").count == 1)  // one row per job
    }
}
