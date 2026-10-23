import Foundation
import Store
import TestSupport
import Testing

@testable import JobSources

private let sourceID = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000ae")!
private let credentials = AdzunaSource.Credentials(appID: "test-id", appKey: "test-key")
private let now = Date(timeIntervalSince1970: 1_792_756_800)

private func url(_ title: String, page: Int, days: Int? = 7) -> String {
    let what = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
    return "https://api.adzuna.com/v1/api/jobs/ca/search/\(page)?app_id=test-id&app_key=test-key"
        + "&results_per_page=50&title_only=\(what)&sort_by=date" + (days.map { "&max_days_old=\($0)" } ?? "")
        + "&content-type=application/json"
}

/// A page of `count` adverts numbered from `first`, in Adzuna's shape (fictional companies).
private func page(_ first: Int, _ count: Int, area: [String] = ["Canada", "Ontario", "Toronto"]) -> Data {
    let results = (first..<first + count).map { n in
        let place = area.map { "\"\($0)\"" }.joined(separator: ",")
        return
            #"{"id":"\#(n)","title":"Software Developer \#(n)","description":"Build things.","created":"2026-10-22T10:00:00Z","redirect_url":"https://www.adzuna.ca/land/ad/\#(n)?se=x","company":{"display_name":"Acme"},"location":{"display_name":"Regent Park, City of Toronto","area":[\#(place)]}}"#
    }
    return Data(#"{"count":\#(count),"results":[\#(results.joined(separator: ","))]}"#.utf8)
}

private func known(_ range: Range<Int>) -> Set<String> {
    Set(range.map { "https://www.adzuna.ca/land/ad/\($0)" })
}

/// Job collection v2, J4: Adzuna fetched in full, within its free plan.
@Suite("Adzuna paging")
struct AdzunaPagingTests {
    /// Newest first, page after page, until the results end; the memo counts the requests.
    @Test func itPagesUntilTheResultsEnd() async throws {
        let (http, script) = ScriptedURLProtocol.client([
            url("software developer", page: 1): .http(status: 200, body: page(1, 50)),
            url("software developer", page: 2): .http(status: 200, body: page(51, 12)),
        ])
        let source = AdzunaSource(id: sourceID, credentials: credentials, http: http, now: { now })
        let answer = try await source.fetch(
            SourceQuery(titles: ["software developer"], countries: [.canada], maxAgeDays: 7), since: nil)
        guard case .postings(let postings, let memo) = answer else {
            Issue.record("expected postings")
            return
        }
        #expect(postings.count == 62 && memo?.requests == 2 && script.requests.count == 2)
        // City and province from its place list, not the landmark it's shown at.
        #expect(postings.first?.location == "Toronto, Ontario")
    }

    /// A full page of jobs Kairos already has means the rest are older and known too.
    @Test func aPageOfKnownJobsEndsTheSearch() async throws {
        let (http, script) = ScriptedURLProtocol.client([
            url("software developer", page: 1): .http(status: 200, body: page(1, 50))
        ])
        let source = AdzunaSource(id: sourceID, credentials: credentials, http: http, now: { now })
        let query = SourceQuery(
            titles: ["software developer"], countries: [.canada], maxAgeDays: 7, knownURLs: known(1..<51))
        _ = try await source.fetch(query, since: nil)
        #expect(script.requests.count == 1)
    }

    /// The run's budget caps every page of every search; only days since the last good fetch are
    /// asked, within your limit.
    @Test func theBudgetAndTheDaysSinceTheLastFetch() async throws {
        let since = now.addingTimeInterval(-1.2 * 86_400)
        let (http, script) = ScriptedURLProtocol.client([
            url("software developer", page: 1, days: 3): .http(status: 200, body: page(1, 50)),
            url("software developer", page: 2, days: 3): .http(status: 200, body: page(51, 50)),
            url("software developer", page: 3, days: 3): .http(status: 200, body: page(101, 50)),
        ])
        let source = AdzunaSource(id: sourceID, credentials: credentials, http: http, now: { now })
        let query = SourceQuery(
            titles: ["software developer", "data engineer"], countries: [.canada], maxAgeDays: 7, since: since,
            callBudget: 3)
        guard case .postings(_, let memo) = try await source.fetch(query, since: nil) else {
            Issue.record("expected postings")
            return
        }
        #expect(memo?.requests == 3 && script.requests.count == 3)
        #expect(source.days(since: since, limit: 7) == 3 && source.days(since: nil, limit: 7) == 7)
        #expect(source.days(since: now.addingTimeInterval(-30 * 86_400), limit: 7) == 7)
        #expect(source.days(since: now.addingTimeInterval(-60), limit: nil) == 2)
    }

    /// Jobs at other roles are never stored, so they don't count as new: a page of them ends the
    /// search like a page of known jobs.
    @Test func aPageOfOtherRolesEndsTheSearchToo() async throws {
        let (http, script) = ScriptedURLProtocol.client([
            url("software developer", page: 1): .http(status: 200, body: page(1, 50))
        ])
        let source = AdzunaSource(id: sourceID, credentials: credentials, http: http, now: { now })
        let query = SourceQuery(
            titles: ["software developer"], countries: [.canada], maxAgeDays: 7,
            roles: RoleMatcher(families: [.qa]))
        _ = try await source.fetch(query, since: nil)
        #expect(script.requests.count == 1)
    }

    /// A request failing after the first keeps the pages before it; the failed one still counts.
    /// A first request that fails is the fetch's failure.
    @Test func aLaterFailureKeepsWhatCameBefore() async throws {
        let (http, _) = ScriptedURLProtocol.client([
            url("software developer", page: 1): .http(status: 200, body: page(1, 50)),
            url("software developer", page: 2): .http(status: 429),
        ])
        let source = AdzunaSource(id: sourceID, credentials: credentials, http: http, now: { now })
        let query = SourceQuery(titles: ["software developer"], countries: [.canada], maxAgeDays: 7)
        guard case .postings(let postings, let memo) = try await source.fetch(query, since: nil) else {
            Issue.record("expected postings")
            return
        }
        #expect(postings.count == 50 && memo?.requests == 2)
        let (broken, _) = ScriptedURLProtocol.client([url("software developer", page: 1): .http(status: 500)])
        await #expect(throws: SourceError.self) {
            _ = try await AdzunaSource(id: sourceID, credentials: credentials, http: broken, now: { now })
                .fetch(query, since: nil)
        }
    }

    /// Places: city and province when Adzuna has them, else the province, else its own name.
    @Test func placesComeFromTheAreaList() {
        typealias Location = AdzunaPage.Result.Location
        #expect(
            AdzunaSource.place(
                Location(displayName: "CN Tower, City of Toronto", area: ["Canada", "Ontario", "Toronto", "CN Tower"]))
                == "Toronto, Ontario")
        #expect(
            AdzunaSource.place(Location(displayName: "British Columbia", area: ["Canada", "British Columbia"]))
                == "British Columbia")
        #expect(AdzunaSource.place(Location(displayName: "Canada", area: ["Canada"])) == "Canada")
        #expect(AdzunaSource.place(Location(displayName: nil, area: nil)) == "")
    }

    /// What's left of the plan: the tightest of the day, the week, the month and a run's share.
    @Test func whatsLeftOfThePlan() {
        let budget = AdzunaSource.Budget.standard
        #expect(budget == AdzunaSource.Budget(day: 200, week: 950, month: 2_400, run: 80))
        #expect(budget.remaining(today: 0, week: 0, month: 0) == 80)
        #expect(budget.remaining(today: 150, week: 400, month: 900) == 50)
        #expect(budget.remaining(today: 10, week: 930, month: 900) == 20)
        #expect(budget.remaining(today: 10, week: 10, month: 2_390) == 10)
        #expect(budget.remaining(today: 250, week: 0, month: 0) == 0)
    }
}
