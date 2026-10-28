import Engine
import Foundation
import Jobs
import Screening
import Store
import Testing

@Suite("Job lists")
struct JobListsTests {
    static func job(
        _ id: String, company: String = "Acme", verdict: Verdict? = nil, stage: ScreeningState.Stage? = .judged,
        country: Country? = .canada, rank: Double = 0, seen: Double = 0, decision: Job.Decision? = nil,
        applied: Bool = false, closed: Bool = false, yours: Verdict? = nil
    ) -> JobSummary {
        JobSummary(
            id: id, company: company, title: "Engineer \(id)", placeLine: "Toronto, ON", country: country,
            firstSeenAt: day(seen), closedAt: closed ? now : nil, decision: decision,
            screening: stage.map {
                ScreeningState(stage: $0, verdict: verdict, rank: rank, yourVerdict: yours, screenedAt: now)
            },
            application: applied ? .init(id: UUID(), status: .applied) : nil)
    }

    @Test func eachListShowsItsJobs() {
        let jobs = [
            Self.job("yes", verdict: .yes), Self.job("no", verdict: .no),
            Self.job("filtered", stage: .filtered), Self.job("waiting", stage: .waiting), Self.job("new", stage: nil),
            Self.job("saved", verdict: .maybe, decision: .saved),
            Self.job("skipped", verdict: .yes, decision: .skipped),
            Self.job("gone", verdict: .maybe, closed: true), Self.job("applied", verdict: .yes, applied: true),
            Self.job("overruled", stage: .filtered, yours: .yes),
        ]
        #expect(JobLists.inbox(jobs).map(\.id) == ["yes", "no", "overruled"])
        #expect(JobLists.saved(jobs).map(\.id) == ["saved"])
        #expect(JobLists.skipped(jobs).map(\.id) == ["skipped", "gone"])
        #expect(JobLists.filteredOut(jobs).map(\.id) == ["filtered"])
        #expect(JobLists.waitingForAI(jobs).map(\.id) == ["waiting"])
    }

    @Test func theInboxPutsTheAIsNoApartAndSortsByYourCountriesThenVerdictThenRank() {
        let jobs = [
            Self.job("us-yes", verdict: .yes, country: .unitedStates, rank: 290),
            Self.job("ca-maybe", verdict: .maybe, rank: 120),
            Self.job("ca-yes-low", verdict: .yes, rank: 210),
            Self.job("ca-yes-high", verdict: .yes, rank: 230),
            Self.job("ca-no", verdict: .no),
        ]
        let groups = JobLists.groups(jobs, query: .init(), countries: [.canada, .unitedStates])
        #expect(groups.map(\.0) == [.decide, .no])
        #expect(groups[0].1.map(\.id) == ["ca-yes-high", "ca-yes-low", "ca-maybe", "us-yes"])
        let narrowed = JobLists.groups(jobs, query: .init(verdict: .yes, search: "high"), countries: [.canada])
        #expect(narrowed.flatMap(\.1).map(\.id) == ["ca-yes-high"])
        let newest = JobLists.sorted(
            [Self.job("old", seen: -2), Self.job("young", seen: 0)], by: .newest, countries: [.canada])
        #expect(newest.map(\.id) == ["young", "old"])
        #expect(JobLists.newToday([Self.job("old", seen: -2), Self.job("young", seen: 0)], now: now) == 1)
    }
}
