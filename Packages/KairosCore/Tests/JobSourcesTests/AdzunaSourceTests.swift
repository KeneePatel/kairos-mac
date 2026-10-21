import Foundation
import Store
import TestSupport
import Testing

@testable import JobSources

private let sourceID = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000ad")!
private let credentials = AdzunaSource.Credentials(appID: "test-id", appKey: "test-key")

/// The request Kairos sends for one title in one country: newest first, 50 a page, title words only.
private func searchURL(_ country: String, _ title: String, maxDays: Int? = 30) -> String {
    let what = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
    return "https://api.adzuna.com/v1/api/jobs/\(country)/search/1?app_id=test-id&app_key=test-key"
        + "&results_per_page=50&title_only=\(what)&sort_by=date" + (maxDays.map { "&max_days_old=\($0)" } ?? "")
        + "&content-type=application/json"
}

private func date(_ iso: String) throws -> Date { try Date.ISO8601FormatStyle().parse(iso) }

@Suite("Adzuna source")
struct AdzunaSourceTests {
    /// Canada first, then the US, one search per title; a snippet becomes the description.
    @Test func searchesCanadaFirstAndMapsTheResults() async throws {
        let canada = try ScriptedURLProtocol.fixture("adzuna_search_ca.json")
        let us = try ScriptedURLProtocol.fixture("adzuna_search_us.json")
        let (http, script) = ScriptedURLProtocol.client([
            searchURL("ca", "software developer"): .http(status: 200, body: canada),
            searchURL("us", "software developer"): .http(status: 200, body: us),
        ])
        let source = AdzunaSource(id: sourceID, credentials: credentials, http: http)
        let query = SourceQuery(titles: ["software developer"], countries: [.canada, .unitedStates], maxAgeDays: 30)

        let postings = try await source.fetch(query)

        #expect(
            script.requests.map { $0.url?.absoluteString } == [
                searchURL("ca", "software developer"), searchURL("us", "software developer"),
            ])
        #expect(postings.map(\.company) == ["Northline Freight", "Maplepay", "Company not listed", "Rivet Studio"])
        let first = postings[0]
        #expect(first.sourceID == sourceID)
        #expect(first.title == "Software Developer, Backend")  // Adzuna's highlighting removed
        #expect(first.url.absoluteString.hasPrefix("https://www.adzuna.ca/land/ad/4790012001?"))
        #expect(first.location == "Toronto, Ontario" && first.countryHint == "CA")
        #expect(first.postedAt == (try date("2026-10-18T14:02:11Z")))
        #expect(
            first.descriptionHTML
                == "<p>Northline Freight is hiring a backend developer to build Go &amp; Kafka services for its dispatch platform. You will work with PostgreSQL and Kubernetes…</p>"
        )
        #expect(postings[1].workplace == .remote)  // "(Remote)" in the title
        #expect(postings[3].countryHint == "US" && postings[3].location == "New York City, New York")
    }

    /// The same advert found by two titles is one posting.
    @Test func anAdvertFoundTwiceIsKeptOnce() async throws {
        let canada = try ScriptedURLProtocol.fixture("adzuna_search_ca.json")
        let (http, script) = ScriptedURLProtocol.client([
            searchURL("ca", "software developer", maxDays: nil): .http(status: 200, body: canada),
            searchURL("ca", "backend developer", maxDays: nil): .http(status: 200, body: canada),
        ])
        let postings = try await AdzunaSource(id: sourceID, credentials: credentials, http: http).fetch(
            SourceQuery(titles: ["software developer", "backend developer"], countries: [.canada]))
        #expect(script.requests.count == 2 && postings.count == 3)
    }

    /// At most `maxCallsPerRun` searches a run, Canada's first, so a long title list can't use up
    /// the daily allowance.
    @Test func aRunMakesAtMostTheCallCap() async throws {
        let empty = Data(#"{"results":[]}"#.utf8)
        let titles = (1...15).map { "title \($0)" }
        var replies: [String: ScriptedURLProtocol.Reply] = [:]
        for title in titles {
            replies[searchURL("ca", title, maxDays: nil)] = .http(status: 200, body: empty)
            replies[searchURL("us", title, maxDays: nil)] = .http(status: 200, body: empty)
        }
        let (http, script) = ScriptedURLProtocol.client(replies)
        _ = try await AdzunaSource(id: sourceID, credentials: credentials, http: http).fetch(
            SourceQuery(titles: titles, countries: [.canada, .unitedStates]))
        #expect(script.requests.count == AdzunaSource.maxCallsPerRun)
        #expect(script.requests.prefix(15).allSatisfy { $0.url?.path().contains("/jobs/ca/") == true })
    }

    /// Adzuna searches by your job titles: with none there's nothing to ask for.
    @Test func withoutTitlesItAsksForSome() async throws {
        let (http, script) = ScriptedURLProtocol.client([:])
        let source = AdzunaSource(id: sourceID, credentials: credentials, http: http)
        await #expect(throws: SourceError.self) { _ = try await source.fetch(SourceQuery(countries: [.canada])) }
        #expect(script.requests.isEmpty)
    }

    /// A wrong app ID or key reads as a settings problem, and the key never shows in the message.
    @Test func aRejectedKeyIsASettingsProblem() async throws {
        let (http, _) = ScriptedURLProtocol.client([
            searchURL("ca", "software developer", maxDays: nil): .http(status: 401, body: Data("{}".utf8))
        ])
        let source = AdzunaSource(id: sourceID, credentials: credentials, http: http)
        let error = await #expect(throws: SourceError.self) {
            _ = try await source.fetch(SourceQuery(titles: ["software developer"], countries: [.canada]))
        }
        guard case .invalidConfiguration(let detail)? = error else {
            Issue.record("expected a settings error, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("app ID or key") && !detail.contains("test-key"))
        #expect(error?.message.contains("test-key") == false)
    }

    /// Adzuna's link carries tracking that changes between calls; the job's identity doesn't.
    @Test func anAdvertKeepsOneIdentityAcrossRuns() {
        let first = URL(string: "https://www.adzuna.ca/land/ad/4790012001?se=Ab12&utm_medium=api&utm_source=x&v=9F")!
        let later = URL(string: "https://www.adzuna.ca/land/ad/4790012001?se=Zz99&utm_medium=api&utm_source=x&v=1A")!
        #expect(URLCanonicalizer.canonical(first) == "https://www.adzuna.ca/land/ad/4790012001")
        #expect(URLCanonicalizer.canonical(first) == URLCanonicalizer.canonical(later))
        // Other sites keep their query.
        let other = URL(string: "https://jobs.example.com/view?id=7")!
        #expect(URLCanonicalizer.canonical(other) == "https://jobs.example.com/view?id=7")
    }
}

@Suite("Source factory")
struct SourceFactoryTests {
    /// Adzuna gets your search settings and needs its key; a board needs only its slug.
    @Test func adzunaTakesYourSearchAndNeedsItsKey() throws {
        let (http, _) = ScriptedURLProtocol.client([:])
        let adzuna = Source(id: UUID(), kind: .adzuna, config: "{}")
        let search = SearchContext(
            query: SourceQuery(titles: ["software developer"], countries: [.canada], maxAgeDays: 14))
        #expect(throws: SourceError.self) { try SourceFactory.make(adzuna, http: http, search: search) }
        var withKey = search
        withKey.adzuna = credentials
        let (made, query) = try SourceFactory.make(adzuna, http: http, search: withKey)
        #expect(made is AdzunaSource && query == search.query)
        let board = Source(
            id: UUID(), kind: .greenhouse, config: BoardConfig(slug: "northline", company: "Northline").json)
        let (_, boardQuery) = try SourceFactory.make(board, http: http, search: withKey)
        #expect(boardQuery.companyName == "Northline" && boardQuery.titles.isEmpty)
        #expect(SourceKind.adzuna.isSearch && !SourceKind.greenhouse.isSearch && SourceKind.linkedIn.isSearch)
    }
}
