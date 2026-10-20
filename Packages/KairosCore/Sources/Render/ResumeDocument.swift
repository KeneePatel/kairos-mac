import Foundation
import PDFKit

/// What a resume template reads, as JSON (SPEC §5.6): a header from the contact block, then
/// sections in the order given, each shown only if `visible`. Everything is already final text:
/// templates lay it out and never decide content.
public struct ResumeDocument: Codable, Sendable, Equatable {
    public struct Header: Codable, Sendable, Equatable {
        public var name: String
        public var headline: String?
        /// Email, phone, links and city, already formatted, in order.
        public var contact: [ContactItem]

        public init(name: String, headline: String? = nil, contact: [ContactItem] = []) {
            self.name = name
            self.headline = headline
            self.contact = contact
        }
    }

    public struct ContactItem: Codable, Sendable, Equatable {
        public var text: String
        /// Makes the item a link in the PDF.
        public var url: String?

        public init(text: String, url: String? = nil) {
            self.text = text
            self.url = url
        }
    }

    public enum SectionKind: String, Codable, Sendable, CaseIterable {
        case summary, experience, projects, education, skills, certifications, languages, custom
    }

    public struct Section: Codable, Sendable, Equatable {
        public var kind: SectionKind
        public var title: String
        public var visible: Bool
        /// A paragraph, for the summary or a one-line section such as languages.
        public var text: String?
        public var items: [Item]
        /// Labelled lists, for skills.
        public var groups: [Group]

        public init(
            kind: SectionKind, title: String, visible: Bool = true, text: String? = nil, items: [Item] = [],
            groups: [Group] = []
        ) {
            self.kind = kind
            self.title = title
            self.visible = visible
            self.text = text
            self.items = items
            self.groups = groups
        }
    }

    /// One entry: a job, project, degree or certification.
    public struct Item: Codable, Sendable, Equatable {
        public var title: String
        public var subtitle: String?
        public var location: String?
        public var dates: String?
        public var bullets: [String]

        public init(
            title: String, subtitle: String? = nil, location: String? = nil, dates: String? = nil,
            bullets: [String] = []
        ) {
            self.title = title
            self.subtitle = subtitle
            self.location = location
            self.dates = dates
            self.bullets = bullets
        }
    }

    public struct Group: Codable, Sendable, Equatable {
        public var label: String
        public var items: [String]

        public init(label: String, items: [String]) {
            self.label = label
            self.items = items
        }
    }

    public struct Style: Codable, Sendable, Equatable {
        public enum Paper: String, Codable, Sendable {
            case usLetter = "us-letter"
            case a4
        }
        public var paper: Paper
        /// Body size in points.
        public var fontSize: Double
        /// Page margin in inches.
        public var margin: Double

        public init(paper: Paper = .usLetter, fontSize: Double = 10.5, margin: Double = 0.6) {
            self.paper = paper
            self.fontSize = fontSize
            self.margin = margin
        }
    }

    public var header: Header
    public var sections: [Section]
    public var style: Style

    public init(header: Header, sections: [Section], style: Style = Style()) {
        self.header = header
        self.sections = sections
        self.style = style
    }
}

/// A rendered PDF and its page count (SPEC §5.3, Render: the page budget is checked from it).
public struct RenderedPDF: Sendable, Equatable {
    public let data: Data
    public let pageCount: Int

    public init(data: Data, pageCount: Int) {
        self.data = data
        self.pageCount = pageCount
    }
}

/// The resume templates shipped in `Templates/`, vendored and never fetched (SPEC §5.6).
public enum ResumeTemplate: String, Sendable, CaseIterable {
    case classic

    public func source() throws(RenderError) -> String {
        try Self.source(named: rawValue)
    }

    /// A template file in `Templates/`, such as `cover` for the letter.
    static func source(named name: String) throws(RenderError) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "typ", subdirectory: "Templates"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw .workspace("the \(name) template is missing from the bundle") }
        return text
    }
}

/// Turns a `ResumeDocument` into a PDF with a template.
public struct ResumeRenderer: Sendable {
    public let runner: TypstRunner

    public init(runner: TypstRunner) {
        self.runner = runner
    }

    /// `createdAt` fixes the PDF's creation date, so the same document gives the same bytes.
    public func render(_ document: ResumeDocument, template: ResumeTemplate = .classic, createdAt: Date? = nil)
        async throws(RenderError) -> RenderedPDF
    {
        let data: Data
        do {
            data = try JSONEncoder().encode(document)
        } catch {
            throw .workspace("the resume couldn't be encoded: \(error.localizedDescription)")
        }
        return try await compile(template.source(), data: data, createdAt: createdAt)
    }

    /// A cover letter with `cover.typ`.
    public func render(letter: LetterDocument, createdAt: Date? = nil) async throws(RenderError) -> RenderedPDF {
        let data: Data
        do {
            data = try JSONEncoder().encode(letter)
        } catch {
            throw .workspace("the letter couldn't be encoded: \(error.localizedDescription)")
        }
        return try await compile(ResumeTemplate.source(named: "cover"), data: data, createdAt: createdAt)
    }

    private func compile(_ template: String, data: Data, createdAt: Date?) async throws(RenderError) -> RenderedPDF {
        let pdf = try await runner.compile(template: template, data: data, createdAt: createdAt)
        guard let pages = PDFDocument(data: pdf)?.pageCount else {
            throw .compile("typst wrote a PDF PDFKit can't read")
        }
        return RenderedPDF(data: pdf, pageCount: pages)
    }
}
