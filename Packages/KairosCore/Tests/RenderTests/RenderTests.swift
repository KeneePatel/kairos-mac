import Foundation
import PDFKit
import Resume
import Tailoring
import TestKit
import Testing

@testable import Render

private func renderer() throws -> ResumeRenderer {
    let typst = try #require(TypstBinary.url, "run scripts/fetch-typst.sh: render tests need the pinned typst")
    return ResumeRenderer(runner: TypstRunner(executable: typst))
}

private func text(_ pdf: RenderedPDF) -> String {
    PDFDocument(data: pdf.data)?.string ?? ""
}

/// A build as the sample persona's resume would come out of the tailor.
private func sampleBuild() -> TailoredResume {
    let master = Sample.resume
    let roles = master.entries(.experience).map { entry -> TailoredResume.Entry in
        guard case .experience(let role) = entry.fields else { return TailoredResume.Entry(entryID: entry.id, title: "") }
        return TailoredResume.Entry(
            entryID: entry.id, title: role.title, organization: role.employer, location: role.location,
            period: TailoredResume.Period(entry),
            bullets: entry.bullets.map { TailoredBullet(text: $0.text, sourceIDs: [$0.id], rank: 2) })
    }
    let school = TailoredResume.Entry(
        entryID: Sample.id(4), title: "BMath, Computer Science", organization: "University of Waterloo", location: "Waterloo, ON",
        period: .init(start: .init(year: 2016, month: 9), end: .init(year: 2027, month: 4)))
    return TailoredResume(
        header: TailoredResume.Header(master.header), skills: [SkillGroup(label: "Languages", skills: ["Go", "Python"])],
        experience: roles, education: [school], languages: "English (native)")
}

@Suite("Rendering")
struct RenderTests {
    @Test func aBuildPrintsInHarvardsLayoutAndMeasuresItself() async throws {
        let now = isoDate("2026-10-28T12:00:00Z")
        let document = ResumeDocument(sampleBuild(), now: now)
        #expect(document.sections.map(\.kind) == [.education, .skills, .experience])
        #expect(document.sections[0].items[0].dates == "September 2016 – April 2027 (Expected)")
        #expect(document.sections[2].items[0].dates == "March 2022 – Present")
        #expect(document.sections[1].groups.last == ResumeDocument.Group(label: "Language", items: ["English (native)"]))
        #expect(document.header.contact.map(\.kind) == [.location, .phone, .email, .linkedIn, .gitHub])

        let pdf = try await renderer().render(document, createdAt: now)
        #expect(pdf.pageCount == 1)
        let printed = text(pdf)
        #expect(printed.contains("JORDAN RIVERA") && printed.contains("EXPERIENCE") && printed.contains("Harbourline Logistics"))
        #expect(printed.contains("(416) 555-0123"))
        let layout = try #require(pdf.layout).pageLayout
        #expect(layout.isMeasured && layout.pages == 1 && layout.freeLines > 0)
        #expect(layout.experience.map(\.count) == [3, 2] && layout.experience[0].allSatisfy { $0.lines >= 1 })
        // The same document gives the same bytes.
        #expect(try await renderer().render(document, createdAt: now).data == pdf.data)
    }

    @Test func textThatLooksLikeMarkupStaysText() async throws {
        var build = sampleBuild()
        build.experience[0].bullets[0].text = "Wrote #set page(width: 1pt) and *bold* and $x$ and <label> as plain text."
        let pdf = try await renderer().render(ResumeDocument(build))
        #expect(pdf.pageCount == 1 && text(pdf).contains("#set page(width: 1pt)"))
    }

    @Test func aLetterPrintsUnderTheSameHeader() async throws {
        let letter = CoverLetter(
            header: TailoredResume.Header(Sample.header), date: "October 28, 2026", company: "Northline Freight",
            jobTitle: "Backend Developer II", greeting: "Dear Northline Freight hiring team,",
            paragraphs: ["I build reliable services.", "I'd welcome a conversation."], closing: "Sincerely,", signature: "Jordan Rivera")
        let pdf = try await renderer().render(letter: LetterDocument(letter))
        let printed = text(pdf)
        #expect(pdf.pageCount == 1 && printed.contains("Re: Backend Developer II") && printed.contains("Sincerely,"))
    }

    @Test func theWholeMasterResumePrintsWithNoPageBudget() async throws {
        let pdf = try await renderer().render(ResumeDocument(FullResume(Sample.resume)))
        let printed = text(pdf)
        #expect(printed.contains("SUMMARY") && printed.contains("Can discuss") && printed.contains("Ledger"))
        #expect(printed.contains("AWS Certified Solutions Architect – Associate · Amazon Web Services"))
    }

    @Test func datesAndContactsTakeHarvardsForm() {
        let period = TailoredResume.Period(start: .init(year: 2024, month: 1), end: .init(year: 2025, month: 8))
        #expect(HarvardDates.text(period) == "January 2024 – August 2025")
        #expect(HarvardDates.spelledOut("Mar 2022 – Present") == "March 2022 – Present")
        #expect(ResumeDocument.ContactItem(text: "416", url: "tel:+1416").kind == .phone)
        #expect(ResumeDocument.ContactItem(text: "x", url: "https://ca.linkedin.com/in/x").kind == .linkedIn)
        #expect(ResumeDocument.ContactItem(text: "Toronto, ON").kind == .location)
    }

    /// 2026-10-20: a build froze for hours waiting on a typst that had already exited. A slow typst
    /// is stopped at the timeout, and its process doesn't outlive it.
    @Test func aTypstThatHangsIsStoppedAtItsTimeout() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kairos-hang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "typst")
        try "#!/bin/sh\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = TypstRunner(executable: script, timeout: .milliseconds(300))
        let started = Date()
        await #expect(throws: RenderError.timedOut) { _ = try await runner.compile(template: "x", data: Data("{}".utf8)) }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aBrokenTemplateSaysWhy() async throws {
        let typst = try #require(TypstBinary.url)
        let error = await #expect(throws: RenderError.self) {
            _ = try await TypstRunner(executable: typst).compile(template: "#let x = (", data: Data("{}".utf8))
        }
        guard case .compile(let reason)? = error else { return }
        #expect(reason.contains("error"))
    }
}
