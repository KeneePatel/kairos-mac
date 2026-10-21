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

private func bullet(_ text: String) -> TailoredBullet { TailoredBullet(text: text, sourceIDs: [UUID()]) }

private func month(_ year: Int, _ month: Int) -> TailoredResume.Period.Month { .init(year: year, month: month) }

/// The design's sample persona as a build (fixtures only), with everything Harvard rearranges: a
/// summary, abbreviated date text (each entry's dates are also kept as numbers), a degree shown in
/// years and spoken languages.
func jordanBuild() -> TailoredResume {
    TailoredResume(
        header: .init(
            name: "Jordan Rivera",
            contact: [
                .init(text: "jordan.rivera@example.com", url: "mailto:jordan.rivera@example.com"),
                .init(text: "(416) 555-0123", url: "tel:+14165550123"),
                .init(text: "linkedin.com/in/jordan-rivera", url: "https://www.linkedin.com/in/jordan-rivera"),
                .init(text: "Toronto, ON"),
            ]),
        summary: "Backend developer with 5 years building event-driven services for logistics and fintech.",
        skills: [
            SkillGroup(label: "Languages", skills: ["Go", "Java", "Python", "SQL"]),
            SkillGroup(label: "Infrastructure", skills: ["Kubernetes", "Docker", "Terraform"]),
        ],
        experience: [
            .init(
                entryID: UUID(), title: "Software Developer, Backend", organization: "Harbourline Logistics",
                location: "Toronto, ON", dates: "Mar 2022 – Present",
                period: .init(start: month(2022, 3), isCurrent: true),
                bullets: [
                    bullet("Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms."),
                    bullet("Onboarded 11 carriers in 4 days instead of 3 weeks with a gRPC integration kit."),
                ]),
            .init(
                entryID: UUID(), title: "Junior Developer", organization: "Rivet Studio", location: "Toronto, ON",
                dates: "Jun 2020 – Feb 2022", period: .init(start: month(2020, 6), end: month(2022, 2)),
                bullets: [bullet("Shipped REST APIs in Django and PostgreSQL for 30+ client projects.")]),
        ],
        projects: [
            .init(
                entryID: UUID(), title: "Dockyard", organization: "Go", dates: "May 2023 – Present",
                period: .init(start: month(2023, 5), isCurrent: true),
                bullets: [bullet("Finds and removes dangling Docker images and volumes; 400+ stars.")])
        ],
        education: [
            .init(
                entryID: UUID(), title: "BMath, Computer Science", organization: "University of Waterloo",
                location: "Waterloo, ON", dates: "2015 – 2019",
                period: .init(start: month(2015, 9), end: month(2019, 4)))
        ],
        certifications: [
            .init(
                entryID: UUID(), title: "AWS Solutions Architect – Associate", dates: "2024",
                period: .init(start: month(2024, 3)))
        ],
        languages: "English (native), French (conversational)")
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

/// Harvard's arrangement, decided in Swift before any template runs.
@Suite("Harvard arrangement")
struct HarvardArrangementTests {
    /// Education, then Skills ("for tech resumes"), Experience, Projects, Certifications; no summary;
    /// spoken languages as Harvard's "Language" row; the contact line in its samples' order.
    @Test func aBuildIsArrangedTheWayHarvardLaysItOut() {
        let document = ResumeDocument(jordanBuild(), for: .harvard)
        #expect(document.template == .harvard && document.style == ResumeTemplate.harvard.style)
        #expect(document.sections.map(\.kind) == [.education, .skills, .experience, .projects, .certifications])
        #expect(document.sections.allSatisfy { $0.text == nil })  // no summary
        #expect(document.sections[1].groups.map(\.label) == ["Languages", "Infrastructure", "Language"])
        #expect(document.sections[1].groups.last?.items == ["English (native), French (conversational)"])
        #expect(
            document.header.contact.map(\.text) == [
                "Toronto, ON", "(416) 555-0123", "jordan.rivera@example.com", "linkedin.com/in/jordan-rivera",
            ])
        // Month and year on both ends, education included: parsers read these exactly.
        #expect(document.sections[0].items[0].dates == "September 2015 – April 2019")
        #expect(document.sections[2].items.map(\.dates) == ["March 2022 – Present", "June 2020 – February 2022"])
        #expect(document.sections[3].items[0].dates == "May 2023 – Present")
        #expect(document.sections[4].items[0].dates == "March 2024")
        #expect(document.sections[2].items[0].subtitle == "Harbourline Logistics")
    }

    /// Harvard: "Don't abbreviate". Every month comes with its year, so a range within one year
    /// still names it twice: a parser stores a month it can't date, or a year alone, as January.
    @Test func datesAreWrittenInFullWithAYearOnEveryMonth() {
        let periods: [(TailoredResume.Period, String?)] = [
            (.init(start: month(2025, 5), end: month(2025, 8)), "May 2025 – August 2025"),
            (.init(start: month(2024, 1), end: month(2025, 8)), "January 2024 – August 2025"),
            (.init(start: month(2024, 9), isCurrent: true), "September 2024 – Present"),
            (.init(start: month(2024, 3)), "March 2024"), (.init(end: month(2025, 8)), "August 2025"),
            (.init(start: month(2025, 8), end: month(2025, 8)), "August 2025"), (.init(), nil),
            (.init(start: month(2025, 13)), "2025"),
        ]
        for (period, text) in periods { #expect(HarvardDates.text(period) == text, "\(period)") }
    }

    /// A build made before dates were kept as numbers: its text is spelled out, and a year alone
    /// stays a year; there's no month to add.
    @Test func anOlderBuildSpellsOutItsStoredText() {
        var build = jordanBuild()
        build.experience[0].period = nil
        build.education[0].period = nil
        let document = ResumeDocument(build, for: .harvard)
        #expect(document.sections[2].items[0].dates == "March 2022 – Present")
        #expect(document.sections[0].items[0].dates == "2015 – 2019")
        let spelled = [
            ("May 2025 – Aug 2025", "May 2025 – August 2025"), ("Sept. 2024", "September 2024"), ("2024", "2024"),
        ]
        for (dates, text) in spelled { #expect(HarvardDates.spelledOut(dates) == text, "\(dates)") }
    }

    /// Classic keeps the Build mockup's arrangement, summary first.
    @Test func classicKeepsItsOwnArrangement() {
        let build = jordanBuild()
        let document = ResumeDocument(build, for: .classic)
        #expect(document == ResumeDocument(build, style: ResumeTemplate.classic.style))
        #expect(document.template == .classic && document.sections.first?.kind == .summary)
        #expect(ResumeTemplate.classic.hasSummary && !ResumeTemplate.harvard.hasSummary)
    }

    /// The letter's contact line follows the same order.
    @Test func theLetterUsesHarvardsContactOrder() {
        let letter = CoverLetter(
            header: jordanBuild().header, date: "October 21, 2026", company: "Northline Freight",
            jobTitle: "Backend Developer II", greeting: "Dear Northline Freight hiring team,",
            paragraphs: ["One.", "Two.", "Three."], closing: "Sincerely,", signature: "Jordan Rivera")
        #expect(LetterDocument(letter).header.contact.first?.text == "Toronto, ON")
    }
}

@Suite("Harvard template", .enabled(if: TypstBinary.url != nil, "Run scripts/fetch-typst.sh first"))
struct HarvardTemplateTests {
    func renderer() throws -> ResumeRenderer {
        ResumeRenderer(runner: TypstRunner(executable: try #require(TypstBinary.url)))
    }

    func render(_ document: ResumeDocument = ResumeDocument(jordanBuild(), for: .harvard)) async throws -> (
        RenderedPDF, PDFDocument, PDFPage
    ) {
        let rendered = try await renderer().render(document)
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
        #expect(!text.contains("Backend developer with 5 years"))  // the summary isn't printed
    }

    /// Harvard: "font size should be between 10 and 12 point and kept consistent throughout the
    /// document". Name, headings and body are all 11 pt.
    @Test func oneSizeThroughout() async throws {
        let page = try await render().2
        let text = try #require(page.attributedString)
        var sizes = Set<CGFloat>()
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? NSFont { sizes.insert(font.pointSize.rounded()) }
        }
        #expect(sizes == [11])
    }

    /// Harvard: "Margins should be equal all the way around the page and should be at least three
    /// quarters of an inch".
    @Test func marginsAreEqualAndAtLeastThreeQuartersOfAnInch() async throws {
        let page = try await render().2
        let box = page.bounds(for: .mediaBox)
        let ink = (0..<(page.string?.count ?? 0)).map { page.characterBounds(at: $0) }.filter {
            $0.width > 0 && $0.height > 0
        }
        let left = try #require(ink.map(\.minX).min())
        let right = box.width - (try #require(ink.map(\.maxX).max()))
        let top = box.height - (try #require(ink.map(\.maxY).max()))
        #expect(left >= 53.5 && right >= 53.5 && top >= 53.5, "left \(left), right \(right), top \(top)")
        #expect(abs(left - right) < 1.5)
    }

    /// "A common, easy to read font": Liberation Serif, metric-compatible with the Times New Roman of
    /// Harvard's sample, and nothing else. The text is clean for parsers: no symbols, no ligatures.
    @Test func itIsSetInATimesStyleFontAndNothingElse() async throws {
        let (rendered, document, _) = try await render()
        let used = try fonts(in: rendered.data)
        #expect(used == ["LiberationSerif", "LiberationSerif-Bold", "LiberationSerif-Italic"])
        let text = try #require(document.string)
        let odd = text.unicodeScalars.filter {
            (0xE000...0xF8FF).contains($0.value) || (0xFB00...0xFB06).contains($0.value) || $0.value == 0xFFFD
        }
        #expect(odd.isEmpty)
    }

    /// The contact line is plain text, as in Harvard's samples, and every link still works.
    @Test func theContactLineIsPlainTextThatLinks() async throws {
        let (_, document, page) = try await render()
        let text = normalized(try #require(document.string))
        #expect(
            text.contains(
                "JORDAN RIVERA Toronto, ON | (416) 555-0123 | jordan.rivera@example.com | linkedin.com/in/jordan-rivera"
            ))
        let links = Set(page.annotations.compactMap(\.url?.absoluteString))
        #expect(
            links == [
                "mailto:jordan.rivera@example.com", "tel:+14165550123", "https://www.linkedin.com/in/jordan-rivera",
            ])
    }

    @Test func sectionOrderAndVisibilityAreInputs() async throws {
        var document = ResumeDocument(jordanBuild(), for: .harvard)
        document.sections.swapAt(0, 2)
        document.sections[document.sections.firstIndex { $0.kind == .skills }!].visible = false
        let text = normalized(try #require(try await render(document).1.string))
        let educationAt = try #require(text.range(of: "EDUCATION")?.lowerBound)
        let experienceAt = try #require(text.range(of: "EXPERIENCE")?.lowerBound)
        #expect(experienceAt < educationAt)
        #expect(!text.contains("SKILLS") && !text.contains("Infrastructure"))
    }

    /// Content is data the template reads, never Typst source, so markup characters print as typed,
    /// in every place this template sets text: organization, title, place, project stack, bullets
    /// and the contact line.
    @Test func typstMarkupInContentPrintsLiterally() async throws {
        let markup = #"#panic("no") *bold* _it_ $x$ [b] <l> @r \e"#
        var document = ResumeDocument(jordanBuild(), for: .harvard)
        document.header.contact[0] = .init(text: markup, url: "https://example.com")
        let experience = try #require(document.sections.firstIndex { $0.kind == .experience })
        let projects = try #require(document.sections.firstIndex { $0.kind == .projects })
        document.sections[experience].items[0].subtitle = markup
        document.sections[experience].items[0].title = markup
        document.sections[experience].items[0].location = markup
        document.sections[experience].items[0].bullets = [markup]
        document.sections[projects].items[0].subtitle = markup
        let text = try #require(try await render(document).1.string)
        #expect(text.components(separatedBy: markup).count - 1 == 6)
    }

    @Test func itIsReproducible() async throws {
        let renderer = try renderer()
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let document = ResumeDocument(jordanBuild(), for: .harvard)
        let first = try await renderer.render(document, createdAt: at)
        let second = try await renderer.render(document, createdAt: at)
        #expect(first.data == second.data)
    }

    /// Builds print with the standard template, and the letter shares its type and header.
    @Test func buildsAndLettersPrintInTheHarvardStyle() async throws {
        #expect(ResumeTemplate.standard == .harvard)
        #expect(ResumeTemplate.harvard.style == ResumeDocument.Style(fontSize: 11, margin: 0.75))
        let printed = try await renderer().render(.resume(ResumeDocument(jordanBuild(), for: .standard)))
        let resumeFonts = try fonts(in: printed.data)
        #expect(resumeFonts.contains("LiberationSerif"))

        let letter = CoverLetter(
            header: jordanBuild().header, date: "October 21, 2026", company: "Northline Freight",
            jobTitle: "Backend Developer II", greeting: "Dear Northline Freight hiring team,",
            paragraphs: ["One.", "Two.", "Three."], closing: "Sincerely,", signature: "Jordan Rivera")
        let letterPDF = try await renderer().render(.letter(LetterDocument(letter)))
        let letterFonts = try fonts(in: letterPDF.data)
        #expect(letterFonts.contains("LiberationSerif"))
        let letterText = normalized(try #require(PDFDocument(data: letterPDF.data)?.string))
        #expect(letterText.hasPrefix("Jordan Rivera Toronto, ON | (416) 555-0123 | jordan.rivera@example.com"))
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

    /// The kind comes from the link, so a stored build's contact line sorts the same way.
    @Test func eachItemsKindComesFromItsLink() {
        for item in Self.cases {
            #expect(ResumeDocument.ContactItem(text: item.text, url: item.url).kind == item.kind, "\(item.text)")
        }
        #expect(ResumeDocument.ContactItem(text: "Toronto, ON", kind: .website).kind == .website)
    }
}
