import Foundation
import PDFKit
import Tailoring

/// What the Harvard template records as it lays a resume out (`<kairos-layout>`, read with
/// `typst eval`). Lengths are in points.
public struct ResumeLayout: Decodable, Sendable, Equatable {
    public struct Bullet: Decodable, Sendable, Equatable {
        /// "experience" or "projects".
        public var section: String
        public var item: Int
        public var bullet: Int
        public var lines: Int
        /// Its width set on one line, and its characters.
        public var width: Double
        public var characters: Int?
    }

    public struct End: Decodable, Sendable, Equatable {
        public var page: Int
        public var y: Double
    }

    public var column: Double
    /// From one line of body text to the next.
    public var step: Double
    public var top: Double
    public var bottom: Double
    /// Where the resume ends.
    public var end: End
    public var bullets: [Bullet]

    static let expression = "query(<kairos-layout>).map(it => it.value)"

    /// For the fitter. A bullet's last line is estimated from its one-line width, so wrapped lines
    /// count as full: a slight underestimate, since a line breaks before a word that won't fit.
    public var pageLayout: PageLayout {
        func entries(_ kind: String) -> [[PageLayout.Bullet]] {
            let mine = bullets.filter { $0.section == kind }
            let count = (mine.map(\.item).max() ?? -1) + 1
            return (0..<count).map { item in
                mine.filter { $0.item == item }.sorted { $0.bullet < $1.bullet }.map { bullet in
                    let rest = bullet.width - Double(bullet.lines - 1) * column
                    let perLine = bullet.characters.flatMap {
                        bullet.width > 0 ? Double($0) * column / bullet.width : nil
                    }
                    return PageLayout.Bullet(
                        lines: bullet.lines, lastLineFill: min(1, max(0, rest / column)), lineCharacters: perLine)
                }
            }
        }
        return PageLayout(
            pages: end.page, linesPerPage: (bottom - top) / step, freeLines: max(0, (bottom - end.y) / step),
            experience: entries("experience"), projects: entries("projects"))
    }
}

/// A PDF, its page count and, for a resume, how it fills its pages.
public struct RenderedPDF: Sendable, Equatable {
    public let data: Data
    public let pageCount: Int
    public let layout: ResumeLayout?

    public init(data: Data, pageCount: Int, layout: ResumeLayout? = nil) {
        self.data = data
        self.pageCount = pageCount
        self.layout = layout
    }

    public var pageLayout: PageLayout { layout?.pageLayout ?? PageLayout(pages: pageCount) }
}

/// Prints resumes and letters with the bundled templates, which are vendored and never fetched.
public struct ResumeRenderer: Sendable {
    public let runner: TypstRunner

    public init(runner: TypstRunner) {
        self.runner = runner
    }

    /// The renderer over a typst binary, when there is one: the app passes the one in its bundle.
    public init?(typst: URL?) {
        guard let typst, FileManager.default.isExecutableFile(atPath: typst.path) else { return nil }
        self.init(runner: TypstRunner(executable: typst))
    }

    /// A resume with its measured layout. `createdAt` fixes the PDF's creation date, so the same
    /// document gives the same bytes.
    public func render(_ document: ResumeDocument, createdAt: Date? = nil) async throws(RenderError) -> RenderedPDF {
        let data = try encode(document)
        let source = try Self.template("harvard")
        let pdf = try await compile(source, data: data, createdAt: createdAt)
        let value = try await runner.evaluate(ResumeLayout.expression, template: source, data: data)
        guard let layout = try? JSONDecoder().decode([ResumeLayout].self, from: value).first else {
            throw .compile("the template's layout couldn't be read")
        }
        return RenderedPDF(data: pdf.data, pageCount: pdf.pageCount, layout: layout)
    }

    /// A build's resume, measured: what the page fitter calls.
    public func measure(_ resume: TailoredResume) async throws(RenderError) -> PageLayout {
        try await render(ResumeDocument(resume)).pageLayout
    }

    public func render(letter: LetterDocument, createdAt: Date? = nil) async throws(RenderError) -> RenderedPDF {
        try await compile(Self.template("cover"), data: try encode(letter), createdAt: createdAt)
    }

    private func encode(_ value: some Encodable) throws(RenderError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .workspace("the document couldn't be encoded: \(error.localizedDescription)")
        }
    }

    private func compile(_ template: String, data: Data, createdAt: Date?) async throws(RenderError) -> RenderedPDF {
        let pdf = try await runner.compile(template: template, data: data, createdAt: createdAt)
        guard let pages = PDFDocument(data: pdf)?.pageCount else {
            throw .compile("typst wrote a PDF PDFKit can't read")
        }
        return RenderedPDF(data: pdf, pageCount: pages)
    }

    static func template(_ name: String) throws(RenderError) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "typ", subdirectory: "Templates"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw .workspace("the \(name) template is missing from the bundle") }
        return text
    }
}
