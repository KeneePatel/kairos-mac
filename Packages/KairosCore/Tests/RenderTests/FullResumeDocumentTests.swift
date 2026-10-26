import Foundation
import PDFKit
import Tailoring
import Testing

@testable import Render

private func normalized(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

private func month(_ year: Int, _ month: Int) -> TailoredResume.Period.Month { .init(year: year, month: month) }

/// Jordan's whole master resume, flattened (fixtures only): a summary, a degree still under way,
/// a linked project, certificates, languages and two sections of their own.
func jordanEverything(bulletsPerRole: Int = 2) -> FullResume {
    let lines = (1...bulletsPerRole).map {
        "Bullet \($0): built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms, then moved it"
    }
    return FullResume(
        header: .init(
            name: "Jordan Rivera", headline: "Backend Developer",
            contact: [
                .init(text: "jordan.rivera@example.com", url: "mailto:jordan.rivera@example.com"),
                .init(text: "(416) 555-0123", url: "tel:+14165550123"), .init(text: "Toronto, ON"),
            ]),
        summary: "Backend developer with 5 years building event-driven services.",
        skills: [
            SkillGroup(label: "Languages", skills: ["Go", "Java"]),
            SkillGroup(label: FullResume.canDiscussLabel, skills: ["Rust"]),
        ],
        experience: [
            .init(
                title: "Software Developer, Backend", organization: "Harbourline Logistics", location: "Toronto, ON",
                period: .init(start: month(2022, 3), isCurrent: true), bullets: lines),
            .init(
                title: "Junior Developer", organization: "Rivet Studio",
                period: .init(start: month(2020, 6), end: month(2022, 2)), bullets: lines),
        ],
        projects: [
            .init(
                title: "Dockyard", organization: "Creator · Go, Docker", period: .init(start: month(2023, 5)),
                url: "https://dockyard.dev", bullets: ["Finds and removes dangling Docker images and volumes."])
        ],
        education: [
            .init(
                title: "BMath, Computer Science", organization: "University of Waterloo", location: "Waterloo, ON",
                period: .init(start: month(2015, 9), end: month(2019, 4)), bullets: ["Coursework: Compilers"]),
            .init(
                title: "Certificate in Data", organization: "Night School",
                period: .init(start: month(2026, 1), end: month(2027, 6))),
        ],
        certifications: [
            .init(
                title: "AWS Solutions Architect – Associate", organization: "AWS", period: .init(start: month(2024, 3)))
        ],
        languages: "English (native), French (conversational)",
        additional: [
            .init(
                title: "Additional Experience",
                entries: [
                    .init(
                        title: "Barista, Beanery (Toronto, ON)",
                        period: .init(start: month(2017, 5), end: month(2018, 8)),
                        bullets: ["Opened the shop on weekends."])
                ]),
            .init(title: "Talks", entries: [.init(title: "Go meetup: event pipelines")]),
            .init(title: "Nothing here", entries: []),
        ],
        version: 12)
}

@Suite("Full resume document")
struct FullResumeDocumentTests {
    let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 26))!

    @Test func everySectionInHarvardOrder() {
        let document = ResumeDocument(jordanEverything(), now: now)
        #expect(
            document.sections.map(\.kind) == [
                .summary, .education, .skills, .experience, .projects, .certifications, .custom, .custom,
            ])
        #expect(
            document.sections.map(\.title) == [
                "Summary", "Education", "Skills", "Experience", "Projects", "Certifications", "Additional Experience",
                "Talks",
            ])
        #expect(document.sections[0].text == "Backend developer with 5 years building event-driven services.")
        #expect(document.template == .harvard && document.style == ResumeTemplate.harvard.style)
        #expect(document.header.contact.map(\.text) == ["Toronto, ON", "(416) 555-0123", "jordan.rivera@example.com"])
    }

    @Test func skillsEndWithCanDiscussAndALanguageRow() {
        let skills = ResumeDocument(jordanEverything(), now: now).sections[2].groups
        #expect(skills.map(\.label) == ["Languages", "Can discuss", "Language"])
        #expect(skills[2].items == ["English (native), French (conversational)"])
    }

    @Test func datesAreSpelledOutAndADegreeUnderWayIsExpected() {
        let document = ResumeDocument(jordanEverything(), now: now)
        let education = document.sections[1].items
        #expect(education[0].dates == "September 2015 – April 2019")
        #expect(education[0].bullets == ["Coursework: Compilers"])
        #expect(education[1].dates == "January 2026 – June 2027 (Expected)")
        #expect(document.sections[3].items[0].dates == "March 2022 – Present")
        let certificate = document.sections[5].items[0]
        #expect(certificate.dates == "March 2024")
        #expect(certificate.title == "AWS Solutions Architect – Associate · AWS" && certificate.subtitle == nil)
    }

    @Test func aProjectTitleLinksToItsPageAndEveryBulletStays() {
        let document = ResumeDocument(jordanEverything(bulletsPerRole: 5), now: now)
        let project = document.sections[4].items[0]
        #expect(project.url == "https://dockyard.dev")
        #expect(project.subtitle == "Creator · Go, Docker")
        #expect(document.sections[3].items.map(\.bullets.count) == [5, 5])
        #expect(document.sections[6].items[0].bullets == ["Opened the shop on weekends."])
        #expect(document.sections[3].items[0].url == nil)
    }

    @Test func anEmptyResumeHasNoSections() {
        let document = ResumeDocument(FullResume(header: .init(name: "Jordan Rivera")), now: now)
        #expect(document.sections.isEmpty)
        #expect(document.header.name == "Jordan Rivera")
    }
}

@Suite("Full resume PDF", .enabled(if: TypstBinary.url != nil, "Run scripts/fetch-typst.sh first"))
struct FullResumePDFTests {
    /// With no page budget, a long resume runs onto a second page with nothing left out, and the
    /// project's title is a link beside the contact line's.
    @Test func everythingRendersAcrossPages() async throws {
        let renderer = ResumeRenderer(runner: TypstRunner(executable: try #require(TypstBinary.url)))
        let rendered = try await renderer.render(ResumeDocument(jordanEverything(bulletsPerRole: 12), now: Date()))
        let pdf = try #require(PDFDocument(data: rendered.data))
        #expect(rendered.pageCount >= 2 && pdf.pageCount == rendered.pageCount)
        let text = normalized(try #require(pdf.string))
        #expect(text.contains("SUMMARY") && text.contains("ADDITIONAL EXPERIENCE") && text.contains("TALKS"))
        #expect(text.contains("Can discuss: Rust"))
        #expect(text.contains("AWS Solutions Architect – Associate · AWS March 2024"))
        #expect(text.contains("Bullet 12: built an event pipeline"))
        #expect(text.contains("Opened the shop on weekends."))
        #expect(text.contains("Go meetup: event pipelines"))
        let links = Set(
            (0..<pdf.pageCount).compactMap(pdf.page).flatMap(\.annotations).compactMap(\.url?.absoluteString))
        #expect(links.contains("https://dockyard.dev") && links.contains("mailto:jordan.rivera@example.com"))
    }
}
