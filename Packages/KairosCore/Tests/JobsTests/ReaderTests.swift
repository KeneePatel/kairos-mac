import Foundation
import KairosKit
import TestKit
import Testing

@testable import Jobs

private let acme = Board(kind: .greenhouse, slug: "acmerobotics", name: "Acme Robotics")
private let software = RoleMatcher(families: [.software])

/// Each reader against an answer recorded from a live board (companies made up), checked again
/// against the live APIs on 2026-10-28.
@Suite("Company boards")
struct BoardReaderTests {
    static let light = "https://boards-api.greenhouse.io/v1/boards/acmerobotics/jobs"
    static let full = "https://boards-api.greenhouse.io/v1/boards/acmerobotics/jobs?content=true"

    /// The light list without texts, as Greenhouse sends it.
    static func lightList() throws -> String {
        var page = try JSONValue(parsing: try Fixtures.data("boards/greenhouse_jobs.json"))
        guard case .object(var object) = page, case .array(let jobs) = object["jobs"] else { return "" }
        object["jobs"] = .array(
            jobs.map { job in
                guard case .object(var fields) = job else { return job }
                fields["content"] = nil
                return .object(fields)
            })
        page = .object(object)
        return page.text
    }

    @Test func greenhouseAsksForTextsOnlyAtYourRoles() async throws {
        let detail = try JSONValue(parsing: try Fixtures.data("boards/greenhouse_jobs.json"))["jobs"]?.arrayValue?.first
        let http = FakeHTTP([
            Self.light: .json(try Self.lightList(), headers: ["ETag": "W/\"v1\""]),
            Self.light + "/4012001002?pay_transparency=true": .json(detail?.text ?? ""),
        ])
        let result = try await GreenhouseReader(board: acme, http: http, clock: ManualWallClock(isoDate("2026-10-20T00:00:00Z")))
            .read(ReadRequest(roles: software))
        #expect(result.complete && result.etag == "W/\"v1\"" && result.requests == 2)
        #expect(result.postings.map(\.title) == ["Backend Engineer, Platform", "Développeur(se) mobile", "Site Reliability Engineer"])
        #expect(result.postings.map(\.textOmitted) == [false, true, true])
        let first = result.postings[0]
        #expect(first.company == "Acme Robotics" && first.location == "Toronto, ON")
        #expect(first.url.absoluteString == "https://job-boards.greenhouse.io/acmerobotics/jobs/4012001002")
        #expect(first.postedAt == isoDate("2026-10-02T11:31:50-04:00"))  // first published, not edited
        #expect(first.descriptionHTML.contains("<h3>What you&rsquo;ll do</h3>"))  // decoded once only
        #expect(result.postings[2].postedAt == isoDate("2026-09-30T08:15:00-05:00"))  // no first_published
    }

    @Test func greenhouseReadsTheWholeBoardWhenManyTextsAreWanted() async throws {
        let jobs = (1...30).map { index in
            #"{"id":\#(index),"title":"Software Engineer \#(index)","absolute_url":"https://job-boards.greenhouse.io/acmerobotics/jobs/\#(index)","location":{"name":"Toronto"}}"#
        }
        let list = #"{"jobs":[\#(jobs.joined(separator: ","))]}"#
        let http = FakeHTTP([Self.light: .json(list), Self.full: .json(list)])
        let result = try await GreenhouseReader(board: acme, http: http).read(ReadRequest(roles: software))
        #expect(http.requestedURLs == [Self.light, Self.full])
        #expect(result.postings.count == 30 && result.postings.allSatisfy { !$0.textOmitted })
    }

    @Test func anUnchangedBoardSaysSo() async throws {
        let http = FakeHTTP([Self.light: .status(304)])
        let result = try await GreenhouseReader(board: acme, http: http).read(ReadRequest(etag: "W/\"v1\""))
        #expect(result.unchanged && result.etag == "W/\"v1\"" && result.postings.isEmpty)
        #expect(http.requests.first?.headers["If-None-Match"] == "W/\"v1\"")
    }

