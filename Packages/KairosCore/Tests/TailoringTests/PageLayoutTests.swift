import Testing

@testable import Tailoring

@Suite("Page layout")
struct PageLayoutTests {
    @Test func overflowIsTheLinesPastTheBudget() {
        let layout = PageLayout(pages: 2, linesPerPage: 58, freeLines: 50)
        #expect(layout.overflow(budget: 1) == 8)  // 8 lines on page 2
        #expect(layout.overflow(budget: 2) == 0)
        #expect(PageLayout(pages: 3, linesPerPage: 58, freeLines: 50).overflow(budget: 1) == 66)
    }

    @Test func aShortWrapIsAFewWordsOnAnExtraLine() {
        #expect(PageLayout.Bullet(lines: 2, lastLineFill: 0.2).isShortWrap)
        #expect(!PageLayout.Bullet(lines: 2, lastLineFill: 0.6).isShortWrap)
        #expect(!PageLayout.Bullet(lines: 1, lastLineFill: 0.2).isShortWrap)  // one line is never a wrap
    }

    @Test func aPageCountAloneIsNotMeasured() {
        let counted = PageLayout(pages: 1)
        #expect(!counted.isMeasured && counted.bullets.isEmpty && counted.overflow(budget: 1) == 0)
        let measured = PageLayout(
            pages: 1, linesPerPage: 58, freeLines: 3, experience: [[.init(lines: 2, lastLineFill: 0.5)]],
            projects: [[.init(lines: 1, lastLineFill: 0.9)]])
        #expect(measured.isMeasured && measured.bullets.map(\.lines) == [2, 1])
    }
}
