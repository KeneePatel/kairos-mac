import Foundation
import Store
import Testing

@testable import JobSources

struct GeoCase: Sendable, CustomTestStringConvertible {
    let text: String
    var others: [String] = []
    var hint: String? = nil
    var workplace: Workplace? = nil
    let expected: GeoResult

    var testDescription: String {
        ([text] + others).joined(separator: " + ") + (hint.map { " [hint \($0)]" } ?? "")
            + (workplace.map { " [\($0)]" } ?? "")
    }
}

private func ca(_ region: String?, _ city: String?, _ scope: RemoteScope) -> GeoResult {
    GeoResult(country: .canada, region: region, city: city, remoteScope: scope)
}

private func us(_ region: String?, _ city: String?, _ scope: RemoteScope) -> GeoResult {
    GeoResult(country: .unitedStates, region: region, city: city, remoteScope: scope)
}

private func outside(_ scope: RemoteScope = .unknown) -> GeoResult {
    GeoResult(remoteScope: scope, outsideCanadaAndUS: true)
}

private func nowhere(_ scope: RemoteScope) -> GeoResult { GeoResult(remoteScope: scope) }

@Suite("Geography")
struct GeoTests {
    static let cases: [GeoCase] = [
        // Canadian cities, provinces and their spellings
        GeoCase(text: "Toronto, ON", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Toronto, Ontario, Canada", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Toronto ON", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Toronto, Canada", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Toronto, ON, CA", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "Vancouver, BC", expected: ca("BC", "Vancouver", .onsite)),
        GeoCase(text: "Vancouver, B.C.", expected: ca("BC", "Vancouver", .onsite)),
        GeoCase(text: "Vancouver, CA", expected: ca("BC", "Vancouver", .onsite)),
        GeoCase(text: "Montréal, QC", expected: ca("QC", "Montréal", .onsite)),
        GeoCase(text: "Montreal, Quebec, Canada", expected: ca("QC", "Montréal", .onsite)),
        GeoCase(text: "Calgary, AB", expected: ca("AB", "Calgary", .onsite)),
        GeoCase(text: "Ottawa", expected: ca("ON", "Ottawa", .onsite)),
        GeoCase(text: "Kitchener, ON", expected: ca("ON", "Kitchener", .onsite)),
        GeoCase(text: "Oshawa, ON", expected: ca("ON", "Oshawa", .onsite)),  // not in the table, named by its province
        GeoCase(text: "Halifax, Nova Scotia", expected: ca("NS", "Halifax", .onsite)),
        GeoCase(text: "Charlottetown, PEI", expected: ca("PE", "Charlottetown", .onsite)),
        GeoCase(text: "London, ON", expected: ca("ON", "London", .onsite)),
        GeoCase(text: "Victoria, BC", expected: ca("BC", "Victoria", .onsite)),
        GeoCase(text: "Ottawa, ON / Montréal, QC", expected: ca("ON", "Ottawa", .onsite)),
        // Work arrangement words
        GeoCase(text: "Toronto, ON (Hybrid)", expected: ca("ON", "Toronto", .hybrid)),
        GeoCase(text: "Hybrid - Vancouver, BC", expected: ca("BC", "Vancouver", .hybrid)),
        GeoCase(text: "Mississauga, Ontario (Hybrid)", expected: ca("ON", "Mississauga", .hybrid)),
        GeoCase(text: "Toronto (On-site)", expected: ca("ON", "Toronto", .onsite)),
        GeoCase(text: "In-office - Calgary", expected: ca("AB", "Calgary", .onsite)),
        GeoCase(text: "Remote - Toronto", expected: ca("ON", "Toronto", .remoteCountry)),
        // Remote, Canada
        GeoCase(text: "Remote - Canada", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote \u{2013} Canada", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote (Canada)", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Canada (Remote)", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote in Canada", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote, Canada residents only", expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Canada", expected: ca(nil, nil, .unknown)),
        // United States
        GeoCase(text: "New York, NY", expected: us("NY", "New York", .onsite)),
        GeoCase(text: "NYC", expected: us("NY", "NYC", .onsite)),
        GeoCase(text: "Brooklyn, New York", expected: us("NY", "Brooklyn", .onsite)),
        GeoCase(text: "San Francisco, CA", expected: us("CA", "San Francisco", .onsite)),
        GeoCase(text: "San Francisco Bay Area", expected: us("CA", "San Francisco Bay Area", .onsite)),
        GeoCase(text: "Seattle, Washington", expected: us("WA", "Seattle", .onsite)),
        GeoCase(text: "Austin, Texas", expected: us("TX", "Austin", .onsite)),
        GeoCase(text: "Atlanta, GA", expected: us("GA", "Atlanta", .onsite)),
        GeoCase(text: "Washington, D.C.", expected: us("DC", nil, .onsite)),  // the code beats the state name
        GeoCase(text: "Portland, ME", expected: us("ME", "Portland", .onsite)),  // the named state beats the default
        GeoCase(text: "Indiana", expected: us("IN", nil, .onsite)),
        // Remote, United States ("CA" alone is California)
        GeoCase(text: "Remote (US only)", expected: us(nil, nil, .remoteCountry)),
        GeoCase(text: "US Remote", expected: us(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote, USA", expected: us(nil, nil, .remoteCountry)),
        GeoCase(text: "Remote, CA", expected: us("CA", nil, .remoteCountry)),
        GeoCase(text: "Bay Area or Remote (US)", expected: us("CA", "Bay Area", .remoteCountry)),
        GeoCase(text: "United States", expected: us(nil, nil, .unknown)),
        // Across countries
        GeoCase(text: "Remote - North America", expected: ca(nil, nil, .remoteAnywhere)),
        GeoCase(text: "Remote (US or Canada)", expected: ca(nil, nil, .remoteAnywhere)),
        GeoCase(text: "Remote US & Canada", expected: ca(nil, nil, .remoteAnywhere)),
        GeoCase(text: "Remote - Anywhere", expected: nowhere(.remoteAnywhere)),
        GeoCase(text: "Worldwide", expected: nowhere(.remoteAnywhere)),
        GeoCase(text: "Remote", expected: nowhere(.remote)),
        GeoCase(text: "Remote (EST)", expected: nowhere(.remote)),
        GeoCase(text: "", expected: nowhere(.unknown)),
        GeoCase(text: "Multiple Locations", expected: nowhere(.unknown)),
        // Outside Canada and the US
        GeoCase(text: "London", expected: outside()),
        GeoCase(text: "London, United Kingdom", expected: outside()),
        GeoCase(text: "Victoria, Australia", expected: outside()),  // the country beats a Canadian city name
        GeoCase(text: "San Jose, Costa Rica", expected: outside()),
        GeoCase(text: "Berlin, Germany", expected: outside()),
        GeoCase(text: "Bengaluru, India", expected: outside()),
        GeoCase(text: "EMEA", expected: outside()),
        // Board hints and further locations
        GeoCase(text: "Remote", hint: "CA", expected: ca(nil, nil, .remoteCountry)),  // a country field: Canada
        GeoCase(text: "Toronto", workplace: .remote, expected: ca("ON", "Toronto", .remoteCountry)),
        GeoCase(text: "Mexico City", hint: "MX", expected: outside()),
        GeoCase(text: "Remote", hint: "GB", expected: outside(.remote)),
        GeoCase(text: "North America", workplace: .remote, expected: ca(nil, nil, .remoteAnywhere)),
        GeoCase(text: "New York, NY", others: ["Toronto, ON"], expected: ca("ON", "Toronto", .onsite)),
        GeoCase(
            text: "Toronto, ON", others: ["Remote (Canada)", "Remote (US)"], hint: "Canada", workplace: .hybrid,
            expected: ca("ON", "Toronto", .hybrid)),
        GeoCase(text: "London, UK", others: ["Remote (Canada)"], expected: ca(nil, nil, .remoteCountry)),
        GeoCase(text: "Paris, France", others: ["Berlin, Germany"], expected: outside()),
    ]

    @Test(arguments: cases)
    func parses(_ geoCase: GeoCase) {
        let result = Geo.parse(
            location: geoCase.text, otherLocations: geoCase.others, countryHint: geoCase.hint,
            workplace: geoCase.workplace)
        #expect(result == geoCase.expected)
    }

    @Test func theTableCoversAtLeastSixtyStrings() {
        #expect(Self.cases.count >= 60)
    }

    @Test func thePlaceTableLoads() {
        #expect(Places.shared.cities.count > 100 && Places.shared.regionCodes.count > 60)
        #expect(Places.shared.regionCodes["CA"] == nil)  // decided by context, never by lookup
    }
}

@Suite("URL canonicalization")
struct URLCanonicalizerTests {
    @Test(arguments: [
        (
            "https://job-boards.greenhouse.io/acme/jobs/123?gh_src=abc&utm_source=linkedin&utm_medium=social",
            "https://job-boards.greenhouse.io/acme/jobs/123"
        ),
        ("http://Boards.Greenhouse.io/acme/jobs/123/", "https://job-boards.greenhouse.io/acme/jobs/123"),
        ("https://jobs.lever.co/acme/2233?lever-source=LinkedIn#apply", "https://jobs.lever.co/acme/2233"),
        ("https://acme.com:443/careers?gh_jid=42&ref=hn", "https://acme.com/careers?gh_jid=42"),  // gh_jid is the job
        ("https://acme.com/jobs?b=2&a=1&UTM_Campaign=x", "https://acme.com/jobs?a=1&b=2"),
        ("https://acme.com/", "https://acme.com/"),
    ])
    func dropsTrackingAndNormalizesTheRest(input: String, expected: String) throws {
        #expect(URLCanonicalizer.canonical(try #require(URL(string: input))) == expected)
    }

    @Test func trackingDoesntChangeTheJobID() throws {
        let plain = try #require(URL(string: "https://jobs.lever.co/acme/2233"))
        let tracked = try #require(URL(string: "https://jobs.lever.co/acme/2233/?utm_source=x&trk=y"))
        #expect(
            JobID(canonicalURL: URLCanonicalizer.canonical(plain))
                == JobID(canonicalURL: URLCanonicalizer.canonical(tracked)))
    }
}

@Suite("HTML to Markdown")
struct HTMLToMarkdownTests {
    @Test func convertsAGreenhouseStylePosting() {
        let html = """
            <div class="content-intro"><p>We&#39;re building <strong>warehouse robots</strong> &amp; their software.</p></div>
            <h3>What you&rsquo;ll do</h3>
            <ul><li><p>Design services in <em>Go</em></p></li><li>Own on-call<ul><li>Nested item</li></ul></li></ul>
            <ol><li>First</li><li>Second</li></ol>
            <p>Apply <a href="https://acme.example/apply?x=1">here</a>, or <a href="javascript:alert(1)">not here</a>.</p>
            <script>alert("x")</script><style>p { color: red }</style>
            <p>Line one<br>Line two</p>
            """
        let expected = """
            We're building **warehouse robots** & their software.

            ### What you\u{2019}ll do

            - Design services in *Go*
            - Own on-call
              - Nested item

            1. First
            2. Second

            Apply [here](https://acme.example/apply?x=1), or not here.

            Line one
            Line two
            """
        #expect(HTMLToMarkdown.convert(html) == expected)
    }

