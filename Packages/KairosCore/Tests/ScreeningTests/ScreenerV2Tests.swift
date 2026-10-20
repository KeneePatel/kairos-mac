import Foundation
import LLM
import MasterResume
import Store
import Testing

@testable import Screening

/// A new graduate's master resume (fictional), with a GitHub link typed into a bullet.
private func graduate() -> MasterResume {
    var header = ResumeHeader()
    header.fullName = "Sam Okafor"
    header.email = "sam.okafor@example.com"
    header.gitHubURL = "https://github.com/samokafor"
    header.region = "NS"
    header.totalYears = 1
    return MasterResume(
        header: header,
        entries: [
            ResumeEntry(
                fields: .experience(.init(employer: "Harbour Labs", title: "Software Developer")),
                start: YearMonth(year: 2025, month: 1), isCurrent: true,
                bullets: [
                    ResumeBullet(text: "Built Flask REST APIs backed by PostgreSQL for 3 internal tools."),
                    ResumeBullet(text: "Open-sourced a data checker at github.com/samokafor/tidy."),
                ]),
            ResumeEntry(
                fields: .project(.init(name: "Cluster Lab", tech: ["Kubernetes", "Terraform"])),
                bullets: [ResumeBullet(text: "Deployed 2 Node.js services to GKE with Terraform.")]),
            ResumeEntry(
                fields: .education(
                    .init(institution: "Northshore College", credential: "MACS", field: "Applied Computer Science"))),
            ResumeEntry(fields: .language(.init(language: "English", proficiency: .fluent))),
        ],
        skills: [Skill(name: "Python"), Skill(name: "React"), Skill(name: "Rust", level: .canDiscuss)])
}

private let plain = JobAnalysis.Flags(
    sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .remote)

private func requirement(
    _ text: String, _ category: JobAnalysis.Requirement.Category, _ match: JobAnalysis.Requirement.Match,
    _ evidence: [String] = [], kind: JobAnalysis.Requirement.Kind = .must
) -> JobAnalysis.Requirement {
    JobAnalysis.Requirement(text: text, kind: kind, category: category, match: match, evidence: evidence)
}

private func engine() -> VerdictEngine {
    VerdictEngine(
        preferences: SearchPreferences(), profile: WorkProfile(authorization: [.canada: .workPermit]),
        languages: [.init(language: "English", proficiency: .fluent)], totalYears: 1)
}

@Suite("Screener v2")
struct ScreenerV2Tests {
    /// Every piece of evidence gets an id; contact details and where you live never appear.
    @Test func theProfileNumbersYourEvidenceWithoutContactDetails() {
        let profile = ScreeningProfile(graduate())
        let text = profile.text
        #expect(text.contains("Skills: [s1] Python, [s2] React"))
        #expect(text.contains("Can discuss (not proven): [c1] Rust"))
        #expect(text.contains("Education: [d1] MACS, Applied Computer Science"))
        #expect(text.contains("[x1] Experience: Software Developer · Harbour Labs · 2025-01 to present"))
        #expect(text.contains("  [x1b1] Built Flask REST APIs backed by PostgreSQL for 3 internal tools."))
        #expect(text.contains("[p1] Project: Cluster Lab · Kubernetes, Terraform"))
        #expect(text.contains("Total years of professional experience: 1"))
        for private_ in ["Sam Okafor", "sam.okafor@example.com", "samokafor", "Northshore", "NS"] {
            #expect(!text.contains(private_), "the profile carries “\(private_)”")
        }
        #expect(profile.describe("x1b1")?.hasPrefix("Built Flask REST APIs") == true)
        #expect(profile.describe("d1") == "MACS, Applied Computer Science" && profile.describe("s9") == nil)
    }

