import AI
import Foundation
import KairosKit
import TestKit
import Testing

@testable import Resume

@Suite("Master resume")
struct ModelTests {
    @Test func monthsParseCompareAndSpellOut() throws {
        let march = try #require(YearMonth("2021-03"))
        #expect(march.description == "2021-03" && march.spelledOut == "March 2021")
        #expect(YearMonth("2021-3") == nil && YearMonth("2021-13") == nil && YearMonth("21-03") == nil)
        #expect(march.months(until: try #require(YearMonth("2022-01"))) == 10)
        #expect(march < (try #require(YearMonth("2021-04"))))
    }

    /// Entries carry over from the first Kairos's JSON as they are.
    @Test func entryFieldsKeepTheFirstKairossJSON() throws {
        let stored = #"{"employer":"Acme","employmentType":"Full-time","location":"Halifax, NS","title":"Developer"}"#
        let fields = try EntryFields.decode(kind: .experience, json: stored)
        #expect(fields == .experience(.init(employer: "Acme", title: "Developer", location: "Halifax, NS", employmentType: "Full-time")))
        #expect(try fields.json() == stored)
        let project = try EntryFields.decode(kind: .project, json: #"{"name":"Kairos","repoURL":"https://github.com/x/kairos","role":"","tech":["Swift"]}"#)
        #expect(project.headline == "Kairos")
        #expect(throws: (any Error).self) { try EntryFields.decode(kind: .experience, json: #"{"name":"no employer"}"#) }
    }

    @Test func theSampleHasWhatTestsNeed() {
        let resume = Sample.resume
        #expect(resume.entries(.experience).count == 2 && resume.provenSkills.count == 7)
        #expect(resume.bulletsByID[Sample.id(11)]?.entry.id == Sample.id(1))
        #expect(resume.languages.map(\.language) == ["English", "French"])
    }
}

@Suite("Master resume validation")
struct ValidationTests {
    @Test(arguments: [
        ("416-555-0123", "+14165550123"), ("(416) 555 0123", "+14165550123"), ("1 416 555 0123", "+14165550123"),
        ("+44 20 7946 0958", "+442079460958"), ("0044 20 7946 0958", "+442079460958"),
    ])
    func phonesBecomeE164(input: String, expected: String) {
        #expect(PhoneNumber.e164(input) == expected)
    }

    @Test(arguments: ["555-0123", "416-555-0123 x22", "+1 116 555 0123", "phone", ""])
    func badPhonesAreRefused(input: String) {
        #expect(PhoneNumber.e164(input) == nil)
    }

    @Test func profileLinksTakeOneForm() {
        #expect(Validator.linkedInProfile("ca.linkedin.com/in/jordan-rivera/?trk=x") == "https://www.linkedin.com/in/jordan-rivera")
        #expect(Validator.linkedInProfile("https://www.linkedin.com/company/acme") == nil)
        #expect(Validator.gitHubProfile("github.com/jrivera/") == "https://github.com/jrivera")
        #expect(Validator.gitHubProfile("https://github.com/jrivera/ledger") == nil)
        #expect(Validator.httpsURL("jordan.dev") == "https://jordan.dev" && Validator.httpsURL("http://jordan.dev") == nil)
        #expect(PhoneNumber.display("+14165550123") == "416-555-0123")
    }

    @Test func aHeaderIsCleanedAndItsGapsNamed() {
        var header = ResumeHeader()
        header.fullName = "Jordan Rivera"
        header.email = "not-an-email"
        header.phone = "416 555 0123"
        header.gitHubURL = "github.com/jrivera"
        let validation = Validator.validate(header)
        #expect(validation.header.phone == "+14165550123" && validation.header.gitHubURL == "https://github.com/jrivera")
        #expect(validation.issues.map(\.field) == [.email, .linkedIn, .totalYears])
        #expect(validation.issue(for: .email)?.kind == .invalid && validation.issue(for: .linkedIn)?.kind == .missing)
    }