    @Test(arguments: [
        ("", ""),
        ("plain words", "plain words"),
        ("<p>  lots   of\n\n spaces </p>", "lots of spaces"),
        ("<b></b>empty bold", "empty bold"),
        ("<a href=\"https://x.example\"></a>empty link", "empty link"),
        ("5 < 6 and <unclosed", "5 < 6 and"),
        ("<!-- a comment --><p>after</p>", "after"),
        ("<p>a</p><p></p><p></p><p>b</p>", "a\n\nb"),
        ("<h1>Title</h1><h5>Small</h5>", "# Title\n\n### Small"),
        ("<p>Spot&nbsp;on</p>", "Spot on"),
        ("<a href='https://x.example/a b'>spaced</a>", "spaced"),  // a URL that would break the link syntax
        ("<table><tr><td>Salary</td><td>$100k</td></tr></table>", "Salary $100k"),
    ])
    func handlesEdgeCases(html: String, expected: String) {
        #expect(HTMLToMarkdown.convert(html) == expected)
    }
}

private let greenhouse = UUID(uuidString: "0199f0a0-0000-7000-8000-000000000001")!
private let linkedIn = UUID(uuidString: "0199f0a0-0000-7000-8000-000000000002")!
private let seen = Date(timeIntervalSince1970: 1_760_000_000)

private func posting(
    _ title: String, company: String = "Acme Robotics", location: String = "Toronto, ON", source: UUID = greenhouse,
    path: String? = nil
) -> Posting {
    let slug = path ?? title.lowercased().replacing(" ", with: "-")
    return Posting(
        sourceID: source, url: URL(string: "https://jobs.example/\(slug)?utm_source=x")!, company: company,
        title: title,
        location: location, postedAt: seen, descriptionHTML: "<p>Do <b>things</b>.</p>")
}

private func job(_ posting: Posting) throws -> Job {
    guard case .job(let job) = Normalizer.normalize(posting, firstSeenAt: seen) else {
        throw CancellationError()
    }
    return job
}

@Suite("Normalizer")
struct NormalizerTests {
    @Test func turnsAPostingIntoAJob() throws {
        var source = posting("  Senior   Backend Engineer ", location: "Toronto, ON")
        source.otherLocations = ["Remote (Canada)", "Toronto, ON"]
        source.workplace = .hybrid
        let job = try job(source)
        #expect(job.canonicalURL == "https://jobs.example/--senior---backend-engineer-")
        #expect(job.id == JobID(canonicalURL: job.canonicalURL))
        #expect(job.url == "https://jobs.example/--senior---backend-engineer-?utm_source=x")
        #expect(job.title == "Senior Backend Engineer")
        #expect(job.location == "Toronto, ON; Remote (Canada)")  // listed once each
        #expect(job.country == .canada && job.region == "ON" && job.city == "Toronto")
        #expect(job.remoteScope == .hybrid)
        #expect(job.descriptionMarkdown == "Do **things**.")
        #expect(job.dedupKey == "acme robotics|senior backend engineer|toronto")
        #expect(job.state == .new && job.verdict == nil && job.firstSeenAt == seen && job.postedAt == seen)
    }