    @Test(arguments: ["", "acme/../admin", "acme?x=1", "..", "acme robotics", "acmé", String(repeating: "a", count: 101)])
    func refusesASlugThatCouldLeaveItsPath(_ slug: String) async {
        let http = FakeHTTP()
        await #expect(throws: SourceError.invalidConfiguration("Greenhouse board token: \(slug)")) {
            _ = try await GreenhouseReader(board: Board(kind: .greenhouse, slug: slug, name: ""), http: http)
                .read(ReadRequest())
        }
        #expect(http.requests.isEmpty)
    }

    @Test func failuresKeepTheirMeaning() async {
        let gone = FakeHTTP([Self.light: .status(404)])
        await #expect(throws: SourceError.notFound(endpoint: "boards-api.greenhouse.io/v1/boards/acmerobotics/jobs")) {
            _ = try await GreenhouseReader(board: acme, http: gone).read(ReadRequest())
        }
        let slow = FakeHTTP([Self.light: .failure(.timedOut(endpoint: "boards-api.greenhouse.io"))])
        await #expect(throws: SourceError.timedOut(endpoint: "boards-api.greenhouse.io")) {
            _ = try await GreenhouseReader(board: acme, http: slow).read(ReadRequest())
        }
        let changed = FakeHTTP([Self.light: .json(#"{"jobs":[{"title":"No URL"}]}"#)])
        await #expect(throws: SourceError.decoding("jobs[0].absoluteUrl: missing")) {
            _ = try await GreenhouseReader(board: acme, http: changed).read(ReadRequest())
        }
        let limited = FakeHTTP([Self.light: .status(429, headers: ["Retry-After": "30"])])
        await #expect(throws: SourceError.rateLimited(retryAfterSeconds: 30)) {
            _ = try await GreenhouseReader(board: acme, http: limited).read(ReadRequest())
        }
    }

    @Test func leverJoinsItsSectionsInPageOrder() async throws {
        let url = "https://api.lever.co/v0/postings/acmerobotics?mode=json"
        let http = FakeHTTP([url: try .fixture("boards/lever_postings.json", headers: ["ETag": "e1"])])
        let board = Board(kind: .lever, slug: "acmerobotics", name: "")
        let result = try await LeverReader(board: board, http: http).read(ReadRequest())
        #expect(result.postings.count == 2 && result.etag == "e1")
        let first = result.postings[0]
        #expect(first.url.absoluteString == "https://jobs.lever.co/acmerobotics/223f9722-3579-4ff2-b123-e4cc7b0c1a64")
        #expect(first.company == "acmerobotics" && first.title == "Senior Software Engineer")
        #expect(first.location == "Toronto" && first.otherLocations == ["Vancouver"] && first.countryHint == "CA")
        #expect(first.workplace == .remote && first.postedAt == Date(timeIntervalSince1970: 1_791_566_108.174))
        #expect(result.postings[1].workplace == nil)  // "unspecified"
        let eu = FakeHTTP(["https://api.eu.lever.co/v0/postings/acme?mode=json": .json("[]")])
        _ = try await LeverReader(board: Board(kind: .lever, slug: "acme", name: "Acme", region: "eu"), http: eu)
            .read(ReadRequest())
        #expect(eu.requests.count == 1)
    }

    @Test func ashbyLeavesOutUnlistedJobs() async throws {
        let url = "https://api.ashbyhq.com/posting-api/job-board/acmerobotics?includeCompensation=true"
        let http = FakeHTTP([url: try .fixture("boards/ashby_job_board.json")])
        let result = try await AshbyReader(board: Board(kind: .ashby, slug: "acmerobotics", name: "Acme Robotics"), http: http)
            .read(ReadRequest())
        #expect(result.postings.map(\.title) == ["Staff Data Engineer", "Solutions Engineer"])
        let first = result.postings[0]
        #expect(first.location == "Toronto, ON" && first.otherLocations == ["Remote (Canada)", "Remote (US)"])
        #expect(first.countryHint == "Canada" && first.workplace == .hybrid)
        #expect(first.postedAt == isoDate("2026-10-07T17:12:35.753Z"))
        #expect(result.postings[1].workplace == .remote)  // no workplaceType, but isRemote
    }

    @Test func smartRecruitersAsksForTextOnlyWhereItCounts() async throws {
        let list = "https://api.smartrecruiters.com/v1/companies/AcmeRobotics/postings?limit=100&offset=0&country="
        let detail = "https://api.smartrecruiters.com/v1/companies/AcmeRobotics/postings/744000000000001"
        let http = FakeHTTP([
            list + "ca": try .fixture("boards/smartrecruiters_postings_ca.json"),
            list + "us": try .fixture("boards/smartrecruiters_postings_us.json"),
            detail: try .fixture("boards/smartrecruiters_posting_detail.json"),
        ])
        let known = URLCanonicalizer.canonical("https://jobs.smartrecruiters.com/AcmeRobotics/744000000000003")
        let board = Board(kind: .smartRecruiters, slug: "AcmeRobotics", name: "")
        let result = try await SmartRecruitersReader(board: board, http: http)
            .read(ReadRequest(roles: software, knownURLs: [known]))
        #expect(result.postings.map(\.title) == ["Backend Developer", "Warehouse Associate", "Senior SDE, Robotics Platform"])
        #expect(result.postings.map(\.textOmitted) == [false, true, true])
        #expect(result.requests == 3)
        let text = result.postings[0].descriptionHTML
        let order = ["Job Description", "Qualifications", "Additional Information", "Company Description"]
            .compactMap { text.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted())
    }

    @Test func workableRecruiteeBambooPersonioAndTeamtailor() async throws {
        let http = FakeHTTP([
            "https://apply.workable.com/api/v1/widget/accounts/acme?details=true": try .fixture("boards/workable_widget.json"),
            "https://acme.recruitee.com/api/offers/": try .fixture("boards/recruitee_offers.json"),
            "https://acme.bamboohr.com/careers/list": try .fixture("boards/bamboohr_list.json"),
            "https://acme.bamboohr.com/careers/761/detail": try .fixture("boards/bamboohr_detail.json"),
            "https://acme.jobs.personio.de/xml?language=en": try .fixture("boards/personio_feed.xml", headers: ["ETag": "p1"]),
            "https://acme.teamtailor.com/jobs.rss": try .fixture("boards/teamtailor_jobs.rss"),
        ])
        func board(_ kind: SourceKind) -> Board { Board(kind: kind, slug: "acme", name: "") }

        let workable = try await WorkableReader(board: board(.workable), http: http).read(ReadRequest())
        #expect(workable.postings.map(\.title) == ["Full Stack Developer", "Field Technician"])
        #expect(workable.postings[0].location == "Halifax, Nova Scotia, Canada")
        #expect(workable.postings[0].otherLocations == ["Moncton, New Brunswick, Canada"])
        #expect(workable.postings[0].company == "Acme Robotics")

        let recruitee = try await RecruiteeReader(board: board(.recruitee), http: http).read(ReadRequest())
        #expect(recruitee.postings.map(\.title) == ["Data Engineer"])
        #expect(recruitee.postings[0].descriptionHTML.contains("<h3>Requirements</h3>"))
        #expect(recruitee.postings[0].salary?.min == 90_000 && recruitee.postings[0].salary?.currency == "CAD")

        let bamboo = try await BambooHRReader(board: board(.bambooHR), http: http)
            .read(ReadRequest(roles: RoleMatcher(families: [.software, .devops])))
        #expect(bamboo.postings.map(\.title) == ["Platform Engineer", "Payroll Specialist"])
        #expect(bamboo.postings.map(\.textOmitted) == [false, true])

        let personio = try await PersonioReader(board: board(.personio), http: http).read(ReadRequest())
        #expect(personio.postings.map(\.title) == ["QA Automation Engineer"] && personio.etag == "p1")
        #expect(personio.postings[0].location == "Toronto" && personio.postings[0].otherLocations == ["Waterloo"])
        #expect(personio.postings[0].descriptionHTML.contains("<h3>What you bring</h3>"))

        let teamtailor = try await TeamtailorReader(board: board(.teamtailor), http: http).read(ReadRequest())
        #expect(teamtailor.postings.map(\.title) == ["Site Reliability Engineer"])
        #expect(teamtailor.postings[0].location == "Ottawa, Canada" && teamtailor.postings[0].workplace == .hybrid)
        #expect(teamtailor.postings[0].postedAt == isoDate("2026-10-23T07:05:16Z"))
        #expect(teamtailor.postings[0].company == "Acme Robotics")
    }

    @Test func aRedirectToTheVendorIsNotFound() async throws {
        let http = FakeHTTP { request in
            request.url.host() == "nobody.bamboohr.com" ? .moved(to: "https://www.bamboohr.com/") : nil
        }
        await #expect(throws: SourceError.notFound(endpoint: "nobody.bamboohr.com/careers/list")) {
            _ = try await BambooHRReader(board: Board(kind: .bambooHR, slug: "nobody", name: ""), http: http)
                .read(ReadRequest())
        }
    }
}