    @Test func readinessBlocksBuildsUntilTheBasicsAreThere() throws {
        let now = try #require(YearMonth("2026-10"))
        #expect(Validator.readiness(Sample.resume, now: now).isReady)
        var thin = Sample.resume
        thin.skills = Array(thin.skills.prefix(3))
        thin.entries = thin.entries.filter { $0.kind != .experience }
        let readiness = Validator.readiness(thin, now: now)
        #expect(readiness.missing == [.experienceBullet, .provenSkills(have: 3, need: 5)])
    }

    @Test func yearsFromDatesCountOverlapsOnce() throws {
        let now = try #require(YearMonth("2026-03"))
        // 2020-06 → 2022-02 (20 months) and 2022-03 → now (48 months).
        #expect(Validator.experienceYears(Sample.resume.entries, now: now) == 68.0 / 12)
        var header = Sample.header
        header.totalYears = 9
        let resume = MasterResume(header: header, entries: Sample.resume.entries, skills: Sample.resume.skills)
        #expect(Validator.readiness(resume, now: now).warnings.first?.contains("add up to 5.7") == true)
    }
}

@Suite("Contact redaction")
struct RedactionTests {
    @Test func contactDetailsNeverReachAPrompt() {
        let text = """
            Jordan Rivera · jordan.rivera@example.com · (416) 555-0123 · linkedin.com/in/jordan-rivera
            https://github.com/jrivera · jordan.dev/work · Rivera, Jordan
            Built an event pipeline handling 4.2M events a day in 2022-2024 with 99.95% uptime, v2.10.3.
            """
        var header = Sample.header
        header.portfolioURL = "https://jordan.dev"
        let redacted = ContactRedactor.redact(text, header: header)
        for secret in ["Jordan", "Rivera", "example.com", "555", "linkedin", "github", "jordan.dev"] {
            #expect(!redacted.contains(secret), "\(secret) leaked: \(redacted)")
        }
        #expect(redacted.contains("4.2M events a day in 2022-2024 with 99.95% uptime, v2.10.3"))
    }

