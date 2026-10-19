import CoreText
import Foundation
import LLM
import Testing

@testable import MasterResume

/// The design's sample persona and a made-up resume: fixtures only.
private func jordan() -> ResumeHeader {
    var header = ResumeHeader()
    header.fullName = "Jordan Rivera"
    header.email = "jordan.rivera@example.com"
    header.phone = "+14165550123"
    header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
    header.gitHubURL = "https://github.com/jrivera"
    header.portfolioURL = "https://jordanrivera.dev"
    return header
}

private let resume = """
    JORDAN RIVERA
    Toronto, ON · (416) 555-0123 · jordan.rivera@example.com
    linkedin.com/in/jordan-rivera · github.com/jrivera · jordanrivera.dev

    EXPERIENCE
    Backend Developer II — Northline Freight, Toronto, ON (Mar 2021 – Present)
    • Cut p95 latency of the tracking API by 40%.
    • Led the move to event sourcing with Kafka.

    SKILLS
    Go, PostgreSQL, Kafka, Rust
    """

private let reply = """
    {"headline":"Backend developer","total_years":4.5,
     "experience":[{"title":"Backend Developer II","employer":"Northline Freight","location":"Toronto, ON",
       "start":"2021-03","current":true,"end":"2024-01",
       "bullets":["Cut p95 latency of the tracking API by 40%.","  ","Led the move to event sourcing with Kafka."]}],
     "projects":[{"name":"Dockyard","tech":["Go"],"start":"2023-01","end":"2023-06","bullets":["CLI for Docker clean-up"]}],
     "education":[{"institution":"University of Waterloo","credential":"BMath","start":"2015-09","end":"2019-04"}],
     "skills":[{"name":"Go","category":"Language","level":"proven"},{"name":"go","level":"proven"},
               {"name":"Rust","level":"can_discuss"},{"name":"Kafka","level":"proven"}],
     "certifications":[{"name":"AWS SAA","issuer":"Amazon","date":"2024-05"}],
     "languages":[{"language":"French","proficiency":"conversational"}],
     "other":[{"section":"Talks","title":"Postgres tips","bullets":["PGConf 2024"]}]}
    """

private func importer(_ replies: [FakeProvider.Reply]) -> (LLMClient, FakeProvider) {
    let fake = FakeProvider([.importResume: replies])
    return (LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 }), fake)
}

private let options = RunOptions(model: "flash", budget: TaskDefaults.catalog[.importResume]!.budget, temperature: 0)

@Suite("Resume import")
struct ImportTests {
    @Test func thePromptIsAVersionedResource() throws {
        let instructions = try #require(PromptLibrary.instructions(for: .importResume, version: 1))
        #expect(instructions.contains("[removed]") && instructions.contains("Never invent"))
        #expect(PromptLibrary.instructions(for: .importResume, version: 99) == nil)
    }

    /// SPEC §5.5 PromptPrivacyTests: render the prompt for a fixture user; no contact value may appear.
    @Test func noContactDetailReachesThePrompt() throws {
        let prepared = try ResumeImporter.prepare(resume, header: jordan())
        let messages = ImportResumeTask().messages(for: prepared, budget: options.budget)
        let sent = messages.map(\.content).joined(separator: "\n")
        for value in [
            "Jordan", "Rivera", "416", "555-0123", "example.com", "jordan-rivera", "jrivera", "jordanrivera.dev",
        ] {
            #expect(!sent.localizedCaseInsensitiveContains(value), "\(value) would be sent")
        }
        #expect(sent.contains("Northline Freight") && sent.contains("Toronto, ON"))
        #expect(messages.first?.role == .system && messages.last?.content.hasPrefix("<resume>\n") == true)
    }

