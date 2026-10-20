import Foundation
import PDFKit
import Tailoring
import Testing

@testable import Render

/// The design's sample persona's letter (fixtures only; Northline Freight is fictional).
private func letter(_ paragraphs: [String]? = nil) -> CoverLetter {
    CoverLetter(
        header: .init(
            name: "Jordan Rivera",
            contact: [
                .init(text: "jordan.rivera@example.com", url: "mailto:jordan.rivera@example.com"),
                .init(text: "(416) 555-0123"), .init(text: "Toronto, ON"),
            ]),
        date: "October 20, 2026", company: "Northline Freight", jobTitle: "Backend Developer II",
        greeting: "Dear Northline Freight hiring team,",
        paragraphs: paragraphs ?? [
            "I'm applying for the Backend Developer II role at Northline Freight. For the past 5 years I've built backend services in Go and Java.",
            "At Harbourline Logistics I built an event pipeline in Go and Kafka that handles 4.2M events a day with p99 under 120 ms.",
            "I'd welcome a conversation about how I could help your team.",
        ], closing: "Sincerely,", signature: "Jordan Rivera")
}

private func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@Suite("Letter document")
struct LetterDocumentTests {
    /// Code writes everything around the paragraphs; the template only lays it out.
    @Test func aLetterBecomesADocument() {
        let document = LetterDocument(letter())
        #expect(document.header.name == "Jordan Rivera" && document.header.contact.count == 3)
        #expect(document.recipient == ["Hiring team", "Northline Freight"])
        #expect(document.subject == "Re: Backend Developer II" && document.paragraphs.count == 3)
        #expect(document.style.fontSize == 11 && document.style.margin == 1)
    }
}

@Suite("Cover template", .enabled(if: TypstBinary.url != nil, "Run scripts/fetch-typst.sh first"))
struct CoverTemplateTests {
    func renderer() throws -> ResumeRenderer {
        ResumeRenderer(runner: TypstRunner(executable: try #require(TypstBinary.url)))
    }

    /// One page, top to bottom: header, date, recipient, subject, greeting, paragraphs, sign-off.
    @Test func theSampleLetterRendersOnOnePageInOrder() async throws {
        let rendered = try await renderer().render(.letter(LetterDocument(letter())))
        #expect(rendered.pageCount == 1)
        let document = try #require(PDFDocument(data: rendered.data))
        let page = try #require(document.page(at: 0))
        let lines = [
            "Jordan Rivera", "jordan.rivera@example.com", "October 20, 2026", "Hiring team", "Northline Freight",
            "Re: Backend Developer II", "Dear Northline Freight hiring team,", "I'm applying for the Backend",
            "At Harbourline Logistics", "I'd welcome a conversation", "Sincerely,",
        ]
        // Reading goes down the page, so each line's height on it may only fall (PDF y grows upward).
        var cursor = CGFloat.infinity
        for line in lines {
            let found = document.findString(line, withOptions: []).map { $0.bounds(for: page).midY }
                .first { $0 <= cursor + 2 }
            #expect(found != nil, "“\(line)” is missing or out of order")
            if let found { cursor = found }
        }
        let signature = document.findString("Jordan Rivera", withOptions: []).map { $0.bounds(for: page).midY }
        #expect(signature.count == 2 && (signature.min() ?? 0) < cursor)  // signed under the sign-off
    }

    /// Paragraphs are data the template reads, never Typst source.
    @Test func typstMarkupInALetterPrintsLiterally() async throws {
        let markup = #"I cut costs 30% with #fast *builds* and $5 [templates] <tags> @refs #panic("no")"#
        let rendered = try await renderer().render(.letter(LetterDocument(letter([markup, "Second.", "Third."]))))
        let text = normalized(try #require(PDFDocument(data: rendered.data)?.string))
        #expect(text.contains(markup))
    }
}
