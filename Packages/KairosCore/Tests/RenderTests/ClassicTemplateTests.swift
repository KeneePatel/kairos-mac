import Foundation
import PDFKit
import Testing

@testable import Render

/// The design's sample persona (fixtures only).
func jordan() -> ResumeDocument {
    ResumeDocument(
        header: .init(
            name: "Jordan Rivera", headline: "Backend developer: event-driven services in Go and Java",
            contact: [
                .init(text: "jordan.rivera@example.com", url: "mailto:jordan.rivera@example.com"),
                .init(text: "(416) 555-0123"),
                .init(text: "linkedin.com/in/jordan-rivera", url: "https://www.linkedin.com/in/jordan-rivera"),
                .init(text: "Toronto, ON"),
            ]),
        sections: [
            .init(
                kind: .summary, title: "Summary",
                text: "Backend developer with 5 years building event-driven services for logistics and fintech."),
            .init(
                kind: .experience, title: "Experience",
                items: [
                    .init(
                        title: "Software Developer, Backend", subtitle: "Harbourline Logistics",
                        location: "Toronto, ON",
                        dates: "Mar 2022 – Present",
                        bullets: [
                            "Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms.",
                            "Onboarded 11 carriers in 4 days instead of 3 weeks with a gRPC integration kit.",
                        ]),
                    .init(
                        title: "Junior Developer", subtitle: "Rivet Studio", location: "Toronto, ON",
                        dates: "Jun 2020 – Feb 2022",
                        bullets: ["Shipped REST APIs in Django and PostgreSQL for 30+ client projects."]),
                ]),
            .init(
                kind: .projects, title: "Projects",
                items: [
                    .init(
                        title: "Dockyard", subtitle: "Go", dates: "2023 – Present",
                        bullets: ["Finds and removes dangling Docker images and volumes; 400+ stars."])
                ]),
            .init(
                kind: .education, title: "Education",
                items: [
                    .init(title: "BMath, Computer Science", subtitle: "University of Waterloo", dates: "2015 – 2019")
                ]),
            .init(
                kind: .skills, title: "Skills",
                groups: [
                    .init(label: "Languages", items: ["Go", "Java", "Python", "SQL"]),
                    .init(label: "Infrastructure", items: ["Kubernetes", "Docker", "Terraform"]),
                ]),
            .init(
                kind: .certifications, title: "Certifications",
                items: [.init(title: "AWS Solutions Architect – Associate", dates: "2024")]),
            .init(kind: .languages, title: "Languages", text: "English (native), French (conversational)"),
        ])
}

/// Whitespace collapsed, so line breaks PDFKit invents don't matter.
private func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Suite("Classic template", .enabled(if: TypstBinary.url != nil, "Run scripts/fetch-typst.sh first"))
struct ClassicTemplateTests {
    func renderer() throws -> ResumeRenderer {
        ResumeRenderer(runner: TypstRunner(executable: try #require(TypstBinary.url)))
    }

    /// The golden file lists the resume's lines in reading order; each must appear, in order. Order is
    /// where each line sits on the page, not where PDFKit's text stream puts it: macOS 26 and 27
    /// order that stream differently. Lines marked "~" (the right-aligned dates) only need to be there.
    @Test func theSampleResumeRendersOnOnePageInOrder() async throws {
        let rendered = try await renderer().render(jordan())
        #expect(rendered.pageCount == 1)
        let text = normalized(try #require(PDFDocument(data: rendered.data)?.string))
        let document = try #require(PDFDocument(data: rendered.data))
        let page = try #require(document.page(at: 0))
        let golden = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Fixtures/render/classic-golden.txt"), encoding: .utf8)
        // Reading goes down the page, so each line's height on it may only fall (PDF y grows upward).
        var cursor = CGFloat.infinity
        for raw in golden.split(separator: "\n").map(String.init) {
            let anywhere = raw.hasPrefix("~ ")
            let line = anywhere ? String(raw.dropFirst(2)) : raw
            let found = document.findString(line, withOptions: []).map { $0.bounds(for: page).midY }
                .first { anywhere || $0 <= cursor + 2 }
            #expect(found != nil, "“\(line)” is missing or out of order")
            #expect(text.contains(normalized(line)), "“\(line)” isn't in the PDF's text")
            if let found, !anywhere { cursor = found }
        }
    }

    @Test func sectionOrderAndVisibilityAreInputs() async throws {
        var document = jordan()
        let education = try #require(document.sections.firstIndex { $0.kind == .education })
        document.sections.insert(document.sections.remove(at: education), at: 0)
        document.sections[document.sections.firstIndex { $0.kind == .skills }!].visible = false
        let text = normalized(try #require(PDFDocument(data: try await renderer().render(document).data)?.string))
        let educationAt = try #require(text.range(of: "EDUCATION")?.lowerBound)
        let experienceAt = try #require(text.range(of: "EXPERIENCE")?.lowerBound)
        #expect(educationAt < experienceAt)
        #expect(!text.contains("SKILLS") && !text.contains("Infrastructure"))
    }

    /// Content is data the template reads, never Typst source, so markup characters print as typed.
    @Test func typstMarkupInContentPrintsLiterally() async throws {
        var document = jordan()
        document.sections[1].items[0].bullets = [
            #"Cut costs 30% with #fast *builds* in C# and $5 [templates] <tags> @refs \escapes"#,
            #"#import "evil.typ": * and #panic("no")"#,
        ]
        let text = normalized(try #require(PDFDocument(data: try await renderer().render(document).data)?.string))
        #expect(text.contains(#"Cut costs 30% with #fast *builds* in C# and $5 [templates] <tags> @refs \escapes"#))
        #expect(text.contains(#"#import "evil.typ": * and #panic("no")"#))
    }

    @Test func itIsSetInTheBundledSerifAndReproducible() async throws {
        let renderer = try renderer()
        let first = try await renderer.render(jordan(), createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let second = try await renderer.render(jordan(), createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(first.data == second.data)  // same input, same bytes
        #expect(first.data.range(of: Data("SourceSerif4-Regular".utf8)) != nil)
        #expect(first.data.range(of: Data("SourceSerif4-Bold".utf8)) != nil)
    }

    @Test func theBundledFontsShipWithTheModule() throws {
        let fonts = try #require(TypstRunner.bundledFonts)
        let files = try FileManager.default.contentsOfDirectory(atPath: fonts.path())
        #expect(Set(files.filter { $0.hasSuffix(".otf") }).count == 4 && files.contains("OFL.txt"))
    }
}
