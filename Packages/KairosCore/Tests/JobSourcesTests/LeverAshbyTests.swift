import Foundation
import Store
import TestSupport
import Testing

@testable import JobSources

private let sourceID = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000bb")!

@Suite("Lever source")
struct LeverSourceTests {
    let url = "https://api.lever.co/v0/postings/acmerobotics?mode=json"

    @Test func mapsARecordedPostingsResponse() async throws {
        let body = try ScriptedURLProtocol.fixture("lever_postings.json")
        let (http, _) = ScriptedURLProtocol.client([url: .http(status: 200, body: body)])
        let postings = try await LeverSource(id: sourceID, slug: "acmerobotics", http: http).fetch(SourceQuery())

        #expect(postings.count == 2)
        let first = postings[0]
        #expect(first.url.absoluteString == "https://jobs.lever.co/acmerobotics/223f9722-3579-4ff2-b123-e4cc7b0c1a64")
        #expect(first.company == "acmerobotics")
        #expect(first.title == "Senior Software Engineer")
        #expect(first.location == "Toronto")
        #expect(first.otherLocations == ["Vancouver"])
        #expect(first.countryHint == "CA")
        #expect(first.workplace == .remote)
        #expect(first.postedAt == Date(timeIntervalSince1970: 1_791_566_108.174))
        // Intro, then each titled list (where the requirements live), then the closing note.
        #expect(
            first.descriptionHTML
                == "<div>Our platform team keeps the robots talking.</div>"
                + "<h3>What You'll Do</h3><ul><div>\n\n<li>Run Kubernetes clusters</li>\n"
                + "<li>Own on-call for R&amp;D services</li></div></ul>"
                + "<h3>Who You Are &amp; What You Bring</h3><ul><li>5+ years with Go</li></ul>"
                + "<div>Acme Robotics is an equal opportunity employer.</div>")

        let second = postings[1]
        #expect(second.workplace == nil)  // "unspecified"
        #expect(second.countryHint == nil && second.otherLocations.isEmpty)
        #expect(second.descriptionHTML == "<p>Short contract.</p>")
    }

    @Test func anEmptyBoardIsNoPostingsNotAnError() async throws {
        let (http, _) = ScriptedURLProtocol.client([url: .http(status: 200, body: Data("[]".utf8))])
        let source = LeverSource(id: sourceID, slug: "acmerobotics", http: http)
        #expect(try await source.fetch(SourceQuery(companyName: "Acme")).isEmpty)
    }

    @Test func anUnknownCompanyIsNotFound() async {
        let missing = "https://api.lever.co/v0/postings/nobody?mode=json"
        let body = Data(#"{"ok":false,"error":"Document not found"}"#.utf8)  // as Lever sends it
        let (http, _) = ScriptedURLProtocol.client([missing: .http(status: 404, body: body)])
        await #expect(throws: SourceError.notFound(endpoint: "api.lever.co/v0/postings/nobody")) {
            try await LeverSource(id: sourceID, slug: "nobody", http: http).fetch(SourceQuery())
        }
    }

    @Test func rejectsASlugThatCouldLeaveItsPath() async {
        let (http, script) = ScriptedURLProtocol.client([:])
        await #expect(throws: SourceError.invalidConfiguration("Lever company slug: ../x")) {
            try await LeverSource(id: sourceID, slug: "../x", http: http).fetch(SourceQuery())
        }
        #expect(script.requests.isEmpty)
    }
}

@Suite("Ashby source")
struct AshbySourceTests {
    let url = "https://api.ashbyhq.com/posting-api/job-board/acmerobotics"

    @Test func mapsARecordedJobBoardAndSkipsUnlistedJobs() async throws {
        let body = try ScriptedURLProtocol.fixture("ashby_job_board.json")
        let (http, _) = ScriptedURLProtocol.client([url: .http(status: 200, body: body)])
        let source = AshbySource(id: sourceID, organization: "acmerobotics", http: http)
        let postings = try await source.fetch(SourceQuery(companyName: "Acme Robotics"))

        #expect(postings.map(\.title) == ["Staff Data Engineer", "Solutions Engineer"])
        let first = postings[0]
        #expect(
            first.url.absoluteString == "https://jobs.ashbyhq.com/acmerobotics/d3bc1ced-3ce4-4086-a050-555055dbb1ff")
        #expect(first.company == "Acme Robotics")
        #expect(first.location == "Toronto, ON")
        #expect(first.otherLocations == ["Remote (Canada)", "Remote (US)"])
        #expect(first.countryHint == "Canada")
        #expect(first.workplace == .hybrid)
        #expect(first.postedAt == (try Date.ISO8601FormatStyle().parse("2026-10-07T17:12:35.753Z")))
        #expect(first.descriptionHTML.contains("<h3>Requirements</h3>"))

