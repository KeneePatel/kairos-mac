import Foundation
import Store
import TestSupport
import Testing

@testable import JobSources

private let sourceID = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000dd")!
private func fixture(_ name: String) throws -> Data { try ScriptedURLProtocol.fixture(name) }
private func date(_ iso: String) -> Date? { try? Date.ISO8601FormatStyle().parse(iso) }

private let srList = "https://api.smartrecruiters.com/v1/companies/AcmeRobotics/postings?limit=100&offset=0"
private func srDetail(_ n: Int) -> String {
    "https://api.smartrecruiters.com/v1/companies/AcmeRobotics/postings/\(744_000_000_000_000 + n)"
}

/// Job collection v2, J2: six more public boards, each read from an answer in the shape recorded
/// from a live board on 2026-10-23 (companies made up).
@Suite("More public boards")
struct MoreBoardsTests {
    /// SmartRecruiters is asked per country; a job's text is asked for only when it's at your roles
    /// and not already known, and the rest count as seen.
    @Test func smartRecruitersAsksForTextOnlyWhereItCounts() async throws {
        let (http, script) = ScriptedURLProtocol.client([
            srList + "&country=ca": .http(status: 200, body: try fixture("smartrecruiters_postings_ca.json")),
            srList + "&country=us": .http(status: 200, body: try fixture("smartrecruiters_postings_us.json")),
            srDetail(1): .http(status: 200, body: try fixture("smartrecruiters_posting_detail.json")),
        ])
        let known = URLCanonicalizer.canonical(
            URL(string: "https://jobs.smartrecruiters.com/AcmeRobotics/744000000000003")!)
        let query = SourceQuery(roles: RoleMatcher(families: [.software]), knownURLs: [known])
        let postings = try await SmartRecruitersSource(id: sourceID, company: "AcmeRobotics", http: http).fetch(query)

        #expect(postings.map(\.title) == ["Backend Developer", "Warehouse Associate", "Senior SDE, Robotics Platform"])
        #expect(postings.map(\.textOmitted) == [false, true, true])
        let first = postings[0]
        #expect(first.url.absoluteString == "https://jobs.smartrecruiters.com/AcmeRobotics/744000000000001")
        #expect(
            first.company == "Acme Robotics" && first.location == "Toronto, ON, Canada" && first.countryHint == "CA")
        #expect(first.workplace == .hybrid && postings[2].workplace == .remote)
        #expect(first.postedAt == date("2026-10-20T14:00:00Z"))
        // The job first, what it asks for next, the company last.
        let text = first.descriptionHTML
        let order = ["Job Description", "Qualifications", "Additional Information", "Company Description"]
            .compactMap { text.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted())
        // Two list pages and one text: the warehouse job isn't at your roles, the SDE one is known.
        #expect(script.requests.count == 3)
    }

    /// Workable's widget feed: every job with its text, places and remote flag.
    @Test func workableMapsItsFeed() async throws {
        let url = "https://apply.workable.com/api/v1/widget/accounts/acmerobotics?details=true"
        let (http, _) = ScriptedURLProtocol.client([url: .http(status: 200, body: try fixture("workable_widget.json"))])
        let postings = try await WorkableSource(id: sourceID, account: "acmerobotics", http: http).fetch(SourceQuery())
        #expect(postings.count == 2)
        let first = postings[0]
        #expect(first.title == "Full Stack Developer" && first.company == "Acme Robotics")
        #expect(
            first.location == "Halifax, Nova Scotia, Canada"
                && first.otherLocations == ["Moncton, New Brunswick, Canada"])
        #expect(first.countryHint == "CA" && first.url.absoluteString == "https://apply.workable.com/j/A1B2C3D4E5")
        #expect(first.postedAt == date("2026-10-19T00:00:00Z"))
        #expect(first.descriptionHTML.contains("React") && !first.textOmitted)
        #expect(postings[1].workplace == .remote && postings[1].location == "United States")
    }

    /// Recruitee: its requirements follow the description; its dates aren't ISO 8601.
    @Test func recruiteeAddsItsRequirements() async throws {
        let url = "https://acmerobotics.recruitee.com/api/offers/"
        let (http, _) = ScriptedURLProtocol.client([url: .http(status: 200, body: try fixture("recruitee_offers.json"))]
        )
        let posting = try #require(
            try await RecruiteeSource(id: sourceID, company: "acmerobotics", http: http).fetch(SourceQuery()).first)
        #expect(posting.title == "Data Engineer" && posting.location == "Montréal, Quebec, Canada")
        #expect(posting.otherLocations == ["Toronto, Ontario, Canada"] && posting.countryHint == "CA")
        #expect(posting.workplace == .hybrid && posting.postedAt == date("2026-10-21T13:58:01Z"))
        #expect(posting.descriptionHTML.contains("<h3>Requirements</h3><ul><li>Python and SQL"))
    }

    /// Personio's XML feed: its sections, its offices, its ETag; a name that isn't a customer is
    /// "not found", never an empty board.
    @Test func personioReadsItsXMLFeed() async throws {
        let url = "https://acmerobotics.jobs.personio.de/xml?language=en"
        let (http, _) = ScriptedURLProtocol.client([
            url: .http(status: 200, headers: ["ETag": "\"p1\""], body: try fixture("personio_feed.xml"))
        ])
        let source = PersonioSource(id: sourceID, company: "acmerobotics", http: http)
        guard case .postings(let postings, let memo) = try await source.fetch(SourceQuery(), since: nil) else {
            Issue.record("expected postings")
            return
        }
        let posting = try #require(postings.first)
        #expect(posting.title == "QA Automation Engineer" && posting.company == "Acme Robotics")
        #expect(posting.url.absoluteString == "https://acmerobotics.jobs.personio.de/job/2837809")
        #expect(posting.location == "Toronto" && posting.otherLocations == ["Waterloo"])
        #expect(posting.descriptionHTML.contains("<h3>Your role</h3><p>Write the tests"))
        #expect(posting.descriptionHTML.contains("Playwright &amp; pytest"))
        #expect(posting.postedAt == date("2026-10-21T10:00:00Z") && memo == FetchMemo(etag: "\"p1\""))

        let (same, _) = ScriptedURLProtocol.client([url: .http(status: 304)])
        #expect(
            try await PersonioSource(id: sourceID, company: "acmerobotics", http: same).fetch(
                SourceQuery(), since: memo)
                == .unchanged)
        let (redirect, _) = ScriptedURLProtocol.client([
            url: .http(status: 307, headers: ["Location": "https://www.personio.com"])
        ])
        await #expect(throws: SourceError.notFound(endpoint: "acmerobotics.jobs.personio.de/xml")) {
            try await PersonioSource(id: sourceID, company: "acmerobotics", http: redirect).fetch(SourceQuery())
        }
    }

    /// BambooHR: the list, then the text of a job at your roles; a name that isn't a customer
    /// redirects, which is "not found".
    @Test func bambooHRAsksForTextAtYourRoles() async throws {
        let (http, script) = ScriptedURLProtocol.client([
            "https://acmerobotics.bamboohr.com/careers/list": .http(
                status: 200, body: try fixture("bamboohr_list.json")),
            "https://acmerobotics.bamboohr.com/careers/761/detail": .http(
                status: 200, body: try fixture("bamboohr_detail.json")),
        ])
        let postings = try await BambooHRSource(id: sourceID, company: "acmerobotics", http: http)
            .fetch(SourceQuery(roles: RoleMatcher(families: [.devops])))
        #expect(postings.map(\.title) == ["Platform Engineer", "Payroll Specialist"])
        #expect(postings.map(\.textOmitted) == [false, true] && script.requests.count == 2)
        #expect(postings[0].location == "Toronto, Ontario, Canada" && postings[0].countryHint == "Canada")
        #expect(postings[0].url.absoluteString == "https://acmerobotics.bamboohr.com/careers/761")
        #expect(
            postings[0].descriptionHTML.contains("Kubernetes")
                && postings[0].postedAt == date("2026-10-20T00:00:00Z"))

        let (redirect, _) = ScriptedURLProtocol.client([
            "https://nobody.bamboohr.com/careers/list": .http(
                status: 302, headers: ["Location": "https://www.bamboohr.com/"])
        ])
        await #expect(throws: SourceError.notFound(endpoint: "nobody.bamboohr.com/careers/list")) {
            try await BambooHRSource(id: sourceID, company: "nobody", http: redirect).fetch(SourceQuery())
        }
    }

    /// Teamtailor's RSS: the escaped HTML comes back as HTML, its places and remote status.
    @Test func teamtailorReadsItsRSS() async throws {
        let url = "https://acmerobotics.teamtailor.com/jobs.rss"
        let (http, _) = ScriptedURLProtocol.client([
            url: .http(status: 200, headers: ["ETag": "\"t1\""], body: try fixture("teamtailor_jobs.rss"))
        ])
        guard
            case .postings(let postings, let memo) = try await TeamtailorSource(
                id: sourceID, company: "acmerobotics", http: http
            ).fetch(SourceQuery(), since: nil),
            let posting = postings.first
        else {
            Issue.record("expected a posting")
            return
        }
        #expect(posting.title == "Site Reliability Engineer" && posting.company == "Acme Robotics")
        #expect(posting.location == "Ottawa, Canada" && posting.countryHint == "Canada" && posting.workplace == .hybrid)
        #expect(posting.descriptionHTML.hasPrefix("<h4>Keep the fleet up</h4>"))
        #expect(posting.descriptionHTML.contains("Kubernetes &amp; on-call"))
        #expect(posting.postedAt == date("2026-10-23T07:05:16Z") && memo == FetchMemo(etag: "\"t1\""))
    }

    /// A pasted address names its board; a vendor's own site isn't a company; Workday says why not.
    @Test(arguments: [
        (
            "https://jobs.smartrecruiters.com/AcmeRobotics/744000000000001-backend", SourceKind.smartRecruiters,
            "AcmeRobotics"
        ),
        ("https://careers.smartrecruiters.com/AcmeRobotics", .smartRecruiters, "AcmeRobotics"),
        ("https://apply.workable.com/acme-robotics/", .workable, "acme-robotics"),
        ("https://apply.workable.com/api/v1/widget/accounts/acmerobotics", .workable, "acmerobotics"),
        ("https://acmerobotics.workable.com", .workable, "acmerobotics"),
        ("https://acmerobotics.recruitee.com/o/data-engineer", .recruitee, "acmerobotics"),
        ("https://acmerobotics.jobs.personio.de/job/2837809", .personio, "acmerobotics"),
        ("acmerobotics.jobs.personio.com", .personio, "acmerobotics"),
        ("https://acmerobotics.bamboohr.com/careers/761", .bambooHR, "acmerobotics"),
        ("https://acmerobotics.teamtailor.com/jobs", .teamtailor, "acmerobotics"),
    ])
    func detectsTheNewBoards(_ url: String, _ kind: SourceKind, _ slug: String) {
        #expect(ATSDetector.detect(url) == .detected(kind: kind, slug: slug))
    }

    @Test func vendorSitesAndWorkdayAreExplained() {
        guard case .notDetected(let workday) = ATSDetector.detect("https://acme.wd3.myworkdayjobs.com/External") else {
            Issue.record("Workday should be explained")
            return
        }
        #expect(workday.contains("Workday") && workday.contains("Adzuna"))
        for vendor in [
            "https://www.bamboohr.com/careers", "https://app.teamtailor.com", "https://apply.workable.com/j/A1B2",
        ] {
            if case .detected = ATSDetector.detect(vendor) { Issue.record("\(vendor) isn't a company's board") }
        }
        #expect(
            SourceKind.boards.count == 9 && SourceKind.boards.allSatisfy { !$0.isSearch } && SourceKind.adzuna.isSearch)
    }

    /// Every new kind is built from its board config, with your roles for the boards that need them.
    @Test func theFactoryBuildsEveryBoard() throws {
        let (http, _) = ScriptedURLProtocol.client([:])
        let roles = RoleMatcher(families: [.qa])
        let search = SearchContext(query: SourceQuery(countries: [.canada], maxAgeDays: 7, roles: roles))
        for kind in [SourceKind.smartRecruiters, .workable, .recruitee, .personio, .bambooHR, .teamtailor] {
            let source = Source(
                id: sourceID, kind: kind, config: BoardConfig(slug: "acmerobotics", company: "Acme").json)
            let (board, query) = try SourceFactory.make(source, http: http, search: search)
            #expect(board.listsEverything && query.companyName == "Acme" && query.roles == roles, "\(kind)")
            #expect(query.countries == [.canada] && query.maxAgeDays == 7)
        }
    }
}
