import Foundation
import MasterResume
import Testing

@testable import Tailoring

/// The whole master resume, flattened for the export (SPEC §5.10): every entry, every bullet,
/// nothing chosen or rewritten.
@Suite("Full resume")
struct FullResumeTests {
    /// Jordan's master resume with every kind of entry the editor offers.
    func everything() -> MasterResume {
        var resume = Sample.resume
        resume.header.email = "jordan.rivera@example.com"
        resume.header.phone = "+14165550123"
        resume.header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
        resume.header.city = "Toronto"
        resume.header.region = "ON"
        resume.header.headline = "Backend Developer"
        resume.header.highlights = "  Backend developer with 5 years building event-driven services.  "
        resume.entries = [
            Sample.harbourline,
            ResumeEntry(
                fields: .experience(
                    .init(
                        employer: "Campus Library", title: "Desk Assistant", location: "", employmentType: "Part-time")
                ),
                start: YearMonth(year: 2018, month: 9), end: YearMonth(year: 2019, month: 4),
                bullets: [ResumeBullet(text: "Shelved returns and ran the evening desk.")]),
            ResumeEntry(
                fields: .project(
                    .init(
                        name: "Dockyard", role: "Creator", tech: ["Go", "Docker"], projectURL: "https://dockyard.dev",
                        repoURL: "https://github.com/jordan/dockyard")),
                start: YearMonth(year: 2023, month: 1), isCurrent: true, bullets: [Sample.dockyard]),
            ResumeEntry(
                fields: .project(.init(name: "Ledger", tech: [], repoURL: "https://github.com/jordan/ledger")),
                bullets: [Sample.ledger]),
            ResumeEntry(
                fields: .education(
                    .init(
                        institution: "University of Waterloo", credential: "BMath", field: "Computer Science",
                        location: "Waterloo, ON", honours: "With Distinction",
                        coursework: ["Distributed Systems", "", "Compilers"])),
                start: YearMonth(year: 2015, month: 9), end: YearMonth(year: 2019, month: 4)),
            ResumeEntry(
                fields: .education(.init(institution: "Night School")), start: YearMonth(year: 2026, month: 1),
                isCurrent: true),
            ResumeEntry(
                fields: .certification(
                    .init(
                        name: "AWS Solutions Architect – Associate", issuer: "AWS",
                        credentialURL: "https://aws.example/c1")
                ), start: YearMonth(year: 2024, month: 3)),
            ResumeEntry(fields: .award(.init(title: "Dean's List", organization: "University of Waterloo"))),
            ResumeEntry(
                fields: .volunteering(.init(title: "Mentor", organization: "Code Club")),
                start: YearMonth(year: 2021, month: 1), isCurrent: true,
                bullets: [ResumeBullet(text: "Ran a weekly session for 12 kids.")]),
            ResumeEntry(
                fields: .publication(.init(title: "Queues at scale", organization: "ACM", url: "https://acm.example/q"))
            ),
            ResumeEntry(fields: .language(.init(language: "English", proficiency: .native))),
            ResumeEntry(fields: .language(.init(language: "French", proficiency: .conversational))),
            ResumeEntry(
                fields: .custom(.init(section: "Additional Experience", title: "Barista, Beanery (Toronto, ON)")),
                start: YearMonth(year: 2017, month: 5), end: YearMonth(year: 2018, month: 8),
                bullets: [ResumeBullet(text: "Opened the shop on weekends.")]),
            ResumeEntry(fields: .custom(.init(section: "Talks", title: "Go meetup: event pipelines"))),
            ResumeEntry(fields: .custom(.init(section: "Additional Experience", title: "Camp counsellor"))),
            ResumeEntry(fields: .custom(.init(section: " ", title: "Chess club"))),
        ]
        resume.skills = [
            Skill(name: "Go", category: "Languages"), Skill(name: "Java", category: "Languages"),
            Skill(name: "Kubernetes", category: "Cloud"),
            Skill(name: "Rust", category: "Languages", level: .canDiscuss),
            Skill(name: "Kafka"), Skill(name: "Terraform", category: "Cloud", level: .canDiscuss),
        ]
        return resume
    }

