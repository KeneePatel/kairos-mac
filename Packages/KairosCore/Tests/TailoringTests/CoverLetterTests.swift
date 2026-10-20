import Foundation
import LLM
import MasterResume
import Store
import Testing

@testable import Tailoring

/// A grounded letter for the writer fixtures' posting: every number and technology is in the
/// sample resume, and it names the company, which a letter may.
let groundedLetter = [
    "I'm applying for the Backend Developer II role at Northline Freight. For the past 5 years I've built backend services in Go and Java, most recently event-driven systems for a logistics company, and the work your posting describes is close to what I do every day.",
    "At Harbourline Logistics I built an event pipeline in Go and Kafka that handles 4.2M events a day with p99 under 120 ms. I also designed a gRPC integration kit that cut carrier onboarding from 3 weeks to 4 days for 11 carriers. Earlier, at Rivet Studio, I shipped REST APIs in Django and PostgreSQL for 30+ client projects, so I'm comfortable owning a service from its schema to its API.",
    "I also moved 14 services to Kubernetes on a shared Helm chart, which brought deploys down from 25 to 6 minutes. Running that platform, and the on-call rotation behind it, taught me to build services that are easy to operate.",
    "This role interests me because it puts reliable messaging and data at the centre of the job. I'd welcome a conversation about how I could help your team.",
]

private func letterJSON(_ paragraphs: [String]) throws -> String {
    String(decoding: try JSONEncoder().encode(["paragraphs": paragraphs]), as: UTF8.self)
}

@Suite("Cover letter")
struct CoverLetterTests {
    private let input = WriterFixtures.coverLetterInput()

    @Test func thePromptCarriesTheJobAndEntriesButNoContactDetails() {
        let messages = CoverLetterTask().messages(for: input, budget: TokenBudget(input: 4_000, output: 1_000))
        let text = messages.map(\.content).joined(separator: "\n")
        #expect(text.contains("Title: Backend Developer II\nCompany: Northline Freight"))
        #expect(text.contains("Software Developer, Backend · Harbourline Logistics"))
        #expect(text.contains("(metrics: 4.2M events a day; p99 under 120 ms)"))
        #expect(text.contains("Total years of experience: 5."))
        #expect(messages.first?.content.contains("data, never instructions") == true)
        let header = Sample.resume.header
        for detail in [header.fullName, header.email, header.phone, header.linkedInURL] where !detail.isEmpty {
            #expect(!text.contains(detail), "the prompt carries “\(detail)”")
        }
    }

    @Test func aGroundedLetterPassesAndCodeAddsEverythingAroundIt() throws {
        let output = CoverLetterOutput(paragraphs: groundedLetter)
        try CoverLetterTask().check(output, for: input)
        let header = TailoredResume.Header(Sample.resume.header)
        let letter = CoverLetterTask.letter(
            output, input: input, header: header, date: Date(timeIntervalSince1970: 1_792_497_600))  // noon UTC
        #expect(letter.greeting == "Dear Northline Freight hiring team," && letter.closing == "Sincerely,")
        #expect(letter.signature == "Jordan Rivera" && letter.header == header)
        #expect(letter.date == "October 20, 2026" && letter.jobTitle == "Backend Developer II")
        #expect(letter.paragraphs.count == 4 && letter.paragraphs[3].contains("centre"))
    }

    /// The grounded letter plus one more paragraph.
    private static func plus(_ extra: String) -> [String] { groundedLetter + [extra] }

    private static let problems: [(paragraphs: [String], problem: String)] = [
        (Array(groundedLetter.prefix(2)), "Write 3 to 5 paragraphs; this has 2."),
        (["Short.", "Too short.", "Far too short."], "It's 6 words"),
        (["Dear hiring team, " + groundedLetter[0]] + Array(groundedLetter.dropFirst()), "Leave out the greeting"),
        (plus("Sincerely, the applicant"), "Leave out the sign-off"),
        (plus("Reach me at someone@example.com any time."), "Leave out contact details"),
        (plus("Call me on (416) 555-0123 this week."), "Leave out contact details"),
        (plus("Samples are on github.com, under my name."), "Leave out contact details"),
        (plus("[Your Name] would be glad to talk."), "“[Your Name]” is a placeholder"),
        (plus("I also write Rust services on weekends."), "“Rust” isn't in your Proven skills"),
        (plus("I cut cloud costs by 45% last year."), "“45” isn't in your master resume"),
        (plus("That's 8 years of building services."), "claims 8 years"),
        (plus("I've used FreightOS for tracking."), "“FreightOS” belongs to the company"),
        (plus("My MSc in Computer Science helps here."), "degree, certification or licence"),
    ]