    @Test func dropsAPostingOutsideCanadaAndTheUS() {
        #expect(
            Normalizer.normalize(posting("Engineer", location: "Berlin, Germany"), firstSeenAt: seen)
                == .outsideCanadaAndUS)
    }

    @Test func anEmptyDescriptionIsNil() throws {
        var source = posting("Engineer")
        source.descriptionHTML = "<div> </div>"
        #expect(try job(source).descriptionMarkdown == nil)
    }

    @Test func dedupKeysFoldSpellingDifferences() {
        #expect(
            DedupKey.make(company: "Acme Robotics, Inc.", title: "Sr. Backend Eng", city: "Montréal")
                == DedupKey.make(company: "acme robotics", title: "Senior Backend Engineer", city: "Montreal"))
    }
}

@Suite("De-duplication")
struct DeduplicatorTests {
    @Test func dropsKnownIDsAndRepeatsWithinTheBatch() throws {
        let a = try job(posting("Backend Engineer"))
        let b = try job(posting("Frontend Engineer"))
        let kept = Deduplicator.newJobs([a, b, a], knownIDs: [b.id], existing: [])
        #expect(kept.map(\.id) == [a.id])
    }

    @Test func dropsTheSameJobPostedOnAnotherBoard() throws {
        let board = try job(posting("Senior Backend Engineer"))
        let copy = try job(
            posting("Sr. Backend Engineer", company: "Acme Robotics Inc.", source: linkedIn, path: "li-1"))
        #expect(Deduplicator.newJobs([board, copy], knownIDs: [], existing: []).map(\.id) == [board.id])
        // Also against what's already stored.
        let stored = Deduplicator.Known(sourceID: greenhouse, dedupKey: board.dedupKey)
        #expect(Deduplicator.newJobs([copy], knownIDs: [], existing: [stored]).isEmpty)
    }

