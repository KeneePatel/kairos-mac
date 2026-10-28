import Foundation
import Testing

@testable import Tailoring

/// A page as the template would measure it: a 10-line header, the fitter's own heading sizes, and
/// a line per 100 characters of bullet.
private func page(holding linesPerPage: Double) -> Tailor.Measure {
    { resume in
        func measured(_ entries: [TailoredResume.Entry]) -> [[PageLayout.Bullet]] {
            entries.map {
                $0.bullets.map { .init(lines: Int((Double($0.text.count) / 100).rounded(.up)), lastLineFill: 0.6) }
            }
        }
        let experience = measured(resume.experience)
        let projects = measured(resume.projects)
        let used =
            10 + Double(resume.experience.count) * PageFitter.roleHeading
            + Double(resume.projects.count) * PageFitter.projectHeading
            + Double((experience + projects).joined().map(\.lines).reduce(0, +))
        let pages = Int((used / linesPerPage).rounded(.up))
        return PageLayout(
            pages: pages, linesPerPage: linesPerPage, freeLines: Double(pages) * linesPerPage - used,
            experience: experience, projects: projects)
    }
}

/// A bullet `lines` long, ranked as the selector would.
private func bullet(_ name: String, lines: Int, rank: Double, gap: Bool = false) -> TailoredBullet {
    TailoredBullet(
        text: name + String(repeating: " x", count: (lines * 100 - 20) / 2), sourceIDs: [UUID()], gap: gap, rank: rank)
}

private func entry(_ title: String, _ bullets: [TailoredBullet]) -> TailoredResume.Entry {
    TailoredResume.Entry(entryID: UUID(), title: title, bullets: bullets)
}

private func fit(_ resume: TailoredResume, holding lines: Double) async throws -> PageFitter.Result {
    try await PageFitter(budget: 1, measure: page(holding: lines)).fit(resume) { _ in }
}

@Suite("Page fitter")
struct PageFitterTests {
    /// 29.5 lines on a 27-line page: the role that answers nothing goes whole, before any bullet that
    /// does. Student Mentor's lines go to the job's evidence.
    @Test func aRoleThatAnswersNothingGoesBeforeARelevantBullet() async throws {
        let relevant = entry("Developer", (1...3).map { bullet("a\($0)", lines: 2, rank: 2.25) })
        let mentor = entry("Student Mentor", (1...3).map { bullet("m\($0)", lines: 1, rank: 0) })
        let project = entry("Portfolio", (1...2).map { bullet("p\($0)", lines: 2, rank: 1.25) })
        let resume = TailoredResume(
            header: .init(name: "Jordan Rivera"), experience: [relevant, mentor], projects: [project])
        let fitted = try await fit(resume, holding: 27)
        #expect(fitted.layout.pages == 1)
        #expect(fitted.resume.experience.map(\.title) == ["Developer"])
        #expect(fitted.resume.experience[0].bullets.count == 3 && fitted.resume.projects[0].bullets.count == 2)
        #expect(fitted.dropped == 3)
    }

    /// Your most recent role stays even when none of its bullets answers the posting: its absence
    /// would read as a gap. An older one like it goes whole.
    @Test func yourLatestRoleIsNeverCutWhole() async throws {
        // Two-line bullets make it the cheapest cut per line, were it allowed.
        let latest = entry("Research Engineer", (1...3).map { bullet("r\($0)", lines: 2, rank: 0) })
        let older = entry("Student Mentor", (1...3).map { bullet("m\($0)", lines: 1, rank: 0) })
        let relevant = entry("Developer", (1...3).map { bullet("a\($0)", lines: 2, rank: 2) })
        let resume = TailoredResume(header: .init(name: "Jordan Rivera"), experience: [latest, older, relevant])
        let fitted = try await fit(resume, holding: 30)  // 32.5 lines
        #expect(fitted.resume.experience.map(\.title) == ["Research Engineer", "Developer"])
        #expect(fitted.resume.experience[0].bullets.count == 3 && fitted.layout.pages == 1)
    }

    /// An older role can go down to one bullet before a strong project is cut; your latest role keeps
    /// two. 22.5 lines on a 21.5-line page.
    @Test func anOlderRoleGoesToOneBulletBeforeAStrongProjectGoes() async throws {
        let latest = entry("Developer", [bullet("l1", lines: 1, rank: 3), bullet("l2", lines: 1, rank: 3)])
        let older = entry("Student Mentor", [bullet("o1", lines: 1, rank: 1.5), bullet("o2", lines: 1, rank: 1.5)])
        let project = entry("Dockyard", [bullet("p1", lines: 2, rank: 8)])
        let resume = TailoredResume(
            header: .init(name: "Jordan Rivera"), experience: [latest, older], projects: [project])
        let fitted = try await fit(resume, holding: 21.5)
        #expect(fitted.resume.experience.map(\.bullets.count) == [2, 1])
        #expect(fitted.resume.projects.map(\.title) == ["Dockyard"] && fitted.dropped == 1)
    }

