import Foundation
import KairosKit
import Testing

@testable import Jobs

@Suite("URL canonicalization")
struct URLCanonicalizerTests {
    @Test(arguments: [
        (
            "https://job-boards.greenhouse.io/acme/jobs/123?gh_src=abc&utm_source=linkedin&utm_medium=social",
            "https://job-boards.greenhouse.io/acme/jobs/123"
        ),
        ("http://Boards.Greenhouse.io/acme/jobs/123/", "https://job-boards.greenhouse.io/acme/jobs/123"),
        ("https://jobs.lever.co/acme/2233?lever-source=LinkedIn#apply", "https://jobs.lever.co/acme/2233"),
        ("https://acme.com:443/careers?gh_jid=42&ref=hn", "https://acme.com/careers?gh_jid=42"),
        ("https://acme.com/jobs?b=2&a=1&UTM_Campaign=x", "https://acme.com/jobs?a=1&b=2"),
        ("https://acme.com/", "https://acme.com/"),
        ("https://www.adzuna.ca/land/ad/4790012001?se=Ab12&v=9F", "https://www.adzuna.ca/land/ad/4790012001"),
        ("https://jobs.example.com/view?id=7", "https://jobs.example.com/view?id=7"),
    ])
    func dropsTrackingAndNormalizesTheRest(input: String, expected: String) {
        #expect(URLCanonicalizer.canonical(input) == expected)
    }

    @Test func trackingDoesntChangeTheID() {
        let plain = URLCanonicalizer.canonical("https://jobs.lever.co/acme/2233")
        let tracked = URLCanonicalizer.canonical("https://jobs.lever.co/acme/2233/?utm_source=x&trk=y")
        #expect(StableID.of(plain) == StableID.of(tracked))
    }
}

@Suite("Normalizing postings")
struct NormalizerTests {
    @Test func aPostingBecomesAListing() throws {
        let posting = Posting(
            url: try #require(URL(string: "https://jobs.lever.co/acme/1?lever-source=x")), company: "  Acme   Inc ",
            title: "Backend  Developer", location: "Toronto, ON (Hybrid)",
            descriptionHTML: "<p>Build <b>Go</b> services.</p>", otherLocations: ["Remote (Canada)", "Toronto, ON (Hybrid)"],
            applyURL: URL(string: "https://jobs.lever.co/acme/1?lever-source=x"))
        let listing = try #require(Normalizer.normalize(posting))
        #expect(listing.canonicalURL == "https://jobs.lever.co/acme/1")
        #expect(listing.id == StableID.of("https://jobs.lever.co/acme/1"))
        #expect(listing.company == "Acme Inc" && listing.title == "Backend Developer")
        #expect(listing.location == "Toronto, ON (Hybrid); Remote (Canada)")
        #expect(listing.country == .canada && listing.region == "ON" && listing.remoteScope == .hybrid)
        #expect(listing.description == "Build **Go** services.")
        #expect(listing.applyURL == nil)  // the same page as its own address
        #expect(listing.dedupKey == "acme|backend developer|toronto")
    }

    @Test func aPostingOutsideCanadaAndTheUSIsDropped() throws {
        let posting = Posting(
            url: try #require(URL(string: "https://x.example/1")), company: "X", title: "Engineer",
            location: "Berlin, Germany")
        #expect(Normalizer.normalize(posting) == nil)
    }

    @Test func anEditChangesTheHashButNotTheID() throws {
        let url = try #require(URL(string: "https://x.example/1"))
        let first = try #require(Normalizer.normalize(Posting(url: url, company: "X", title: "A", location: "Toronto")))
        let edited = try #require(
            Normalizer.normalize(Posting(url: url, company: "X", title: "A", location: "Toronto", descriptionHTML: "new")))
        #expect(first.id == edited.id && first.contentHash != edited.contentHash)
    }
}

