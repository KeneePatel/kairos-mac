import Foundation
import Testing

@testable import Tailoring

private let job = JobRequirements(
    musts: [
        "3+ years building services in Go or Java", "Postgres in production",
        "Experience with message queues such as RabbitMQ or Kafka", "Legally entitled to work in Canada",
    ], nices: ["Kubernetes", "gRPC"], domains: ["logistics"])

private let strongBullets = [
    "Built a Go and Kafka event pipeline handling 4.2M events a day at p99 under 120 ms.",
    "Moved 14 services to Kubernetes on a shared Helm chart, cutting deploys from 25 to 6 minutes.",
    "Cut carrier onboarding from 3 weeks to 4 days with a gRPC integration kit for 11 carriers.",
    "Shipped REST APIs on PostgreSQL for 30+ client projects in a logistics platform.",
]

private func resume(
    _ bullets: [String], skills: [String] = ["Go", "PostgreSQL", "Kafka", "Kubernetes", "gRPC"],
    summary: String? = "Backend developer with 5 years building Go and PostgreSQL services for logistics."
) -> TailoredResume {
    TailoredResume(
        header: .init(name: "Jordan Rivera"), summary: summary, skills: [SkillGroup(label: "Skills", skills: skills)],
        experience: [
            .init(
                entryID: UUID(), title: "Software Developer, Backend", organization: "Harbourline Logistics",
                bullets: bullets.map { TailoredBullet(text: $0, sourceIDs: [UUID()]) })
        ])
}

@Suite("Match score")
struct MatchScoreTests {
    /// SPEC §5.3's weights: must-haves 40, nice-to-haves 10, evidence 15, domain 10, metrics 10,
    /// language 10, structure 5.
    @Test func aStrongBuildEarnsEveryPoint() {
        let score = MatchScore.score(resume(strongBullets), for: job, pages: 1)
        #expect(
            score.breakdown
                == MatchScore.Breakdown(
                    mustHaves: 40, niceToHaves: 10, evidence: 15, domain: 10, metrics: 10, language: 10, structure: 5))
        #expect(score.total == 100)
        #expect(score.score(.experience) == 100 && score.score(.skills) == 100)
        #expect(score.findings(.experience).isEmpty)
    }

    /// Work authorization is a condition the verdict judged; a resume can't show it.
    @Test func conditionsArentScored() {
        let withoutCondition = JobRequirements(
            musts: Array(job.musts.prefix(3)), nices: job.nices, domains: job.domains)
        #expect(
            MatchScore.score(resume(strongBullets), for: job)
                == MatchScore.score(resume(strongBullets), for: withoutCondition))
    }

    @Test func bulletsBeatASkillsList() {
        let noKubernetes = strongBullets.filter { !$0.contains("Kubernetes") }
        let score = MatchScore.score(resume(noKubernetes), for: job)
        #expect(score.breakdown.niceToHaves == 10)  // the skills list still covers it
        #expect(score.breakdown.evidence < 15)  // but only bullets count as evidence
    }

    @Test func missingMustHavesCostMostAndBecomeFindings() {
        let score = MatchScore.score(
            resume([strongBullets[0], strongBullets[2]], skills: ["Go", "Kafka"], summary: nil), for: job)
        #expect(score.breakdown.mustHaves < 40 * 0.7)
        #expect(
            score.findings(.experience).contains { $0.hasPrefix("Not shown in any bullet: Postgres in production") })
        #expect((score.score(.skills) ?? 100) < 100)
    }

    @Test func weakLanguageAndMissingNumbersLowerTheSection() {
        let weak = [
            "Responsible for the Go event pipeline.", "Worked on the Kafka queues.", "I built the PostgreSQL schema.",
        ]
        let score = MatchScore.score(resume(weak), for: job)
        #expect(score.breakdown.metrics == 0 && score.breakdown.language <= 4)
        #expect((score.score(.experience) ?? 100) < 70)
        let findings = score.findings(.experience).joined(separator: "\n")
        #expect(findings.contains("“responsible for”") && findings.contains("first person"))
        #expect(findings.contains("0 of 3 bullets have a number"))
    }

    /// The employer's name is evidence of the domain, even when no bullet says it.
    @Test func whereYouWorkedShowsTheDomain() {
        let bullets = strongBullets.map { $0.replacing(" in a logistics platform", with: "") }
        let score = MatchScore.score(resume(bullets, summary: nil), for: job)
        #expect(score.breakdown.domain == 10)  // "Harbourline Logistics"
        var elsewhere = resume(bullets, summary: nil)
        elsewhere.experience[0].organization = "Rivet Studio"
        #expect(MatchScore.score(elsewhere, for: job).breakdown.domain == 0)
    }

    @Test func runningOverThePageBudgetCostsStructure() {
        let fits = MatchScore.score(resume(strongBullets), for: job, pages: 1, pageBudget: 1)
        let over = MatchScore.score(resume(strongBullets), for: job, pages: 2, pageBudget: 1)
        #expect(fits.breakdown.structure - over.breakdown.structure == 2)
    }

    @Test func theScoreSurvivesStorage() throws {
        let score = MatchScore.score(resume(strongBullets), for: job)
        #expect(try JSONDecoder().decode(MatchScore.self, from: JSONEncoder().encode(score)) == score)
    }
}

@Suite("Tailored header")
struct TailoredHeaderTests {
    /// Code fills the contact line from your contact block; a link that doesn't validate is left off.
    @Test func theContactLineComesFromYourContactBlock() {
        var header = Sample.resume.header
        header.email = "jordan.rivera@example.com"
        header.phone = "+14165550123"
        header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
        header.gitHubURL = "https://github.com/jrivera"
        header.portfolioURL = "http://jordanrivera.dev"  // not https: left off
        header.city = "Toronto"
        header.region = "ON"
        header.headline = "Backend developer"
        let tailored = TailoredResume.Header(header)
        #expect(tailored.name == "Jordan Rivera" && tailored.headline == "Backend developer")
        #expect(
            tailored.contact.map(\.text) == [
                "jordan.rivera@example.com", "(416) 555-0123", "linkedin.com/in/jordan-rivera", "github.com/jrivera",
                "Toronto, ON",
            ])
        #expect(tailored.contact[0].url == "mailto:jordan.rivera@example.com")
    }

    /// The phone number is a link too, so it can be tapped in the PDF; separators don't reach it.
    @Test func thePhoneNumberIsATelLink() {
        var header = Sample.resume.header
        header.phone = "+14165550123"
        #expect(TailoredResume.Header(header).contact.first { $0.text == "(416) 555-0123" }?.url == "tel:+14165550123")
        #expect(TailoredResume.Header.telURL("(416) 555-0123") == "tel:4165550123")
    }
}