        let second = postings[1]
        #expect(second.workplace == .remote)  // no workplaceType, but isRemote
        #expect(second.countryHint == "United States")
        #expect(second.descriptionHTML == "")
    }

    @Test func rejectsAnOrganizationThatCouldLeaveItsPath() async {
        let (http, script) = ScriptedURLProtocol.client([:])
        await #expect(throws: SourceError.invalidConfiguration("Ashby organization: acme/../../admin")) {
            try await AshbySource(id: sourceID, organization: "acme/../../admin", http: http).fetch(SourceQuery())
        }
        #expect(script.requests.isEmpty)
    }
}

@Suite("ATS detection")
struct ATSDetectorTests {
    @Test(arguments: [
        ("https://boards.greenhouse.io/acmerobotics", SourceKind.greenhouse, "acmerobotics"),
        ("https://job-boards.greenhouse.io/acmerobotics/jobs/4012001002", .greenhouse, "acmerobotics"),
        (
            "boards.greenhouse.io/embed/job_board?for=acme_robotics&b=https%3A%2F%2Facme.com", .greenhouse,
            "acme_robotics"
        ),
        ("https://boards.greenhouse.io/embed/job_app?for=acme&token=4012001002", .greenhouse, "acme"),
        ("https://boards-api.greenhouse.io/v1/boards/acme/jobs?content=true", .greenhouse, "acme"),
        ("  https://jobs.lever.co/acme-robotics  ", .lever, "acme-robotics"),
        ("https://jobs.lever.co/acme/223f9722-3579-4ff2-b123-e4cc7b0c1a64/apply", .lever, "acme"),
        ("HTTPS://JOBS.LEVER.CO/acme", .lever, "acme"),
        ("https://api.lever.co/v0/postings/acme?mode=json", .lever, "acme"),
        ("jobs.ashbyhq.com/acme", .ashby, "acme"),
        ("https://jobs.ashbyhq.com/acme/d3bc1ced-3ce4-4086-a050-555055dbb1ff", .ashby, "acme"),
        ("https://jobs.ashbyhq.com/acme/embed?version=2", .ashby, "acme"),
        ("https://api.ashbyhq.com/posting-api/job-board/acme", .ashby, "acme"),
    ])
    func detectsBoardsPostingsEmbedsAndAPIs(url: String, kind: SourceKind, slug: String) {
        #expect(ATSDetector.detect(url) == .detected(kind: kind, slug: slug))
    }

    @Test(arguments: [
        (
            "https://acme.com/careers",
            "Not a job board Kairos reads. It reads Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR and Teamtailor."
        ),
        (
            "https://acme.com/careers?gh_jid=4012001002",
            "This company page embeds its job board. Open the board itself and paste that address."
        ),
        (
            "https://acme.com/jobs?ashby_jid=d3bc1ced",
            "This company page embeds its job board. Open the board itself and paste that address."
        ),
        ("https://boards.greenhouse.io/", "That\'s a Greenhouse address, but it doesn\'t say which company."),
        (
            "https://boards.greenhouse.io/embed/job_board",
            "That\'s a Greenhouse address, but it doesn\'t say which company."
        ),
        ("https://jobs.lever.co/acme%2F..%2Fadmin", "That\'s a Lever address, but it doesn\'t say which company."),
        ("https://api.ashbyhq.com/other/acme", "That\'s a Ashby address, but it doesn\'t say which company."),
        ("ftp://jobs.lever.co/acme", "That doesn't look like a web address."),
        ("not a url at all", "That doesn't look like a web address."),
    ])
    func explainsWhatItCouldntDetect(url: String, reason: String) {
        #expect(ATSDetector.detect(url) == .notDetected(reason))
    }
}
