import Foundation
import Testing

@testable import Pipeline

/// The sidebar's status line (UI v2): one wording per state, in the order the states take over.
@Suite struct RunStatusTests {
    private let at = { (_: Date) in "7:58 AM" }

    @Test func findingJobsCountsBoardsAndNewJobs() {
        var input = RunStatus.Input()
        input.fetching = true
        var fetch = FetchRun.Progress()
        fetch.sourcesTotal = 821
        fetch.sourcesDone = 212
        fetch.added = 3
        input.fetch = fetch
        let status = RunStatus.current(input, time: at)
        #expect(status.kind == .fetching)
        #expect(status.title == "Finding jobs · 212 of 821")
        #expect(status.detail == "3 new so far")
        #expect(status.fraction.map { abs($0 - 212.0 / 821.0) < 0.001 } == true)
    }

    @Test func failedBoardsShowOnTheDetailLine() {
        var input = RunStatus.Input()
        input.fetching = true
        var fetch = FetchRun.Progress()
        fetch.sourcesTotal = 10
        fetch.sourcesDone = 4
        fetch.failures = [FetchRun.Failure(sourceID: UUID(), message: "board moved")]
        input.fetch = fetch
        #expect(RunStatus.current(input, time: at).detail == "Nothing new yet · 1 board failed")
    }

    @Test func screeningTakesOverFromFetchingWhileItRuns() {
        var input = RunStatus.Input()
        input.fetching = true
        var screening = ScreeningRun.Progress()
        screening.total = 120
        screening.done = 40
        screening.yes = 3
        screening.maybe = 12
        input.screening = screening
        let status = RunStatus.current(input, time: at)
        #expect(status.kind == .screening)
        #expect(status.title == "Screening jobs · 40 of 120")
        #expect(status.detail == "3 Yes · 12 Maybe so far")
        #expect(status.fraction.map { abs($0 - 40.0 / 120.0) < 0.001 } == true)
    }

    @Test func buildingCountsResumesAndTheQueue() {
        var input = RunStatus.Input()
        input.building = 2
        input.queued = 1
        input.lastChecked = Date()
        let status = RunStatus.current(input, time: at)
        #expect(status.kind == .building)
        #expect(status.title == "Building 2 resumes")
        #expect(status.detail == "1 more queued")
        #expect(status.fraction == nil)
        input.building = 1
        input.queued = 0
        let one = RunStatus.current(input, time: at)
        #expect(one.title == "Building 1 resume" && one.detail == nil)
    }

    @Test func aRunThatStoppedEarlySaysWhyAndHowManyWait() {
        var input = RunStatus.Input()
        var screening = ScreeningRun.Progress()
        screening.phase = .finished
        screening.total = 100
        screening.done = 60
        screening.stopped = "Daily AI budget reached · resets at 4:00 AM"
        input.screening = screening
        input.waiting = 40
        input.lastChecked = Date()
        let status = RunStatus.current(input, time: at)
        #expect(status.kind == .stoppedEarly)
        #expect(status.title == "Screening stopped · 40 waiting")
        #expect(status.detail == "Daily AI budget reached · resets at 4:00 AM")
        #expect(status.fraction.map { abs($0 - 0.6) < 0.001 } == true)
    }

    @Test func aCancelledRunWithNothingWaitingIsJustIdle() {
        var input = RunStatus.Input()
        var screening = ScreeningRun.Progress()
        screening.phase = .cancelled
        input.screening = screening
        input.waiting = 0
        input.lastChecked = Date()
        input.newLastTime = 14
        let status = RunStatus.current(input, time: at)
        #expect(status.kind == .idle)
        #expect(status.title == "Checked 7:58 AM · 14 new")
        #expect(status.detail == nil)
    }

    @Test func idleNamesTheLastCheckAndWhatWaits() {
        var input = RunStatus.Input()
        input.lastChecked = Date()
        input.newLastTime = 0
        input.waiting = 40
        let status = RunStatus.current(input, time: at)
        #expect(status.title == "Checked 7:58 AM · nothing new")
        #expect(status.detail == "40 waiting for the AI")
        input.canAnalyse = false
        #expect(RunStatus.current(input, time: at).detail == "40 waiting · add an AI key in Settings")
    }

    @Test func beforeAnyCheckItPointsAtTheNextStep() {
        var input = RunStatus.Input()
        input.hasSources = false
        let none = RunStatus.current(input, time: at)
        #expect(none.kind == .never && none.title == "No companies yet" && none.detail == "Add a company in Sources")
        input.hasSources = true
        let some = RunStatus.current(input, time: at)
        #expect(some.title == "Not checked yet" && some.detail == "Find new jobs checks every board")
    }
}