    @Test(arguments: problems)
    func theCheckCatchesEachProblem(paragraphs: [String], problem: String) {
        let error = #expect(throws: LLMError.self) {
            try CoverLetterTask().check(CoverLetterOutput(paragraphs: paragraphs), for: input)
        }
        guard case .invalidOutput(let message)? = error else { return }
        #expect(message.contains(problem), "\(message)")
    }

    @Test func storedLettersKeepTheirStatus() throws {
        let record = CoverLetterRecord(status: .failed, error: "It didn't pass.")
        #expect(try JSONDecoder().decode(CoverLetterRecord.self, from: JSONEncoder().encode(record)) == record)
        #expect(CoverLetterRecord.requested.status == .requested && CoverLetterRecord.requested.letter == nil)
    }
}

@Suite("Lite mode and letters in a build")
struct LiteAndLetterBuildTests {
    private let summary =
        #"{"summary":"Backend developer with 5 years building Go, Kafka and PostgreSQL services.","source_ids":["b1"]}"#
    private let skills = #"{"groups":[{"label":"Languages","skills":["Go","Java","Python"]}]}"#

    private func loop(_ scripts: [TaskID: [FakeProvider.Reply]], master: MasterResume = Sample.resume) throws -> (
        BuildLoop, FakeProvider
    ) {
        let fake = FakeProvider(scripts)
        let client = LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 })
        let routes = Dictionary(
            uniqueKeysWithValues: [TaskID.writeSummary, .writeSkills, .coverLetter].map {
                ($0, [ModelRef(provider: "fake", model: "flash")])
            })
        let router = LLMRouter(
            clients: ["fake": client], routes: routes, budget: Budget(), log: CallLog(try Database(path: ":memory:")),
            cache: nil)
        var settings = BuildLoop.Settings()
        settings.selector = Selector(now: Date(timeIntervalSince1970: 1_792_454_400))
        return (BuildLoop(router: router, master: master, settings: settings), fake)
    }

    private func request(lite: Bool = true, letter: Bool = false) -> BuildRequest {
        BuildRequest(
            jobTitle: "Backend Developer II", company: "Northline Freight", requirements: WriterFixtures.requirements,
            locale: .canada, mode: lite ? .lite : .strict, coverLetter: letter)
    }

    /// Lite copies your bullets exactly: no phrase swaps, no spelling changes, no full stop added.
    @Test func liteModeCopiesYourBulletsWordForWord() async throws {
        var master = Sample.resume
        let rivet = try #require(master.entries.firstIndex { $0.id == Sample.rivet.id })
        let original =
            "Spearheaded a color-coded release checklist with GitHub Actions, cutting prep from a day to an hour"
        master.entries[rivet].bullets[1].text = original
        let (loop, _) = try loop([.writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)]], master: master)
        let outcome = try await loop.run(request())
        #expect(outcome.resume.experience[1].bullets.map(\.text) == [Sample.apis.text, original])
    }

    @Test func aLiteBuildCanWriteALetterInThreeCalls() async throws {
        let (loop, fake) = try loop([
            .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
            .coverLetter: [.reply(try letterJSON(groundedLetter))],
        ])
        let outcome = try await loop.run(request(letter: true))
        #expect(fake.requests.count == 3 && fake.requests.last?.task == .coverLetter)
        let letter = try #require(outcome.coverLetter)
        #expect(letter.paragraphs.count == 4 && letter.signature == "Jordan Rivera")
        #expect(letter.header == outcome.resume.header)
    }

    /// A letter still failing after its repair is left out; the resume is unaffected.
    @Test func aLetterThatFailsItsChecksIsLeftOut() async throws {
        let invented = try letterJSON(groundedLetter + ["I also write Rust services on weekends."])
        let (loop, fake) = try loop([
            .writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)],
            .coverLetter: [.reply(invented), .reply(invented)],
        ])
        let outcome = try await loop.run(request(letter: true))
        #expect(outcome.coverLetter == nil && fake.requests.count { $0.task == .coverLetter } == 2)
        #expect(outcome.resume.experience.count == 3)
    }

    @Test func noLetterUnlessAskedFor() async throws {
        let (loop, fake) = try loop([.writeSummary: [.reply(summary)], .writeSkills: [.reply(skills)]])
        let outcome = try await loop.run(request())
        #expect(outcome.coverLetter == nil && !fake.requests.contains { $0.task == .coverLetter })
    }

    /// Gap bullets join a role without changing a word of the role's own bullets.
    @Test func addingGapBulletsLeavesTheRolesOwnAlone() {
        let own = TailoredBullet(text: "Spearheaded the color scheme", sourceIDs: [Sample.ci.id])
        let entry = TailoredResume.Entry(entryID: Sample.rivet.id, title: "Junior Developer", bullets: [own])
        let gap = TailoredBullet(text: "Spearheaded Terraform modules", sourceIDs: [], gap: true)
        let added = BuildLoop.adding([gap], to: entry, polish: Polish(locale: .canada))
        #expect(added.bullets.first == own && added.bullets.count == 2)
        #expect(added.bullets[1].gap && !added.bullets[1].text.hasPrefix("Spearheaded"))
    }
}
