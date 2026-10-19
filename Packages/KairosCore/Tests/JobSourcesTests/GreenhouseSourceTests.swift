import Foundation
import Testing

@testable import JobSources

private let boardURL = "https://boards-api.greenhouse.io/v1/boards/acmerobotics/jobs?content=true"
private let sourceID = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000aa")!

private func date(_ iso: String) throws -> Date { try Date.ISO8601FormatStyle().parse(iso) }

@Suite("Greenhouse source")
struct GreenhouseSourceTests {
    @Test func mapsARecordedBoardResponse() async throws {
        let body = try ScriptedURLProtocol.fixture("greenhouse_jobs.json")
        let (http, script) = ScriptedURLProtocol.client([boardURL: .http(status: 200, body: body)])
        let source = GreenhouseSource(id: sourceID, boardToken: "acmerobotics", http: http)

        let postings = try await source.fetch(SourceQuery())

        #expect(postings.count == 3)
        let first = postings[0]
        #expect(first.sourceID == sourceID)
        #expect(first.url.absoluteString == "https://job-boards.greenhouse.io/acmerobotics/jobs/4012001002")
        #expect(first.company == "Acme Robotics")
        #expect(first.title == "Backend Engineer, Platform")
        #expect(first.location == "Toronto, ON")
        #expect(first.postedAt == (try date("2026-10-02T11:31:50-04:00")))  // first_published, not updated_at
        #expect(
            first.descriptionHTML.hasPrefix(
                #"<div class="content-intro"><p>We&#39;re building warehouse robots &amp; the"#))
        #expect(first.descriptionHTML.contains("<h3>What you&rsquo;ll do</h3>"))

        #expect(postings[1].location == "Remote - Canada")
        #expect(postings[1].postedAt == (try date("2026-10-17T13:05:12.250Z")))
        #expect(postings[1].descriptionHTML == "<p>Poste bilingue &mdash; fran&ccedil;ais requis.</p>")

        let third = postings[2]
        #expect(third.company == "acmerobotics")  // no company_name: falls back to the token
        #expect(third.postedAt == (try date("2026-09-30T08:15:00-05:00")))  // no first_published
        #expect(third.descriptionHTML == "")

        let request = try #require(script.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Kairos-tests")
    }

    @Test func theNameYouGaveTheCompanyWins() async throws {
        let body = try ScriptedURLProtocol.fixture("greenhouse_jobs.json")
        let (http, _) = ScriptedURLProtocol.client([boardURL: .http(status: 200, body: body)])
        let source = GreenhouseSource(id: sourceID, boardToken: "acmerobotics", http: http)
        let postings = try await source.fetch(SourceQuery(companyName: "Acme"))
        #expect(postings.allSatisfy { $0.company == "Acme" })
    }

    @Test(arguments: [
        "", "acme/../admin", "acme?x=1", "..", "acme robotics", "acmé", String(repeating: "a", count: 101),
    ])
    func rejectsABoardTokenThatCouldLeaveItsPath(_ token: String) async {
        let (http, script) = ScriptedURLProtocol.client([:])
        let source = GreenhouseSource(id: sourceID, boardToken: token, http: http)
        await #expect(throws: SourceError.invalidConfiguration("Greenhouse board token: \(token)")) {
            try await source.fetch(SourceQuery())
        }
        #expect(script.requests.isEmpty)
    }

    @Test func aMissingBoardIsNotFound() async {
        let missing = "https://boards-api.greenhouse.io/v1/boards/gone/jobs?content=true"
        let (http, _) = ScriptedURLProtocol.client([missing: .http(status: 404)])
        let source = GreenhouseSource(id: sourceID, boardToken: "gone", http: http)
        await #expect(throws: SourceError.notFound(endpoint: "boards-api.greenhouse.io/v1/boards/gone/jobs")) {
            try await source.fetch(SourceQuery())
        }
    }

    @Test func aTimeoutIsReportedAsATimeout() async {
        let (http, _) = ScriptedURLProtocol.client([boardURL: .failure(.timedOut)])
        let source = GreenhouseSource(id: sourceID, boardToken: "acmerobotics", http: http)
        await #expect(throws: SourceError.timedOut(endpoint: "boards-api.greenhouse.io/v1/boards/acmerobotics/jobs")) {
            try await source.fetch(SourceQuery())
        }
    }

    @Test func aChangedResponseShapeIsADecodingError() async {
        let body = Data(#"{"jobs":[{"title":"No URL"}]}"#.utf8)
        let (http, _) = ScriptedURLProtocol.client([boardURL: .http(status: 200, body: body)])
        let source = GreenhouseSource(id: sourceID, boardToken: "acmerobotics", http: http)
        await #expect(throws: SourceError.decoding("jobs[0].absoluteUrl: missing")) {
            try await source.fetch(SourceQuery())
        }
    }
}