    @Test func keepsSimilarJobsFromTheSameBoard() throws {
        let payments = try job(posting("Software Engineer, Payments"))
        let payouts = try job(posting("Software Engineer, Payouts"))
        #expect(Deduplicator.similarity(payments.dedupKey, payouts.dedupKey) >= Deduplicator.threshold)
        #expect(Deduplicator.newJobs([payments, payouts], knownIDs: [], existing: []).count == 2)
    }

    @Test func keepsTheSameTitleInAnotherCityOrCompany() throws {
        let toronto = try job(posting("Backend Engineer"))
        let vancouver = try job(posting("Backend Engineer", location: "Vancouver, BC", source: linkedIn, path: "v"))
        let rival = try job(posting("Backend Engineer", company: "Globex", source: linkedIn, path: "g"))
        #expect(Deduplicator.newJobs([toronto, vancouver, rival], knownIDs: [], existing: []).count == 3)
    }

    @Test(arguments: [("abc", "abc", 1.0), ("", "", 1.0), ("abc", "", 0.0), ("kitten", "sitting", 1 - 3.0 / 7)])
    func similarityIsOneMinusTheNormalizedEditDistance(a: String, b: String, expected: Double) {
        #expect(abs(Deduplicator.similarity(a, b) - expected) < 1e-9)
    }
}
