import Foundation
import MasterResume
import Testing

@testable import Tailoring

@Suite("Build report")
struct BuildReportTests {
    private func written(_ source: ResumeBullet) -> TailoredBullet {
        TailoredBullet(text: source.text, sourceIDs: [source.id])
    }

    private func entry(_ source: ResumeEntry, _ bullets: [ResumeBullet]) -> TailoredResume.Entry {
        TailoredResume.Entry(entryID: source.id, title: "Shown", bullets: bullets.map(written))
    }

    private func outcome(_ resume: TailoredResume, layout: PageLayout?, dropped: Int = 0) -> BuildOutcome {
        BuildOutcome(
            resume: resume, score: MatchScore.score(resume, for: JobRequirements(musts: [])), rewrites: 0,
            fellBack: [], pages: layout?.pages, layout: layout, dropped: dropped, coverLetter: nil)
    }

    private var resume: TailoredResume {
        TailoredResume(
            header: .init(name: "Jordan Rivera"),
            experience: [
                entry(Sample.harbourline, [Sample.pipeline, Sample.carriers]), entry(Sample.rivet, [Sample.apis]),
            ],
            projects: [entry(Sample.dockyardProject, [Sample.dockyard])],
            certifications: [TailoredResume.Entry(entryID: Sample.certificate.id, title: "AWS")])
    }

    @Test func itCountsWhatMadeThePageAndWhatWasLeftOut() {
        let layout = PageLayout(
            pages: 1, linesPerPage: 58, freeLines: 4.26,
            experience: [
                [.init(lines: 2, lastLineFill: 0.2), .init(lines: 1, lastLineFill: 0.9)],
                [.init(lines: 1, lastLineFill: 0.7)],
            ],
            projects: [[.init(lines: 2, lastLineFill: 0.5)]])
        let report = BuildReport(outcome(resume, layout: layout, dropped: 3), master: Sample.resume)
        #expect(report.experienceBullets == [2, 1] && report.projectBullets == [1] && report.bullets == 4)
        #expect(report.leftOut == ["Developer Intern, Maplepay", "Ledger"])
        #expect(report.certifications == 1 && !report.languages && report.dropped == 3 && report.pages == 1)
        #expect(report.freeLines == 4.3 && report.shortWraps == 1)
        #expect(report.numbersKept == 1)  // your bullets word for word
    }

    /// A page count alone says nothing about lines.
    @Test func anUnmeasuredPageHasNoLineFigures() {
        let report = BuildReport(outcome(resume, layout: PageLayout(pages: 1)), master: Sample.resume)
        #expect(report.pages == 1 && report.freeLines == nil && report.shortWraps == nil)
        #expect(BuildReport(outcome(resume, layout: nil), master: Sample.resume).pages == nil)
    }

    /// The pipeline bullet states 4.2M events and 120 ms. "4.2 million" is the same number; leaving
    /// out the latency loses one of two.
    @Test func numbersKeptComparesValuesWithTheCitedBullets() {
        let kept = TailoredBullet(
            text: "Built a Go pipeline for 4.2 million events a day at p99 under 120 ms.",
            sourceIDs: [Sample.pipeline.id])
        let lost = TailoredBullet(
            text: "Built a fast Go event pipeline handling 4.2M events a day.", sourceIDs: [Sample.pipeline.id])
        let plain = TailoredBullet(text: "Built Ledger in SwiftUI.", sourceIDs: [Sample.ledger.id])
        #expect(BuildReport.numbersKept([kept], master: Sample.resume) == 1)
        #expect(BuildReport.numbersKept([kept, lost], master: Sample.resume) == 0.75)
        #expect(BuildReport.numbersKept([plain], master: Sample.resume) == 1)
    }
}
