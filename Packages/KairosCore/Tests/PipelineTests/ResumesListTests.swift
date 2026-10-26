import Foundation
import Tailoring
import Testing

@testable import Pipeline

/// The Resumes list's groups (UI v2).
@Suite struct ResumesListTests {
    private let now = Date(timeIntervalSince1970: 1_761_480_000)  // a mid-morning

    private func build(_ status: BuildStatus, daysAgo: Double, minutesAgo: Double = 0) -> BuildRecord {
        BuildRecord(
            id: UUID(), jobID: "job", mode: .strict, masterVersion: 1, status: status, content: nil, score: nil,
            iterations: 0, error: nil, createdAt: now.addingTimeInterval(-daysAgo * 86_400 - minutesAgo * 60),
            finishedAt: nil)
    }

    @Test func buildsUnderWayComeFirstWhateverTheirDay() {
        let queued = build(.queued, daysAgo: 1)
        let running = build(.running, daysAgo: 0, minutesAgo: 2)
        let done = build(.done, daysAgo: 0, minutesAgo: 30)
        let groups = ResumesList.groups([done, queued, running], now: now)
        #expect(groups.map(\.kind) == [.building, .today])
        #expect(groups[0].builds.map(\.id) == [running.id, queued.id])
        #expect(groups[1].builds.map(\.id) == [done.id])
    }

    @Test func finishedBuildsGroupByDayNewestFirst() {
        let earlier = build(.done, daysAgo: 3)
        let yesterday = build(.failed, daysAgo: 1)
        let olderToday = build(.done, daysAgo: 0, minutesAgo: 90)
        let today = build(.done, daysAgo: 0, minutesAgo: 10)
        let groups = ResumesList.groups([earlier, olderToday, yesterday, today], now: now)
        #expect(groups.map(\.kind) == [.today, .yesterday, .earlier])
        #expect(groups[0].builds.map(\.id) == [today.id, olderToday.id])
        #expect(groups[1].builds.map(\.id) == [yesterday.id])
        #expect(groups[2].builds.map(\.id) == [earlier.id])
    }

    @Test func theSummaryCountsBuildingTodayAndTheWeek() {
        let builds = [
            build(.running, daysAgo: 0), build(.done, daysAgo: 0), build(.done, daysAgo: 2), build(.done, daysAgo: 9),
        ]
        #expect(ResumesList.summary(builds, now: now) == "1 building · 2 today · 3 this week")
        #expect(ResumesList.summary([], now: now) == "0 today · 0 this week")
    }
}