@Suite("Searches")
struct SearchReaderTests {
    @Test func himalayasSearchesYourRolesAndUsesItsApplyLink() async throws {
        let now = isoDate("2026-10-20T00:00:00Z")
        let page = """
            {"jobs":[{"title":"Backend Engineer","companyName":"Acme","guid":"https://himalayas.app/companies/acme/jobs/backend",
            "applicationLink":"https://boards.greenhouse.io/acme/jobs/1","description":"<p>Build our fleet API.</p>",
            "pubDate":\(now.timeIntervalSince1970 - 86_400),"expiryDate":\(now.timeIntervalSince1970 + 86_400),
            "locationRestrictions":["Canada"],"minSalary":100000,"maxSalary":120000,"currency":"CAD","salaryPeriod":"year"},
            {"title":"Old","companyName":"Old Co","guid":"https://himalayas.app/x","pubDate":\(now.timeIntervalSince1970 - 40 * 86_400)},
            {"title":"Expired","companyName":"Gone","guid":"https://himalayas.app/y","expiryDate":\(now.timeIntervalSince1970 - 10)}]}
            """
        let http = FakeHTTP { request in
            request.url.host() == "himalayas.app" && request.url.query()?.contains("page=1") == true
                ? .json(page) : .json(#"{"jobs":[]}"#)
        }
        let reader = HimalayasReader(key: "him-key", http: http, clock: ManualWallClock(now))
        let result = try await reader.read(
            ReadRequest(roles: RoleMatcher(families: [], extra: ["backend engineer"]), countries: [.canada], maxAgeDays: 30))
        #expect(result.postings.map(\.title) == ["Backend Engineer"] && !result.complete)
        let posting = try #require(result.postings.first)
        #expect(posting.location == "Remote - Canada" && posting.workplace == .remote && posting.countryHint == "CA")
        #expect(posting.applyURL?.absoluteString == "https://boards.greenhouse.io/acme/jobs/1" && posting.via == "Himalayas")
        #expect(posting.salary?.max == 120_000 && posting.salary?.period == .year)
        #expect(http.requests.first?.headers["Authorization"] == "Bearer him-key")
    }

    @Test func googleJobsLinksToThePageGoogleTookTheJobFrom() async throws {
        let now = isoDate("2026-10-26T12:00:00Z")
        let http = FakeHTTP { request in
            request.url.host() == "serpapi.com" ? try? .fixture("boards/serpapi_google_jobs.json") : nil
        }
        let turn = SearchTurn(phrase: "software developer", place: Place(city: "Toronto", region: "Ontario", country: .canada), country: .canada)
        let result = try await GoogleJobsReader(key: "serp-key", http: http, clock: ManualWallClock(now))
            .read(ReadRequest(budget: 1, turns: [turn]))
        #expect(result.requests == 1 && result.postings.count == 5)
        let query = try #require(http.requests.first?.url.query())
        #expect(query.contains("location=Toronto,%20Ontario,%20Canada") && query.contains("engine=google_jobs"))
        let byCompany = Dictionary(result.postings.map { ($0.company, $0) }) { first, _ in first }
        let scotiabank = try #require(byCompany["Scotiabank"])
        let page = "https://jobs.scotiabank.com/job/Toronto-Software-Developer-ON-M5A-3X5/607183517/"
        #expect(scotiabank.url.absoluteString == page && scotiabank.applyURL?.absoluteString == page)
        #expect(scotiabank.postedAt == now.addingTimeInterval(-7 * 86_400))
        let softline = try #require(byCompany["Softline Technology"])
        #expect(softline.url.absoluteString == "https://ca.indeed.com/viewjob?jk=46a439dfd909f1d0")
        #expect(softline.applyURL?.absoluteString == "https://softlinetechnology.com/job/title-dashed-rq10575/")
        #expect(byCompany["Info-Tech Research Group"]?.postedAt == nil)
    }

    @Test func adzunaGivesSnippetsCanadaFirstWithinItsBudget() async throws {
        let http = FakeHTTP { request in
            guard request.url.host() == "api.adzuna.com" else { return nil }
            let path = request.url.path()
            if path.contains("/jobs/ca/search/1") { return try? .fixture("boards/adzuna_search_ca.json") }
            if path.contains("/jobs/us/search/1") { return try? .fixture("boards/adzuna_search_us.json") }
            return .json(#"{"results":[]}"#)
        }
        let reader = AdzunaReader(credentials: .init(appID: "test-id", appKey: "test-key"), http: http)
        let roles = RoleMatcher(families: [], extra: ["software developer"])
        let result = try await reader.read(ReadRequest(roles: roles, budget: 2))
        #expect(http.requests.map { $0.url.path() } == ["/v1/api/jobs/ca/search/1", "/v1/api/jobs/us/search/1"])
        #expect(result.postings.allSatisfy(\.isSnippet) && result.requests == 2)
        #expect(result.postings.map(\.company).prefix(3) == ["Northline Freight", "Maplepay", "Company not listed"])
        #expect(result.postings[0].title == "Software Developer, Backend")  // its highlighting removed
        let query = try #require(http.requests.first?.url.query())
        #expect(query.contains("title_only=software%20developer") && query.contains("sort_by=date"))

        let rejected = FakeHTTP { _ in .status(401) }
        let error = await #expect(throws: SourceError.self) {
            _ = try await AdzunaReader(credentials: .init(appID: "i", appKey: "secret"), http: rejected)
                .read(ReadRequest(roles: roles))
        }
        #expect(error?.message.contains("secret") == false)
    }

    @Test func searchesNeedRolesAndKeys() async {
        await #expect(throws: SourceError.self) {
            _ = try await HimalayasReader(key: nil, http: FakeHTTP()).read(ReadRequest())
        }
        guard case .failure = Readers.search(.googleJobs, keys: .init(), http: FakeHTTP()) else {
            Issue.record("Google Jobs without a key"); return
        }
        guard case .success = Readers.search(.himalayas, keys: .init(), http: FakeHTTP()) else {
            Issue.record("Himalayas works without a key"); return
        }
    }
}
