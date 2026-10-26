import Foundation
import Store
import Testing

@testable import Pipeline

/// The Inbox's groups and order (UI v2).
@Suite struct InboxTests {
    private func job(
        _ title: String, company: String = "Acme", verdict: Verdict? = .maybe, source: VerdictSource? = .analysis,
        state: JobState = .new, country: Country? = .canada, rank: Double? = 50, closed: Bool = false,
        seen: TimeInterval = 0, snippet: Bool = false
    ) -> Job {
        var job = Job(
            canonicalURL: "https://example.com/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
            sourceID: UUID(), url: "https://example.com", dedupKey: title, company: company, title: title,
            country: country, firstSeenAt: Date(timeIntervalSince1970: 1_700_000_000 + seen))
        job.verdict = verdict
        job.verdictSource = source
        job.state = state
        job.rank = rank
        job.closedAt = closed ? Date() : nil
        job.descriptionKind = snippet ? .snippet : .full
        return job
    }

    private let countries: [Country] = [.canada, .unitedStates]

    @Test func waitingLeavesOutWhatYouDecidedAndWhatIsntJudged() {
        let jobs = [
            job("New"), job("Saved", state: .shortlisted), job("Skipped", state: .skipped),
            job("Applied", state: .applied), job("Archived", state: .archived), job("Unjudged", verdict: nil),
            job("Prefiltered", verdict: .no, source: .prefilter), job("Closed", closed: true),
        ]
        #expect(Inbox.waiting(jobs).map(\.title) == ["New"])
        #expect(Inbox.saved(jobs).map(\.title) == ["Saved"])
        #expect(Inbox.skipped(jobs).map(\.title) == ["Skipped", "Closed"])
    }

    @Test func snippetsNeedAFullReadAndNoSitsApart() {
        let jobs = [
            job("Full Maybe"), job("Snippet", snippet: true), job("Snippet No", verdict: .no, snippet: true),
            job("Full No", verdict: .no), job("Full Yes", verdict: .yes),
        ]
        let groups = Inbox.groups(jobs, query: Inbox.Query(), countries: countries) { $0.descriptionKind == .snippet }
        #expect(groups.map(\.kind) == [.decide, .needsFullRead, .noFromAI])
        #expect(groups[0].jobs.map(\.title) == ["Full Yes", "Full Maybe"])
        #expect(groups[1].jobs.map(\.title) == ["Snippet"])
        #expect(groups[2].jobs.map(\.title) == ["Full No", "Snippet No"])
    }

    @Test func matchOrderIsYourCountriesThenVerdictThenRankThenNewest() {
        let jobs = [
            job("US Yes", verdict: .yes, country: .unitedStates, rank: 90),
            job("CA Maybe high", rank: 80), job("CA Maybe low", rank: 40),
            job("CA Yes", verdict: .yes, rank: 70), job("Nowhere", country: nil, rank: 99),
            job("CA Maybe low, newer", rank: 40, seen: 100),
        ]
        let sorted = Inbox.sorted(jobs, by: .match, countries: countries)
        #expect(
            sorted.map(\.title) == [
                "CA Yes", "CA Maybe high", "CA Maybe low, newer", "CA Maybe low", "US Yes", "Nowhere",
            ])
    }

    @Test func newestAndCompanyOrders() {
        let jobs = [
            job("B", company: "Zed", seen: 10), job("A", company: "Alpha", seen: 20),
            job("C", company: "Alpha", seen: 5),
        ]
        #expect(Inbox.sorted(jobs, by: .newest, countries: countries).map(\.title) == ["A", "B", "C"])
        #expect(Inbox.sorted(jobs, by: .company, countries: countries).map(\.title) == ["A", "C", "B"])
    }

    @Test func theQueryNarrowsByVerdictCountryAndWords() {
        let jobs = [
            job("Backend Developer", company: "Northline Freight", verdict: .yes),
            job("Backend Engineer", company: "Fernhill", verdict: .yes, country: .unitedStates),
            job("Data Engineer", company: "Tidewater", verdict: .maybe),
        ]
        func titles(_ query: Inbox.Query) -> [String] {
            Inbox.groups(jobs, query: query, countries: countries) { _ in false }.flatMap(\.jobs).map(\.title)
        }
        #expect(titles(Inbox.Query(verdict: .yes)) == ["Backend Developer", "Backend Engineer"])
        #expect(titles(Inbox.Query(country: .unitedStates)) == ["Backend Engineer"])
        #expect(titles(Inbox.Query(search: "backend north")) == ["Backend Developer"])
        // Canada first, whatever the verdict.
        #expect(titles(Inbox.Query(search: "ENGINEER")) == ["Data Engineer", "Backend Engineer"])
        #expect(
            Inbox.groups(jobs, query: Inbox.Query(search: "nothing here"), countries: countries) { _ in false }.isEmpty)
    }

    @Test func newTodayCountsFirstSeenDates() {
        let now = Date()
        let jobs = [job("Today", seen: now.timeIntervalSince1970 - 1_700_000_000), job("Old")]
        #expect(Inbox.newToday(jobs, now: now) == 1)
    }
}
