import CoreGraphics
import Foundation
import PDFKit
import Tailoring
import Testing

@testable import Render

/// Whitespace collapsed, so line breaks PDFKit invents don't matter.
private func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// The fonts a PDF's first page uses, by their PostScript names without the subset prefix.
private func fonts(in data: Data) throws -> Set<String> {
    let provider = try #require(CGDataProvider(data: data as CFData))
    let document = try #require(CGPDFDocument(provider))  // kept alive while its dictionaries are read
    let page = try #require(document.page(at: 1)?.dictionary)
    var resources: CGPDFDictionaryRef?
    var fonts: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources,
        CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts
    else { return [] }
    var names = Set<String>()
    CGPDFDictionaryApplyBlock(
        fonts,
        { _, object, _ in
            var font: CGPDFDictionaryRef?
            var name: UnsafePointer<CChar>?
            if CGPDFObjectGetValue(object, .dictionary, &font), let font,
                CGPDFDictionaryGetName(font, "BaseFont", &name),
                let name
            {
                let full = String(cString: name)
                let base = String(full.split(separator: "+").last ?? Substring(full))
                names.insert(base.hasSuffix("-Identity-H") ? String(base.dropLast(11)) : base)
            }
            return true
        }, nil)
    return withExtendedLifetime(document) { names }
}

/// Dark pixels an icon leaves in the 11 pt before its item, at 2×. Calibrated on a real resume
/// (2026-10-21): icons left 107 to 197; the same strip in the Classic template, which has no icons,
/// left 45 to 60 from the end of the item before.
private let iconInk = 85

/// Dark pixels in `rect` (page points) when the page is drawn at 2×.
private func ink(in rect: CGRect, on page: PDFPage) -> Int {
    let box = page.bounds(for: .mediaBox)
    let scale: CGFloat = 2
    let width = Int(box.width * scale)
    let height = Int(box.height * scale)
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return 0 }
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
    var dark = 0
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) where pixels[(height - 1 - y) * width + x] < 128 {
            dark += 1
        }
    }
    return dark
}

