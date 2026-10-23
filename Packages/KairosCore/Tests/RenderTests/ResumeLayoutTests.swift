import Foundation
import PDFKit
import Tailoring
import Testing

@testable import Render

/// The page fitter reads how Harvard lays a resume out: each bullet's lines and how full its last
/// one is, and where the resume ends.
@Suite("Resume layout", .enabled(if: TypstBinary.url != nil, "Run scripts/fetch-typst.sh first"))
struct ResumeLayoutTests {
    /// Just past one line at Harvard's 11 pt: a few words run onto a second line.
    static let shortWrap =
        "Built an event pipeline in Go and Kafka that handled 4.2 million events a day at a p99 latency under 120 ms in production"

    func render(_ build: TailoredResume, for template: ResumeTemplate = .harvard) async throws -> RenderedPDF {
        try await ResumeRenderer(runner: TypstRunner(executable: try #require(TypstBinary.url)))
            .render(ResumeDocument(build, for: template))
    }

    @Test func everyBulletIsMeasuredInItsPlace() async throws {
        var build = jordanBuild()
        build.experience[0].bullets[0].text = Self.shortWrap
        let rendered = try await render(build)
        let layout = rendered.pageLayout
        #expect(layout.isMeasured && layout.pages == 1 && rendered.pageCount == 1)
        #expect(layout.experience.map(\.count) == [2, 1] && layout.projects.map(\.count) == [1])
        let wrapped = layout.experience[0][0]
        #expect(wrapped.lines == 2 && wrapped.isShortWrap, "\(wrapped)")
        #expect(layout.experience[0][1].lines == 1 && !layout.experience[0][1].isShortWrap)
        #expect(layout.experience[0][1].lastLineFill > 0.5 && layout.experience[0][1].lastLineFill <= 1)
        // A letter page at ¾ in margins holds about 59 lines of 11 pt; this short resume leaves most free.
        #expect((55...62).contains(layout.linesPerPage), "\(layout.linesPerPage)")
        #expect(layout.freeLines > 10 && layout.freeLines < layout.linesPerPage)
        #expect(layout.overflow(budget: 1) == 0)
    }

    /// Past the page, the overflow is what the second page holds, in lines.
    @Test func whatRunsOntoAnotherPageIsCountedInLines() async throws {
        var build = jordanBuild()
        build.experience[1].bullets += (1...60).map {
            TailoredBullet(text: "Shipped release \($0) of a client API.", sourceIDs: [UUID()])
        }
        let rendered = try await render(build)
        let layout = rendered.pageLayout
        #expect(layout.pages == 2 && rendered.pageCount == 2)
        #expect(layout.experience[1].count == 61 && layout.experience[1].allSatisfy { $0.lines == 1 })
        let overflow = layout.overflow(budget: 1)
        #expect(overflow > 1 && overflow == layout.linesPerPage - layout.freeLines)
        #expect(layout.overflow(budget: 2) == 0)
    }

    /// Classic isn't measured: the fitter gets its page count only.
    @Test func classicGivesOnlyItsPageCount() async throws {
        let rendered = try await render(jordanBuild(), for: .classic)
        #expect(rendered.layout == nil && !rendered.pageLayout.isMeasured)
        #expect(rendered.pageLayout == PageLayout(pages: rendered.pageCount))
    }
}
