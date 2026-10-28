import Engine
import Foundation
import Jobs
import Resume
import Screening
import Store
import TestKit
import Testing

@Suite("Improve")
struct ImproveReportTests {
    /// Two Maybe jobs held back only by Kafka, and one decided by your level.
    @Test func fixesAreRankedByTheVerdictsTheyWouldMove() throws {
        func job(_ id: String) -> Job {
            Job(
                id: id, company: "Acme", title: "Backend Developer", city: "Toronto", country: .canada, url: "u\(id)",
                firstSeenAt: now)
        }
        let analysis = JobAnalysis(requirements: [
            .init(text: "Go", kind: .must, category: .skill, match: .yes),
            .init(text: "PostgreSQL", kind: .must, category: .skill, match: .yes),
            .init(text: "Experience with Kafka", kind: .must, category: .skill, match: .no),
        ])
        let preferences = SearchPreferences()
        let engine = VerdictEngine(preferences: preferences, profile: WorkProfile(), languages: [], totalYears: 5)
        var summaries: [JobSummary] = []
        var analyses: [String: StoredAnalysis] = [:]
        var details: [String: Job] = [:]
        for id in ["a", "b"] {
            let decision = engine.decide(analysis, for: job(id))
            #expect(decision.verdict == .maybe)
            summaries.append(
                JobSummary(
                    id: id, company: "Acme", title: "Backend Developer", placeLine: "Toronto", firstSeenAt: now,
                    screening: ScreeningState(
                        stage: .judged, verdict: decision.verdict, rule: decision.rule.rawValue, screenedAt: now)))
            analyses[id] = StoredAnalysis(analysis: analysis, model: "m", promptVersion: 2, analyzedAt: now)
            details[id] = job(id)
        }
        summaries.append(
            JobSummary(
                id: "c", company: "Acme", title: "Staff Engineer", placeLine: "Toronto", firstSeenAt: now,
                screening: ScreeningState(
                    stage: .judged, verdict: .no, rule: VerdictRule.seniority.rawValue, screenedAt: now)))
        analyses["c"] = StoredAnalysis(analysis: analysis, model: "m", promptVersion: 2, analyzedAt: now)
        details["c"] = job("c")

        let report = ImproveReport(
            jobs: summaries, analyses: analyses, details: details, resume: Sample.resume, preferences: preferences,
            profile: WorkProfile())
        #expect(report.analysed == 3)
        let kafka = try #require(report.fixes.first)
        #expect(kafka.id == "tech:kafka" && kafka.toYes == 2 && kafka.jobs == ["a", "b"])
        #expect(kafka.standing == .proven("Kafka"))
        #expect(report.held.map(\.rule) == [.seniority])
    }
}