@Suite("De-duplication")
struct DedupTests {
    @Test func keysFoldCompaniesTitlesAndCities() {
        #expect(DedupKey.make(company: "The Acme Corp.", title: "Sr. Software Eng", city: "Montréal") ==
            "acme|senior software engineer|montreal")
        #expect(DedupKey.company("Syndio, Inc.") == "syndio")
    }

    @Test func sameJobNeedsTheSameCompanyCityAndCloseTitles() {
        let a = DedupKey.make(company: "Acme", title: "Senior Software Engineer", city: "Toronto")
        let b = DedupKey.make(company: "Acme Inc", title: "Sr. Software Engineer", city: "Toronto")
        let nextLevel = DedupKey.make(company: "Acme", title: "Senior Software Engineer II", city: "Toronto")
        let other = DedupKey.make(company: "Acme", title: "Senior Software Engineer", city: "Vancouver")
        let noCity = DedupKey.make(company: "Acme", title: "Senior Software Engineer", city: nil)
        #expect(Similarity.isSameJob(a, b) && Similarity.isSameJob(a, noCity))
        #expect(!Similarity.isSameJob(a, other))
        #expect(!Similarity.isSameJob(a, nextLevel))  // 0.89: another level can be another opening
        // Titles alone: a shared company and city once made these 0.91 alike.
        #expect(
            !Similarity.isSameJob(
                DedupKey.make(company: "Acme", title: "QA Engineer", city: "Toronto"),
                DedupKey.make(company: "Acme", title: "Data Engineer", city: "Toronto")))
        #expect(Similarity.of("", "") == 1 && Similarity.of("abc", "") == 0)
    }
}

@Suite("Finding boards")
struct DiscoveryTests {
    @Test(arguments: [
        ("https://boards.greenhouse.io/acme", SourceKind.greenhouse, "acme"),
        ("job-boards.greenhouse.io/acme/jobs/4012001002", .greenhouse, "acme"),
        ("https://boards.greenhouse.io/embed/job_board?for=acme", .greenhouse, "acme"),
        ("https://boards-api.greenhouse.io/v1/boards/acme/jobs", .greenhouse, "acme"),
        ("https://jobs.lever.co/acme/2233", .lever, "acme"),
        ("https://jobs.ashbyhq.com/acme/embed", .ashby, "acme"),
        ("https://jobs.smartrecruiters.com/AcmeRobotics/744000000000001", .smartRecruiters, "AcmeRobotics"),
        ("https://apply.workable.com/acme/j/ABC123", .workable, "acme"),
        ("https://apply.workable.com/api/v1/widget/accounts/acme", .workable, "acme"),
        ("https://acme.recruitee.com/o/backend", .recruitee, "acme"),
        ("https://acme.jobs.personio.de/job/1", .personio, "acme"),
        ("https://acme.bamboohr.com/careers/12", .bambooHR, "acme"),
        ("https://acme.teamtailor.com/jobs", .teamtailor, "acme"),
    ])
    func detectsBoardsPostingsEmbedsAndAPIs(url: String, kind: SourceKind, slug: String) {
        #expect(ATSDetector.detect(url) == .board(kind: kind, slug: slug, region: nil))
    }

    @Test func leverEUAndWhatItCantRead() {
        #expect(ATSDetector.detect("https://jobs.eu.lever.co/acme") == .board(kind: .lever, slug: "acme", region: "eu"))
        guard case .notABoard(let workday) = ATSDetector.detect("https://acme.wd3.myworkdayjobs.com/en-US/careers")
        else { Issue.record("Workday should be refused"); return }
        #expect(workday.contains("Workday"))
        guard case .notABoard = ATSDetector.detect("https://boards.greenhouse.io/") else {
            Issue.record("a board address without a company"); return
        }
        guard case .notABoard = ATSDetector.detect("not a url at all") else { Issue.record("not a URL"); return }
        guard case .notABoard = ATSDetector.detect("https://www.recruitee.com/") else {
            Issue.record("the vendor's own site"); return
        }
    }