    /// Code keeps the model honest: a counted requirement is judged, and a Can-discuss skill alone
    /// is a partial match at most. Unknown ids don't survive.
    @Test func repliesAreNormalised() throws {
        let input = AnalyzeJobTask.Input(job: sampleJob(), profile: ScreeningProfile(graduate()))
        let output = AnalyzeJobTask.Output(
            requirements: [
                requirement("Python", .skill, .notJudged),
                requirement("Rust", .skill, .yes, ["c1"]),
                requirement("Backend APIs", .experience, .yes, ["x1b1", "zz9"]),
                requirement("Teamwork", .soft, .notJudged),
            ], yearsRequired: nil, seniority: "junior", domains: [], flags: plain)
        let analysis = JobAnalysis(output, input: input)
        #expect(analysis.requirements.map(\.match) == [.no, .partial, .yes, .notJudged])
        #expect(analysis.requirements[2].evidence == ["x1b1"])
    }

    /// Your three examples: residency, a related degree, and AI tools shown only in part.
    @Test func partialMatchesCountHalfAndConditionsNeverCount() {
        let analysis = JobAnalysis(
            requirements: [
                requirement("Javascript/Typescript experience", .skill, .yes, ["s2"]),
                requirement("BS/MS in Computer Science or related field", .education, .yes, ["d1"]),
                requirement("Strong background in distributed systems", .experience, .partial, ["p1b1"]),
                requirement("Proficiency in AI tools", .skill, .partial, ["c1"]),
                requirement("Residing in Ontario, Nova Scotia or British Columbia", .location, .notJudged),
                requirement("Excellent communication skills", .soft, .notJudged),
                requirement("Willingness to learn C++", .soft, .notJudged),
                requirement("Kubernetes", .skill, .yes, ["p1"], kind: .nice),
            ], yearsRequired: nil, seniority: .junior, domains: [], flags: plain)
        let coverage = Coverage(analysis)
        #expect(coverage == Coverage(mustCovered: 3, mustTotal: 4, niceCovered: 1, niceTotal: 1))
        let decision = engine().decide(analysis, for: sampleJob())
        #expect(decision.verdict == .yes && decision.rule == .strongMatch)  // 3 of 4 = 75%
        #expect(decision.reasons.contains("Covers 3 of 4 must-haves and 1 of 1 nice-to-haves."))
    }

    /// Below the bar, only what's really missing is named: never soft skills or conditions.
    @Test func missingNamesOnlyRequirementsYourResumeDoesntShow() {
        let analysis = JobAnalysis(
            requirements: [
                requirement("Ruby on Rails", .skill, .no),
                requirement("Observability tools", .skill, .partial, ["s1"]),
                requirement("Go", .skill, .no),
                requirement("Clear communication", .soft, .notJudged),
                requirement("Located in Canada", .location, .notJudged),
            ], yearsRequired: nil, seniority: nil, domains: [], flags: plain)
        let decision = engine().decide(analysis, for: sampleJob())
        #expect(decision.verdict == .no && decision.rule == .weakMatch)  // 0.5 of 3
        #expect(decision.reasons.first == "Missing Ruby on Rails and Go")
    }

    /// Analyses from prompt v1 (stored before the change) still score exactly as they did.
    @Test func olderAnalysesScoreAsBefore() {
        let v1 = JobAnalysis(
            requirements: [
                .init(text: "Go", kind: .must, matchedSkill: "Go"), .init(text: "Kafka", kind: .must),
                .init(text: "Legally entitled to work in Canada", kind: .must),
            ], yearsRequired: nil, seniority: nil, domains: [], flags: plain)
        #expect(Coverage(v1) == Coverage(mustCovered: 1, mustTotal: 2, niceCovered: 0, niceTotal: 0))
        #expect(v1.requirements.map(\.effectiveMatch) == [.yes, .no, .no] && !v1.requirements[2].counts)
    }

    /// Stored coverage written before partial credit (whole numbers) still reads.
    @Test func storedCoverageStillDecodes() throws {
        let stored = #"{"mustCovered":2,"mustTotal":3,"niceCovered":0,"niceTotal":1}"#
        let coverage = try JSONDecoder().decode(Coverage.self, from: Data(stored.utf8))
        #expect(coverage == Coverage(mustCovered: 2, mustTotal: 3, niceCovered: 0, niceTotal: 1))
    }
}