@Suite("HTTP client")
struct HTTPClientTests {
    struct Probe: Decodable, Equatable { let seenAt: Date }

    @Test func anUnscriptedRequestFailsInsteadOfReachingTheNetwork() async throws {
        let (http, script) = ScriptedURLProtocol.client([:])
        let url = try #require(URL(string: "https://example.com/anything"))
        await #expect(throws: SourceError.self) { try await http.getJSON(url, as: Probe.self) }
        #expect(script.requests.map(\.url) == [url])
    }

    @Test(arguments: [
        (ScriptedURLProtocol.Reply.http(status: 410), SourceError.notFound(endpoint: "api.example.com/v1/x")),
        (.http(status: 429, headers: ["Retry-After": "30"]), .rateLimited(retryAfterSeconds: 30)),
        (.http(status: 429), .rateLimited(retryAfterSeconds: nil)),
        (.http(status: 503), .http(status: 503, endpoint: "api.example.com/v1/x")),
        (.http(status: 200, body: Data("<html>".utf8)), .decoding("The given data was not valid JSON.")),
        (.failure(.notConnectedToInternet), .offline),
        (.failure(.cancelled), .cancelled),
        (.failure(.cannotFindHost), .network("api.example.com/v1/x: URL error -1003")),
    ])
    func mapsEachFailure(reply: ScriptedURLProtocol.Reply, expected: SourceError) async throws {
        // The query string stands in for an API key; it must not appear in any error.
        let url = "https://api.example.com/v1/x?app_key=secret"
        let (http, _) = ScriptedURLProtocol.client([url: reply])
        await #expect(throws: expected) { try await http.getJSON(URL(string: url)!, as: Probe.self) }
    }

    @Test func decodesSnakeCaseKeysAndISODates() async throws {
        let url = "https://api.example.com/probe"
        let body = Data(#"{"seen_at":"2026-10-19T08:00:00-04:00"}"#.utf8)
        let (http, _) = ScriptedURLProtocol.client([url: .http(status: 200, body: body)])
        let probe = try await http.getJSON(URL(string: url)!, as: Probe.self)
        #expect(probe == Probe(seenAt: try date("2026-10-19T12:00:00Z")))
    }

    @Test func aDateThatIsntISOIsADecodingError() async throws {
        let url = "https://api.example.com/probe"
        let body = Data(#"{"seen_at":"yesterday"}"#.utf8)
        let (http, _) = ScriptedURLProtocol.client([url: .http(status: 200, body: body)])
        await #expect(throws: SourceError.decoding("seenAt: not an ISO 8601 date: yesterday")) {
            try await http.getJSON(URL(string: url)!, as: Probe.self)
        }
    }
}

@Suite("HTML entities")
struct HTMLEntitiesTests {
    @Test(arguments: [
        ("plain text", "plain text"),
        ("&lt;p&gt;Tom &amp;amp; Jerry&lt;/p&gt;", "<p>Tom &amp; Jerry</p>"),  // one level only
        ("caf&eacute; &#233; &#xE9; &#XE9;", "café é é é"),
        ("5 &lt; 6 &amp;&amp; 7 &gt; 3", "5 < 6 && 7 > 3"),
        ("AT&T and R&D", "AT&T and R&D"),
        ("&bogus; &#xZZ; &#0; &#;", "&bogus; &#xZZ; &#0; &#;"),
        ("&amp", "&amp"),
        ("trailing &", "trailing &"),
        ("&quot;quoted&quot; &apos;single&apos; a&nbsp;b", "\"quoted\" 'single' a\u{00A0}b"),
        ("emoji &#128640;", "emoji 🚀"),
    ])
    func decodesOneLevelOfReferences(input: String, expected: String) {
        #expect(HTMLEntities.decode(input) == expected)
    }
}