@Suite("Harvard template", .enabled(if: TypstBinary.url != nil, "Run scripts/fetch-typst.sh first"))
struct HarvardTemplateTests {
    func renderer() throws -> ResumeRenderer {
        ResumeRenderer(runner: TypstRunner(executable: try #require(TypstBinary.url)))
    }

    func render(_ document: ResumeDocument = jordan()) async throws -> (RenderedPDF, PDFDocument, PDFPage) {
        let rendered = try await renderer().render(document, template: .harvard)
        let pdf = try #require(PDFDocument(data: rendered.data))
        return (rendered, pdf, try #require(pdf.page(at: 0)))
    }

    /// The golden file lists the resume's lines in reading order, as the classic test reads its own:
    /// each must appear, going down the page. Lines marked "~" (right-aligned) only need to be there.
    @Test func theSampleResumeRendersOnOnePageInOrder() async throws {
        let (rendered, document, page) = try await render()
        #expect(rendered.pageCount == 1)
        let text = normalized(try #require(document.string))
        let golden = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Fixtures/render/harvard-golden.txt"), encoding: .utf8)
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

    /// Small caps change how the name and headings look, not their letters: a parser reads
    /// "Experience", as typed.
    @Test func smallCapsKeepTheTypedLetters() async throws {
        let text = normalized(try #require(try await render().1.string))
        #expect(text.hasPrefix("Jordan Rivera"))
        for heading in ["Summary", "Experience", "Projects", "Education", "Skills", "Certifications", "Languages"] {
            #expect(text.contains(heading), "\(heading) is missing")
        }
        #expect(!text.contains("EXPERIENCE"))
    }

    /// Each contact item has its icon drawn just before it. The icons are drawings, so the PDF's
    /// text holds only the items, with no symbols from an icon font, and the only fonts are the
    /// text's.
    @Test func contactIconsAreDrawingsNotText() async throws {
        let (rendered, document, page) = try await render()
        let text = try #require(document.string)
        let stray = text.unicodeScalars.filter {
            (0xE000...0xF8FF).contains($0.value) || $0.value == 0xFFFD || $0.properties.generalCategory == .otherSymbol
        }
        #expect(stray.isEmpty, "stray symbols: \(stray.map { String(format: "U+%04X", $0.value) })")
        let used = try fonts(in: rendered.data)
        #expect(used == ["NewCM10-Regular", "NewCM10-Bold", "NewCM10-Italic"])
        for item in ["jordan.rivera@example.com", "(416) 555-0123", "linkedin.com/in/jordan-rivera"] {
            let bounds = try #require(document.findString(item, withOptions: []).first?.bounds(for: page), "\(item)")
            let before = CGRect(x: bounds.minX - 13, y: bounds.minY, width: 11, height: bounds.height)
            #expect(ink(in: before, on: page) > iconInk, "no icon before \(item)")
        }
        // The check can fail: Classic, which has no icons, stays under the line.
        let classic = try #require(PDFDocument(data: try await renderer().render(jordan(), template: .classic).data))
        let classicPage = try #require(classic.page(at: 0))
        let linkedIn = try #require(
            classic.findString("linkedin.com/in/jordan-rivera", withOptions: []).first?.bounds(for: classicPage))
        let strip = CGRect(x: linkedIn.minX - 13, y: linkedIn.minY, width: 11, height: linkedIn.height)
        #expect(ink(in: strip, on: classicPage) <= iconInk)
        // The place in the header has its pin.
        let places = document.findString("Toronto, ON", withOptions: []).map { $0.bounds(for: page) }
        let header = try #require(places.max { $0.midY < $1.midY })
        #expect(
            ink(in: CGRect(x: header.minX - 13, y: header.minY, width: 11, height: header.height), on: page) > iconInk)
    }

    /// Links stay links: email, LinkedIn and the phone number when it has one.
    @Test func contactLinksAreClickable() async throws {
        var document = jordan()
        document.header.contact[1] = .init(text: "(416) 555-0123", url: "tel:+14165550123")
        let (_, pdf, page) = try await render(document)
        let links = Set(page.annotations.compactMap(\.url?.absoluteString))
        #expect(
            links == [
                "mailto:jordan.rivera@example.com", "tel:+14165550123", "https://www.linkedin.com/in/jordan-rivera",
            ])
        #expect(pdf.pageCount == 1)
    }

    @Test func sectionOrderAndVisibilityAreInputs() async throws {
        var document = jordan()
        let education = try #require(document.sections.firstIndex { $0.kind == .education })
        document.sections.insert(document.sections.remove(at: education), at: 0)
        document.sections[document.sections.firstIndex { $0.kind == .skills }!].visible = false
        let text = normalized(try #require(try await render(document).1.string))
        let educationAt = try #require(text.range(of: "Education")?.lowerBound)
        let experienceAt = try #require(text.range(of: "Experience")?.lowerBound)
        #expect(educationAt < experienceAt)
        #expect(!text.contains("Skills") && !text.contains("Infrastructure"))
    }

    /// Content is data the template reads, never Typst source, so markup characters print as typed,
    /// in every place this template sets text differently: italic lines, the project stack, links.
    @Test func typstMarkupInContentPrintsLiterally() async throws {
        let markup = #"#panic("no") *bold* _it_ $x$ [b] <l> @r \e"#
        var document = jordan()
        document.header.contact[0] = .init(text: markup, url: "mailto:jordan.rivera@example.com")
        document.sections[1].items[0].subtitle = markup
        document.sections[1].items[0].location = markup
        document.sections[2].items[0].subtitle = markup
        document.sections[1].items[0].bullets = [markup]
        let text = try #require(try await render(document).1.string)
        #expect(text.components(separatedBy: markup).count - 1 == 5)
    }

    @Test func itIsSetInNewComputerModernAndReproducible() async throws {
        let renderer = try renderer()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try await renderer.render(jordan(), template: .harvard, createdAt: at)
        let second = try await renderer.render(jordan(), template: .harvard, createdAt: at)
        #expect(first.data == second.data)
        #expect(first.data.range(of: Data("NewCM10-Regular".utf8)) != nil)
    }

    /// Builds print with the standard template at its size, and the letter shares its header.
    @Test func buildsAndLettersPrintInTheHarvardStyle() async throws {
        #expect(ResumeTemplate.standard == .harvard)
        #expect(ResumeTemplate.harvard.style == ResumeDocument.Style(fontSize: 10, margin: 0.6))
        let resume = TailoredResume(header: .init(name: "Jordan Rivera"), summary: "Backend developer.")
        #expect(ResumeDocument(resume).style == ResumeTemplate.harvard.style)
        let printed = try await renderer().render(.resume(ResumeDocument(resume)))
        let resumeFonts = try fonts(in: printed.data)
        #expect(resumeFonts.contains("NewCM10-Regular"))

        let letter = CoverLetter(
            header: .init(
                name: "Jordan Rivera",
                contact: [
                    .init(text: "jordan.rivera@example.com", url: "mailto:jordan.rivera@example.com"),
                    .init(text: "Toronto, ON"),
                ]),
            date: "October 20, 2026", company: "Northline Freight", jobTitle: "Backend Developer II",
            greeting: "Dear Northline Freight hiring team,", paragraphs: ["One.", "Two.", "Three."],
            closing: "Sincerely,", signature: "Jordan Rivera")
        let letterPDF = try await renderer().render(.letter(LetterDocument(letter)))
        let letterFonts = try fonts(in: letterPDF.data)
        #expect(letterFonts.contains("NewCM10-Regular"))
        let letterDocument = try #require(PDFDocument(data: letterPDF.data))
        let page = try #require(letterDocument.page(at: 0))
        let email = try #require(
            letterDocument.findString("jordan.rivera@example.com", withOptions: []).first?.bounds(for: page))
        #expect(ink(in: CGRect(x: email.minX - 13, y: email.minY, width: 11, height: email.height), on: page) > iconInk)
    }
}

@Suite("Contact kinds")
struct ContactKindTests {
    static let cases: [(text: String, url: String?, kind: ResumeDocument.ContactItem.Kind)] = [
        ("jordan.rivera@example.com", "mailto:jordan.rivera@example.com", .email),
        ("(416) 555-0123", "tel:+14165550123", .phone),
        ("(416) 555-0123", nil, .phone),  // a build from before phone numbers were links
        ("linkedin.com/in/jordan-rivera", "https://www.linkedin.com/in/jordan-rivera", .linkedIn),
        ("github.com/jrivera", "https://github.com/jrivera", .gitHub),
        ("jrivera.github.io", "https://jrivera.github.io", .website),
        ("jordanrivera.dev", "https://jordanrivera.dev", .website),
        ("Toronto, ON", nil, .location),
    ]

    /// The icon comes from the link, so a stored build's contact line gets its icons too.
    @Test func eachItemsKindComesFromItsLink() {
        for item in Self.cases {
            #expect(ResumeDocument.ContactItem(text: item.text, url: item.url).kind == item.kind, "\(item.text)")
        }
        #expect(ResumeDocument.ContactItem(text: "Toronto, ON", kind: .website).kind == .website)
    }
}