    @Test func contactFieldsComeFirst() {
        #expect(throws: ImportError.contactIncomplete([.fullName, .email, .phone, .linkedIn])) {
            try ResumeImporter.prepare(resume, header: ResumeHeader())
        }
        var noYears = jordan()
        noYears.totalYears = nil  // total years isn't contact; it can come from the import
        #expect(throws: Never.self) { try ResumeImporter.prepare(resume, header: noYears) }
        #expect(throws: ImportError.emptyText) { try ResumeImporter.prepare("  hi  ", header: jordan()) }
    }

    @Test func aLongResumeIsShortenedToTheBudget() {
        let long = String(repeating: "Built things. ", count: 5_000)
        let user =
            ImportResumeTask().messages(for: long, budget: TokenBudget(input: 2_000, output: 100)).last?.content ?? ""
        #expect(user.count < 4_100 && user.contains("[resume shortened to fit]"))
    }

    @Test func aReplyBecomesADraftToReview() async throws {
        let (client, fake) = importer([.reply(reply)])
        let prepared = try ResumeImporter.prepare(resume, header: jordan())
        let result = try await client.run(ImportResumeTask(), input: prepared, options: options)
        let draft = ImportDraft(result.output)
        #expect(fake.requests.count == 1 && result.outcome == .ok)

        #expect(draft.headline == "Backend developer" && draft.totalYears == 4.5)
        #expect(draft.entries.map(\.kind) == [.experience, .project, .education, .certification, .language, .custom])
        let job = draft.entries[0]
        #expect(job.isCurrent && job.end == nil && job.start == YearMonth(year: 2021, month: 3))
        #expect(
            job.bullets.map(\.text) == [
                "Cut p95 latency of the tracking API by 40%.", "Led the move to event sourcing with Kafka.",
            ])
        #expect(draft.entries[1].end == YearMonth(year: 2023, month: 6))
        #expect(draft.entries[3].start == YearMonth(year: 2024, month: 5))
        #expect(draft.skills.map(\.name) == ["Go", "Rust", "Kafka"])  // "go" was a repeat
        #expect(draft.skills.map(\.level) == [.proven, .canDiscuss, .proven])
        #expect(Set(draft.entries.map(\.id)).count == draft.entries.count)  // fresh, distinct ids
    }

    @Test(arguments: [
        (
            #"{"experience":[{"title":"Dev","employer":"Acme","start":"2021-13","bullets":[]}],"projects":[],"education":[],"skills":[]}"#,
            "isn't a month in YYYY-MM form"
        ),
        (
            #"{"experience":[{"title":" ","employer":"Acme","bullets":[]}],"projects":[],"education":[],"skills":[]}"#,
            "have no title, employer or name"
        ),
        (
            #"{"experience":[{"title":"Dev","employer":"Acme","bullets":["Reach me at sam@acme.example"]}],"projects":[],"education":[],"skills":[]}"#,
            "contains contact details"
        ),
    ])
    func aReplyThatBreaksTheRulesIsRepairedThenRefused(bad: String, problem: String) async throws {
        let (client, fake) = importer([.reply(bad), .reply(bad)])
        await #expect {
            try await client.run(ImportResumeTask(), input: "resume text", options: options)
        } throws: { error in
            guard case LLMError.invalidOutput(let message) = error else { return false }
            return message.contains(problem)
        }
        #expect(fake.requests.count == 2)  // one repair, then a clear error
    }

    /// Prompt v2 (2026-10-19): v1 turned "2015" into "2015-01", called a project's description its
    /// role and left its tech empty.
    @Test func thePromptKeepsYearsAloneAndOnlyStatedRoles() throws {
        #expect(ImportResumeTask.promptVersion == 2)
        let instructions = try #require(
            PromptLibrary.instructions(for: .importResume, version: ImportResumeTask.promptVersion))
        #expect(instructions.contains(#"write only the year, "YYYY""#) && instructions.contains("Never guess a month"))
        #expect(instructions.contains("A description of the project is never its role"))
        #expect(
            instructions.contains("tech") && instructions.contains("[removed]") && instructions.contains("Never invent")
        )
    }

    /// A resume that gives only a year: the year is kept, the month becomes January, and review asks
    /// you to check it.
    @Test func aYearAloneIsKeptAndMarkedForReview() async throws {
        let yearsOnly = """
            {"experience":[{"title":"Dev","employer":"Acme","start":"2021-03","current":true,"bullets":["Built it."]}],
             "projects":[{"name":"Dockyard","start":"2023","current":true,"bullets":[]}],
             "education":[{"institution":"University of Waterloo","start":"2015","end":"2019-04"}],
             "skills":[],
             "certifications":[{"name":"AWS SAA","date":"2024"}]}
            """
        let (client, fake) = importer([.reply(yearsOnly)])
        let result = try await client.run(ImportResumeTask(), input: "resume text", options: options)
        let draft = ImportDraft(result.output)
        #expect(fake.requests.count == 1)  // a year alone passes the checks
        let (job, project, school, cert) = (draft.entries[0], draft.entries[1], draft.entries[2], draft.entries[3])
        #expect(project.start == YearMonth(year: 2023, month: 1) && project.isCurrent)
        #expect(school.start == YearMonth(year: 2015, month: 1) && school.end == YearMonth(year: 2019, month: 4))
        #expect(cert.start == YearMonth(year: 2024, month: 1))
        #expect(draft.monthsToCheck == [project.id, school.id, cert.id])
        #expect(!draft.monthsToCheck.contains(job.id))
        #expect(ImportDraft(entries: [job]).monthsToCheck.isEmpty)
    }

    @Test(arguments: ["15", "201", "20155", "2015-1", "2015-00", "1850", "+201"])
    func aDateIsAMonthOrAYearAlone(_ bad: String) async throws {
        let reply =
            #"{"experience":[],"projects":[],"education":[{"institution":"Waterloo","start":"\#(bad)"}],"skills":[]}"#
        let (client, _) = importer([.reply(reply), .reply(reply)])
        await #expect {
            try await client.run(ImportResumeTask(), input: "resume text", options: options)
        } throws: { error in
            guard case LLMError.invalidOutput(let message) = error else { return false }
            return message.contains("isn't a month in YYYY-MM form")
        }
    }

    @Test func readsTheTextOfAPDF() throws {
        let text = try ResumeTextExtractor.text(
            fromPDF: Self.pdf(drawing: "Backend Developer II\n\n\n\nNorthline Freight"))
        #expect(text.contains("Backend Developer II") && text.contains("Northline Freight"))
        #expect(!text.contains("\n\n\n"))
    }

    @Test func aPDFWithoutTextOrNotAPDFIsRefused() throws {
        #expect(throws: ImportError.emptyText) { try ResumeTextExtractor.text(fromPDF: Self.pdf(drawing: "")) }
        #expect(throws: ImportError.unreadablePDF) { try ResumeTextExtractor.text(fromPDF: Data("not a pdf".utf8)) }
    }

    /// A one-page PDF with `text` drawn in it.
    static func pdf(drawing text: String) -> Data {
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &page, nil)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attributed = NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let frame = CTFramesetterCreateFrame(
            CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
            CGPath(rect: page.insetBy(dx: 72, dy: 72), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