    @Test func theHeaderComesFromTheContactBlockByCode() {
        let full = FullResume(everything())
        #expect(full.header.name == "Jordan Rivera")
        #expect(full.header.headline == "Backend Developer")
        #expect(
            full.header.contact.map(\.text) == [
                "jordan.rivera@example.com", "(416) 555-0123", "linkedin.com/in/jordan-rivera", "Toronto, ON",
            ])
        #expect(full.summary == "Backend developer with 5 years building event-driven services.")
        #expect(full.version == 7)
    }

    @Test func aBlankHighlightsLineIsNoSummary() {
        var resume = everything()
        resume.header.highlights = " \n"
        #expect(FullResume(resume).summary == nil)
    }

    @Test func everyRoleKeepsEveryBulletAndItsEmploymentType() {
        let full = FullResume(everything())
        #expect(full.experience.map(\.title) == ["Software Developer, Backend", "Desk Assistant (Part-time)"])
        #expect(full.experience[0].organization == "Harbourline Logistics")
        #expect(full.experience[0].location == "Toronto, ON")
        #expect(full.experience[0].bullets == Sample.harbourline.bullets.map(\.text))
        #expect(full.experience[0].period == TailoredResume.Period(start: .init(year: 2022, month: 3), isCurrent: true))
        #expect(full.experience[1].location == nil)
    }

    @Test func aProjectShowsItsRoleStackAndPage() {
        let full = FullResume(everything())
        #expect(full.projects.map(\.title) == ["Dockyard", "Ledger"])
        #expect(full.projects[0].organization == "Creator · Go, Docker")
        #expect(full.projects[0].url == "https://dockyard.dev", "the live page before the repository")
        #expect(full.projects[0].bullets == [Sample.dockyard.text])
        #expect(full.projects[1].organization == nil)
        #expect(full.projects[1].url == "https://github.com/jordan/ledger")
        #expect(full.projects[1].period == nil)
    }

    @Test func aDegreeCarriesItsHonoursAndCoursework() {
        let full = FullResume(everything())
        #expect(full.education[0].title == "BMath, Computer Science, With Distinction")
        #expect(full.education[0].organization == "University of Waterloo")
        #expect(full.education[0].location == "Waterloo, ON")
        #expect(full.education[0].bullets == ["Coursework: Distributed Systems; Compilers"])
        #expect(full.education[1].title == "Night School", "a school alone is the title")
        #expect(full.education[1].organization == nil)
        #expect(full.education[1].period?.isCurrent == true)
    }

    @Test func certificatesAndLanguagesComeThrough() {
        let full = FullResume(everything())
        #expect(full.certifications.map(\.title) == ["AWS Solutions Architect – Associate"])
        #expect(full.certifications[0].organization == "AWS")
        #expect(full.certifications[0].url == "https://aws.example/c1")
        #expect(full.certifications[0].period == TailoredResume.Period(start: .init(year: 2024, month: 3)))
        #expect(full.languages == "English (native), French (conversational)")
    }

    @Test func skillsAreProvenByCategoryThenCanDiscuss() {
        let full = FullResume(everything())
        #expect(full.skills.map(\.label) == ["Languages", "Cloud", "Other", "Can discuss"])
        #expect(full.skills[0].skills == ["Go", "Java"])
        #expect(full.skills[2].skills == ["Kafka"], "an uncategorized skill")
        #expect(full.skills[3].skills == ["Rust", "Terraform"])
    }

    @Test func noCanDiscussSkillsMeansNoSuchGroup() {
        var resume = everything()
        resume.skills = [Skill(name: "Go", category: "Languages")]
        #expect(FullResume(resume).skills.map(\.label) == ["Languages"])
    }

    @Test func otherSectionsFollowInOrderWithYourOwnGroupedByName() {
        let full = FullResume(everything())
        #expect(
            full.additional.map(\.title) == [
                "Awards", "Volunteering", "Publications", "Additional Experience", "Talks", "Additional",
            ])
        #expect(full.additional[0].entries[0].organization == "University of Waterloo")
        #expect(full.additional[1].entries[0].bullets == ["Ran a weekly session for 12 kids."])
        #expect(full.additional[1].entries[0].period?.isCurrent == true)
        #expect(full.additional[2].entries[0].url == "https://acm.example/q")
        #expect(full.additional[3].entries.map(\.title) == ["Barista, Beanery (Toronto, ON)", "Camp counsellor"])
        #expect(full.additional[3].entries[0].bullets == ["Opened the shop on weekends."])
        #expect(full.additional[5].entries.map(\.title) == ["Chess club"], "a blank section name")
    }

    @Test func anEmptyResumeIsEmptyEverywhere() {
        let full = FullResume(MasterResume())
        #expect(full.experience.isEmpty && full.projects.isEmpty && full.education.isEmpty)
        #expect(full.skills.isEmpty && full.additional.isEmpty && full.languages == nil && full.summary == nil)
    }
}
