import Foundation
import Tailoring

/// Something to print: a build's resume or its cover letter.
public enum Printable: Sendable, Equatable {
    case resume(ResumeDocument)
    case letter(LetterDocument)
}

extension ResumeRenderer {
    public func render(_ printable: Printable, createdAt: Date? = nil) async throws(RenderError) -> RenderedPDF {
        switch printable {
        case .resume(let document): try await render(document, createdAt: createdAt)
        case .letter(let letter): try await render(letter: letter, createdAt: createdAt)
        }
    }
}

/// What `cover.typ` reads, as JSON: a cover letter that's already final text (SPEC §5.3, Cover
/// letter), laid out on one page under the same header as the resume.
public struct LetterDocument: Codable, Sendable, Equatable {
    public var header: ResumeDocument.Header
    public var date: String
    /// The lines under the date: "Hiring team", then the company.
    public var recipient: [String]
    /// "Re: Backend Developer II".
    public var subject: String?
    public var greeting: String
    public var paragraphs: [String]
    public var closing: String
    public var signature: String
    public var style: ResumeDocument.Style

    public init(_ letter: CoverLetter, style: ResumeDocument.Style = .init(fontSize: 11, margin: 1)) {
        header = ResumeDocument.Header(
            name: letter.header.name,
            contact: ResumeDocument.ContactItem.harvardOrder(
                letter.header.contact.map { ResumeDocument.ContactItem(text: $0.text, url: $0.url) }))
        date = letter.date
        recipient = ["Hiring team", letter.company]
        subject = letter.jobTitle.isEmpty ? nil : "Re: \(letter.jobTitle)"
        greeting = letter.greeting
        paragraphs = letter.paragraphs
        closing = letter.closing
        signature = letter.signature
        self.style = style
    }
}