    /// Your latest role never drops under two bullets: with two left, neither is offered as a cut,
    /// and a role that answers the posting is never cut whole. A project can go.
    @Test func aKeptRoleKeepsTwoBullets() {
        let role = entry("Developer", [bullet("a1", lines: 1, rank: 0.5), bullet("a2", lines: 1, rank: 0.5)])
        let project = entry("Dockyard", [bullet("p1", lines: 1, rank: 3)])
        let resume = TailoredResume(header: .init(name: "Jordan Rivera"), experience: [role], projects: [project])
        let layout = PageLayout(
            pages: 2, linesPerPage: 20, freeLines: 19,
            experience: [[.init(lines: 1, lastLineFill: 1), .init(lines: 1, lastLineFill: 1)]],
            projects: [[.init(lines: 1, lastLineFill: 1)]])
        #expect(PageFitter.cheapest(in: resume, cuts: .init(), layout: layout) == .entry(project.entryID))
    }

    /// 24.5 lines on a 21.5-line page. The cheapest cut, an off-topic bullet, isn't enough; the next,
    /// a weak project, overshoots, so the bullet comes back into the freed lines.
    @Test func linesFreedByACutAreFilledAgain() async throws {
        let role = entry(
            "Developer",
            [bullet("a1", lines: 2, rank: 2.25), bullet("a2", lines: 2, rank: 2.25), bullet("a3", lines: 2, rank: 0)])
        let weak = entry("Ledger", [bullet("p1", lines: 1, rank: 0.25), bullet("p2", lines: 1, rank: 0.25)])
        let strong = entry("Dockyard", [bullet("q1", lines: 1, rank: 1)])
        let resume = TailoredResume(header: .init(name: "Jordan Rivera"), experience: [role], projects: [weak, strong])
        var steps: [BuildStep] = []
        let fitted = try await PageFitter(budget: 1, measure: page(holding: 21.5)).fit(resume) { steps.append($0) }
        #expect(steps == [.fitting(pages: 2), .fitting(pages: 2)])  // a3, then Ledger
        #expect(fitted.resume.experience[0].bullets.count == 3)  // a3 came back
        #expect(fitted.resume.projects.map(\.title) == ["Dockyard"])
        #expect(fitted.dropped == 2 && fitted.layout.pages == 1 && fitted.layout.freeLines == 0.5)
    }

    /// A stretch-mode gap bullet goes before anything your master resume backs.
    @Test func aGapBulletGoesFirst() async throws {
        let role = entry(
            "Developer",
            [
                bullet("a1", lines: 1, rank: 0), bullet("a2", lines: 1, rank: 0),
                bullet("gap", lines: 2, rank: 2, gap: true),
            ])
        let resume = TailoredResume(header: .init(name: "Jordan Rivera"), experience: [role])
        let fitted = try await fit(resume, holding: 15.5)  // 16.5 lines
        #expect(fitted.resume.experience[0].bullets.map(\.gap) == [false, false])
        #expect(fitted.resume.experience[0].bullets.map { $0.text.prefix(2) } == ["a1", "a2"])
    }

    /// With two pages allowed, a second is used only when what answers the posting runs half a page
    /// past the first. A role that answers nothing doesn't count toward it: it would be cut first.
    @Test func aSecondPageOnlyWhenTheEvidenceNeedsIt() async throws {
        func role(_ title: String, rank: Double) -> TailoredResume.Entry {
            entry(title, (1...8).map { bullet("\(title)\($0)", lines: 2, rank: rank) })
        }
        let strong = TailoredResume(
            header: .init(name: "Jordan Rivera"),
            experience: [role("a", rank: 2), role("b", rank: 2), role("c", rank: 2)])  // 65.5 lines
        let allowed = PageFitter(budget: 1, allowingTwo: true, measure: page(holding: 40))
        let two = try await allowed.fit(strong) { _ in }
        #expect(two.budget == 2 && two.layout.pages == 2 && two.dropped == 0)
        let one = try await PageFitter(budget: 1, measure: page(holding: 40)).fit(strong) { _ in }
        #expect(one.budget == 1 && one.layout.pages == 1)  // not allowed: one page

        var padded = strong
        padded.experience[2] = role("m", rank: 0)  // the same length, answering nothing
        let fitted = try await allowed.fit(padded) { _ in }
        #expect(fitted.budget == 1 && fitted.layout.pages == 1)
        #expect(!fitted.resume.experience.map(\.title).contains("m"))
    }

    /// When cuts alone can't fit it, it falls back to dropping by rank, down to one bullet a role.
    @Test func whatCantFitOtherwiseFallsBackToRank() async throws {
        let role = entry("Developer", (1...4).map { bullet("a\($0)", lines: 2, rank: 2) })
        let resume = TailoredResume(header: .init(name: "Jordan Rivera"), experience: [role])
        let fitted = try await fit(resume, holding: 15)  // 20.5 lines; two bullets still leave 16.5
        #expect(fitted.layout.pages == 1 && fitted.resume.experience[0].bullets.count == 1)
        #expect(fitted.dropped == 3)
    }
}