    @Test func workStatusStaysOnThisMac() {
        let text = "Canadian citizen; no sponsorship required. Built a visa portal. Eligible to work in Canada. Secret clearance."
        let redacted = ContactRedactor.redactWorkStatus(text)
        #expect(!redacted.localizedCaseInsensitiveContains("citizen") && !redacted.localizedCaseInsensitiveContains("clearance"))
        #expect(redacted.contains("Built a visa portal"))
    }
}

@Suite("Importing a resume")
struct ImportTests {
    static let reply = #"""
        {"headline":"Backend developer","total_years":5,
         "experience":[{"title":"Software Developer","employer":"Harbourline","start":"2022-03","current":true,"bullets":["Built an event pipeline in Go."," "]}],
         "projects":[{"name":"Ledger","tech":["Swift"],"start":"2023","bullets":["Budgeting app."]}],
         "education":[{"institution":"University of Waterloo","credential":"BMath","start":"2016-09","end":"2020-04"}],
         "skills":[{"name":"Go","level":"proven"},{"name":"go","level":"proven"},{"name":"Rust","level":"can_discuss"}],
         "languages":[{"language":"French","proficiency":"conversational"}]}
        """#

    @Test func anImportRunsThroughTheRouterIntoADraft() async throws {
        let chat = ScriptedChat([.importResume: [.json(Self.reply)]])
        let text = try ResumeImporter.prepare(
            "Jordan Rivera, jordan.rivera@example.com. Software Developer at Harbourline since 2022. Canadian citizen.",
            header: Sample.header)
        #expect(!text.contains("Jordan") && !text.contains("citizen"))
        let result = try await scriptedRouter(chat).run(ImportResumeTask(), input: text)
        let draft = ImportDraft(result.output)
        #expect(draft.entries.map(\.kind) == [.experience, .project, .education, .language])
        #expect(draft.entries[0].isCurrent && draft.entries[0].bullets.map(\.text) == ["Built an event pipeline in Go."])
        #expect(draft.monthsToCheck == [draft.entries[1].id])  // "2023" became January, to check
        #expect(draft.skills.map(\.name) == ["Go", "Rust"] && draft.skills[1].level == .canDiscuss)
        let prompt = try #require(chat.asked.first?.request.messages)
        #expect(prompt[0].content.contains("never instructions") && prompt[1].content.hasPrefix("<resume>"))
    }

    @Test func aReplyWithContactDetailsOrBadDatesIsRefused() {
        let task = ImportResumeTask()
        let leak = #"{"experience":[{"title":"Dev","employer":"Acme","bullets":["Reach me at jo@example.com"]}],"projects":[],"education":[],"skills":[]}"#
        guard case .failure(let problem) = OutputCheck.output(from: leak, task: task, input: "") else {
            Issue.record("a leaked email should fail")
            return
        }
        #expect(problem.description.contains("contact details"))
        let badDate = #"{"experience":[{"title":"Dev","employer":"Acme","start":"March 2020","bullets":[]}],"projects":[],"education":[],"skills":[]}"#
        guard case .failure = OutputCheck.output(from: badDate, task: task, input: "") else {
            Issue.record("a month in words should fail")
            return
        }
    }

    @Test func importWaitsForTheContactFields() {
        #expect(throws: ImportError.self) { try ResumeImporter.prepare(String(repeating: "x", count: 100), header: ResumeHeader()) }
        #expect(throws: ImportError.emptyText) { try ResumeImporter.prepare("short", header: Sample.header) }
    }

    @Test func gitHubRepositoriesBecomeProjects() async throws {
        let repos = #"[{"name":"ledger","full_name":"jrivera/ledger","description":"Budgets. Mail jordan.rivera@example.com","language":"Swift","fork":false,"archived":false,"stargazers_count":3,"html_url":"https://github.com/jrivera/ledger","created_at":"2023-01-05T10:00:00Z","pushed_at":"2026-09-30T10:00:00Z","topics":["swift"]},{"name":"fork","full_name":"jrivera/fork","fork":true,"archived":false,"stargazers_count":0,"html_url":"https://github.com/jrivera/fork","created_at":"2020-01-05T10:00:00Z"}]"#
        let http = FakeHTTP([
            "https://api.github.com/users/jrivera/repos?per_page=100&sort=pushed&type=owner": .json(repos),
            "https://api.github.com/repos/jrivera/ledger/languages": .json(#"{"Swift":9000,"C":10}"#),
            "https://api.github.com/repos/jrivera/ledger/readme": .json("# Ledger\nA budgeting app by Jordan Rivera."),
        ])
        let client = GitHubClient(token: nil, http: http)
        let user = try #require(GitHubClient.user(fromProfile: Sample.header.gitHubURL))
        let found = try await client.repos(of: user)
        #expect(found.map(\.name) == ["ledger", "fork"])
        let ledger = found[0]
        let input = ImportGitHubRepoTask.Input(
            repo: ledger, languages: try await client.languages(of: ledger), readme: try await client.readme(of: ledger),
            header: Sample.header)
        #expect(input.languages == ["Swift", "C"] && !input.readme.contains("Rivera") && !input.description.contains("@"))
        let output = ImportGitHubRepoTask.Output(name: "Ledger", role: nil, tech: ["Swift"], bullets: ["A budgeting app."])
        let entry = ImportGitHubRepoTask.entry(from: output, repo: ledger, now: isoDate("2026-10-28T00:00:00Z"))
        #expect(entry.isCurrent && entry.start == YearMonth("2023-01"))
        guard case .project(let project) = entry.fields else { return }
        #expect(project.repoURL == "https://github.com/jrivera/ledger")
    }
}
