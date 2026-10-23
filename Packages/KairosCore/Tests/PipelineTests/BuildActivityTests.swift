import Foundation
import Store
import Testing

@testable import LLM
@testable import Pipeline

private let flash = ModelRef(provider: "gemini", model: "gemini-flash-latest")
private let lite = ModelRef(provider: "gemini", model: "gemini-flash-lite-latest")
private let start = Date(timeIntervalSince1970: 1_792_000_000)

@Suite("Build activity")
struct BuildActivityTests {
    /// Flash overloaded, retried, given up; Flash-Lite takes over: one run, now on Flash-Lite,
    /// timed from the first ask, and a note saying who wrote it and why.
    @Test func aFallbackIsOneRunWithANote() {
        var activity = BuildActivity()
        activity.apply(.asking(task: .writeExperience, model: flash, fallback: false), at: start)
        activity.apply(.retrying(task: .writeExperience, model: flash, reason: "was overloaded (503)"), at: start + 5)
        #expect(activity.runs[0].state == .retrying("was overloaded (503)"))
        activity.apply(
            .failed(task: .writeExperience, model: flash, reason: "was overloaded (503)", detail: nil), at: start + 9)
        activity.apply(.asking(task: .writeExperience, model: lite, fallback: true), at: start + 9)
        #expect(activity.runs.count == 1 && activity.runs[0].state == .asking && activity.runs[0].finished == nil)
        activity.apply(.answered(task: .writeExperience, model: lite, seconds: 3, cached: false), at: start + 12)
        let run = activity.runs[0]
        #expect(run.model == lite && run.state == .answered(cached: false) && run.seconds(at: start + 99) == 12)
        #expect(
            activity.notes == [
                .init(
                    kind: .fellBack, task: .writeExperience,
                    text: "Experience: gemini-flash-latest was overloaded (503), so gemini-flash-lite-latest wrote it.")
            ])
        #expect(activity.hasFallbacks && !activity.hasGivenUp)
    }

    /// When every model fails, the note says what the build did instead.
    @Test func noModelAnsweringIsNotedByWhatTheStepDidInstead() {
        var activity = BuildActivity()
        for (task, model) in [(TaskID.writeExperience, flash), (.coverLetter, lite), (.rewriteSection, lite)] {
            activity.apply(.asking(task: task, model: model, fallback: false), at: start)
            activity.apply(
                .failed(task: task, model: model, reason: "didn't answer in time", detail: nil), at: start + 90)
        }
        #expect(
            activity.notes.map(\.text) == [
                "Experience: uses your master resume's words because gemini-flash-latest didn't answer in time.",
                "Cover letter: was left out because gemini-flash-lite-latest didn't answer in time.",
                "Rewrite: was skipped because gemini-flash-lite-latest didn't answer in time.",
            ])
        #expect(
            activity.hasGivenUp && !activity.hasFallbacks && activity.runs.allSatisfy { $0.seconds(at: start) == 90 })
    }

    /// Two rewrite passes are two runs; a cached answer is a run that took no time; a run under way
    /// counts its seconds up.
    @Test func eachCallIsItsOwnRun() {
        var activity = BuildActivity()
        activity.apply(.answered(task: .writeSkills, model: lite, seconds: 0, cached: true), at: start)
        for pass in 0..<2 {
            let at = start + Double(pass * 10)
            activity.apply(.asking(task: .rewriteSection, model: lite, fallback: false), at: at)
            activity.apply(.answered(task: .rewriteSection, model: lite, seconds: 4, cached: false), at: at + 4)
        }
        activity.apply(.asking(task: .coverLetter, model: lite, fallback: false), at: start + 30)
        #expect(activity.runs.map(\.task) == [.writeSkills, .rewriteSection, .rewriteSection, .coverLetter])
        #expect(activity.runs[0].state == .answered(cached: true) && activity.runs[0].seconds(at: start + 50) == 0)
        #expect(activity.runs[3].seconds(at: start + 37) == 7 && activity.notes.isEmpty)
        #expect(BuildActivity.name(.shortenBullets) == "Shortening" && BuildActivity.name(.analyzeJob) == "analyzeJob")
    }
}

@Suite("Build activity from the log")
struct BuildActivityLogTests {
    /// A build made yesterday: Flash failed with a 503 and Flash-Lite took over; the letter's only
    /// model wasn't available. The log, replayed, tells the same story as it told live.
    @Test func aFinishedBuildsCallsTellWhatHappened() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let log = CallLog(db)
        func record(_ task: TaskID, _ model: String, _ outcome: LLMOutcome, _ code: String?, at seconds: Double)
            async throws
        {
            try await log.record(
                CallRecord(
                    at: start + seconds, task: task, provider: "gemini", model: model, promptVersion: 2,
                    inputTokens: nil, outputTokens: nil, latency: .seconds(4), attempts: 1, outcome: outcome,
                    errorCode: code, jobID: "j1", buildID: "b1"))
        }
        try await record(.writeExperience, "gemini-flash-latest", .failed, "server_503", at: 0)
        try await record(.writeExperience, "gemini-flash-lite-latest", .fellBack, nil, at: 5)
        try await record(.coverLetter, "gemini-flash-latest", .failed, "model_unavailable", at: 10)
        try await record(.writeSkills, "gemini-flash-latest", .ok, nil, at: 0)
        let calls = try await log.calls(build: "b1")
        #expect(calls.count == 4 && calls.first?.task == .writeExperience && calls.last?.task == .coverLetter)
        #expect(try await log.calls(build: "b2").isEmpty)
        let activity = BuildActivity(calls: calls)
        #expect(activity.runs.map(\.task) == [.writeExperience, .writeSkills, .coverLetter])
        #expect(
            activity.notes.map(\.text) == [
                "Experience: gemini-flash-latest was overloaded (503), so gemini-flash-lite-latest wrote it.",
                "Cover letter: was left out because gemini-flash-latest isn't available to this account.",
            ])
    }

    @Test func aLoggedCodeReadsAsItsReason() {
        #expect(LLMError.reason(code: "server_503") == "was overloaded (503)")
        #expect(LLMError.reason(code: "timed_out") == "didn't answer in time")
        #expect(LLMError.reason(code: "invalid_output") == "replied in a form that failed its checks")
        #expect(LLMError.reason(code: "model_unavailable") == "isn't available to this account")
        #expect(LLMError.reason(code: "something_new") == "failed (something_new)")
    }
}