    @Test func boardsBehindASearchsLinks() throws {
        let postings = [
            Posting(
                url: try #require(URL(string: "https://ca.indeed.com/viewjob?jk=1")), company: "Acme", title: "Dev",
                location: "Toronto", links: [try #require(URL(string: "https://jobs.lever.co/acme/1"))]),
            Posting(
                url: try #require(URL(string: "https://jobs.lever.co/acme/2")), company: "Acme", title: "Dev 2",
                location: "Toronto"),
            Posting(
                url: try #require(URL(string: "https://boards.greenhouse.io/talentco/jobs/1")),
                company: "Talent Staffing Agency", title: "Dev", location: "Toronto"),
        ]
        #expect(ATSDetector.boards(behind: postings) == [Board(kind: .lever, slug: "acme", name: "Acme")])
    }

    @Test func theCatalogShipsAndLeavesOutAggregators() {
        let catalog = BoardCatalog.bundled
        #expect(catalog.entries.count > 3_000)
        let canadian = catalog.boards(in: [.canada])
        #expect(canadian.count > 700)
        #expect(canadian.allSatisfy { !BoardCatalog.isAggregator($0.name) })
        #expect(catalog.board(forCompany: "1Password Inc.")?.kind == .ashby)
        #expect(BoardCatalog.isAggregator("Jooble") && BoardCatalog.isAggregator("Acme Staffing"))
        #expect(!BoardCatalog.isAggregator("Shopify"))
    }

    @Test func jobBoardHostsAndCompanyNames() throws {
        #expect(JobBoards.isJobBoard(try #require(URL(string: "https://ca.indeed.com/viewjob?jk=1"))))
        #expect(!JobBoards.isJobBoard(try #require(URL(string: "https://jobs.scotiabank.com/job/1"))))
        #expect(
            JobBoards.stripped(try #require(URL(string: "https://a.example/j?utm_source=x&id=2&ref=y"))).absoluteString
                == "https://a.example/j?id=2")
        #expect(JobBoards.names("Softline Careers", company: "Softline Technology", via: nil))
        #expect(!JobBoards.names("Indeed", company: "Softline Technology", via: "LinkedIn"))
        #expect(JobBoards.names("LinkedIn", company: "Acme", via: "LinkedIn"))
    }

    @Test func likelySlugs() {
        #expect(BoardProbe.slugs(for: "Traction Rec Inc.") == ["tractionrec", "traction-rec"])
        #expect(BoardProbe.slugs(for: "The Group") == ["thegroup", "the-group"])
        #expect(BoardProbe.slugs(for: "Syndio") == ["syndio"])
    }
}

@Suite("Google Jobs turns")
struct SearchTurnTests {
    @Test func everyPhraseInEveryPlaceThenRemoteInEachCountry() {
        let places = [Place(city: "Toronto", region: "Ontario", country: .canada)]
        let turns = SearchTurn.all(phrases: ["qa engineer"], places: places, countries: [.canada, .unitedStates])
        #expect(turns.map(\.key) == ["qa engineer|toronto|ontario|ca|CA", "qa engineer|remote|CA", "qa engineer|remote|US"])
    }

    @Test func theLeastRecentlySearchedComeFirst() {
        let turns = SearchTurn.all(
            phrases: ["a", "b"], places: [], countries: [.canada])
        let last = [turns[0].key: Date(timeIntervalSince1970: 100)]
        #expect(SearchTurn.due(turns, lastSearched: last, count: 1) == [turns[1]])
        #expect(SearchTurn.due(turns, lastSearched: [:], count: 5) == turns)
        #expect(SearchTurn.due(turns, lastSearched: [:], count: 0).isEmpty)
    }

    @Test func budgetsKeepToEveryLimit() {
        #expect(SearchBudget.adzuna.remaining(today: 0, week: 0, month: 0) == 80)
        #expect(SearchBudget.adzuna.remaining(today: 190, week: 0, month: 0) == 10)
        #expect(SearchBudget.adzuna.remaining(today: 0, week: 950, month: 0) == 0)
        #expect(SearchBudget.serpAPI.remaining(today: 3, week: 10, month: 100) == 5)
    }
}
