import Foundation
import MasterResume
import Screening
import Store
import Testing

@testable import Pipeline

// A new graduate (fictional) and made-up postings: fixtures only.

private let now = Date(timeIntervalSince1970: 1_792_000_000)  // October 2026

private func resume() -> MasterResume {
    var header = ResumeHeader()
    header.fullName = "Sam Okafor"
    header.totalYears = 0.5
    return MasterResume(
        header: header,
        entries: [
            ResumeEntry(
                fields: .experience(.init(employer: "Harbour Labs", title: "Software Developer")),
                start: YearMonth(year: 2024, month: 1), end: YearMonth(year: 2024, month: 6),
                bullets: [ResumeBullet(text: "Built Flask APIs in Python serving 2,000 users.")]),
            ResumeEntry(
                fields: .experience(.init(employer: "Northline", title: "Developer Intern")),
                start: YearMonth(year: 2023, month: 5), end: YearMonth(year: 2023, month: 8),
                bullets: [ResumeBullet(text: "Wrote data checks for a nightly import.")]),
            ResumeEntry(
                fields: .project(.init(name: "Cluster Lab", tech: ["Kubernetes"])),
                bullets: [ResumeBullet(text: "Deployed 2 services to K8s with Terraform.")]),
            ResumeEntry(fields: .language(.init(language: "English", proficiency: .fluent))),
        ],
        skills: [Skill(name: "Python"), Skill(name: "React"), Skill(name: "Rust", level: .canDiscuss)])
}

private func preferences() -> SearchPreferences {
    var preferences = SearchPreferences()
    preferences.titleInclude = ["Software Engineer", "Developer"]
    preferences.seniority = [.intern, .junior, .mid]
    preferences.thresholds = VerdictThresholds(yesAt: 0.65, maybeAt: 0.4)
    return preferences
}

private func job(_ name: String, _ title: String, _ verdict: Verdict?) -> Job {
    Job(
        canonicalURL: "https://jobs.example.com/\(name)", sourceID: UUID(), url: "https://jobs.example.com/\(name)",
        dedupKey: "\(name)|toronto", company: "Northwind", title: title, location: "Toronto, ON", region: "ON",
        country: .canada, remoteScope: .hybrid, descriptionMarkdown: "Software work.", verdict: verdict,
        verdictSource: verdict == nil ? nil : .analysis, firstSeenAt: now)
}

private func must(
    _ text: String, _ match: JobAnalysis.Requirement.Match, _ category: JobAnalysis.Requirement.Category = .skill
)
    -> JobAnalysis.Requirement
{
    JobAnalysis.Requirement(text: text, kind: .must, category: category, match: match, evidence: [])
}

private func analysis(_ requirements: [JobAnalysis.Requirement]) -> JobAnalysis {
    JobAnalysis(
        requirements: requirements, yearsRequired: nil, seniority: nil, domains: [],
        flags: .init(sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .hybrid))
}

private func record(_ verdict: Verdict, _ rule: VerdictRule) -> ScreeningRecord {
    ScreeningRecord(stage: .analysis, verdict: verdict, ruleID: rule.rawValue, coverage: nil, reasons: [], at: now)
}

private let backend = job("backend", "Backend Developer", .maybe)
private let platform = job("platform", "Platform Developer", .no)
private let web = job("web", "Web Developer", .maybe)
private let snippet = job("snippet", "Software Developer", .maybe)
private let senior = job("senior", "Software Developer", .no)
private let gis = job("gis", "GIS Developer", .no)
private let junior = job("junior", "Junior Developer", .maybe)

private func report() -> ImproveReport {
    let analyses: [JobID: JobAnalysis] = [
        backend.id: analysis([must("Python", .yes), must("Kubernetes in production", .partial), must("Datadog", .no)]),
        platform.id: analysis([
            must("Datadog monitoring", .no), must("Kubernetes", .no), must("Go", .no),
            must("Experience with distributed systems", .no, .experience),
        ]),
        web.id: analysis([must("React", .yes), must("Rust services", .partial), must("TypeScript", .no)]),
        gis.id: analysis([must("ESRI ArcGIS", .no), must("Experience with distributed systems", .no, .experience)]),
        junior.id: analysis([
            must("1+ years of software development", .partial, .experience), must("Python", .yes),
            must("Datadog", .no),
        ]),
    ]
    let screenings = [
        backend.id.rawValue: record(.maybe, .partialMatch), platform.id.rawValue: record(.no, .weakMatch),
        web.id.rawValue: record(.maybe, .partialMatch), snippet.id.rawValue: record(.maybe, .snippetOnly),
        senior.id.rawValue: record(.no, .seniority), gis.id.rawValue: record(.no, .weakMatch),
        junior.id.rawValue: record(.maybe, .partialMatch),
    ]
    let filtered = [
        job("sde", "Software Development Engineer, Payments", nil),
        job("senior-sde", "Senior Software Development Engineer", nil),
        job("bizdev", "Business Development Manager", nil),
    ]
    return ImproveReport(
        jobs: [backend, platform, web, snippet, senior, gis, junior], screenings: screenings, analyses: analyses,
        filteredByTitle: filtered, resume: resume(), preferences: preferences(),
        profile: WorkProfile(authorization: [.canada: .workPermit]), now: now)
}

@Suite struct ImproveReportTests {
    /// Fixes rank by the verdicts they could move, then by how many jobs ask.
    @Test func fixesRankByTheVerdictsTheyCouldMove() {
        let report = report()
        #expect(report.considered == 5)
        #expect(
            report.fixes.map(\.title) == [
                "Datadog", "Kubernetes", "Rust", "Distributed systems", "Years of experience",
            ])
        let datadog = report.fixes[0]
        #expect(datadog.jobs == [backend.id, platform.id, junior.id])
        #expect(datadog.toYes == 2 && datadog.toMaybe == 0)
        #expect(datadog.asks.map(\.text) == ["Datadog", "Datadog monitoring", "Datadog"])
        #expect(report.fixes[3].toMaybe == 1)  // the GIS job would reach Maybe
    }

    /// What your master resume already shows, for each fix.
    @Test func eachFixSaysWhereYourResumeStands() {
        let fixes = Dictionary(uniqueKeysWithValues: report().fixes.map { ($0.title, $0) })
        #expect(fixes["Datadog"]?.standing == .absent)
        #expect(fixes["Kubernetes"]?.standing == .mentioned("Cluster Lab"))  // in a project, not in Skills
        #expect(fixes["Rust"]?.standing == .canDiscuss("Rust"))
        #expect(fixes["Kubernetes"]?.kind == .technology && fixes["Distributed systems"]?.kind == .theme)
    }

    /// Asks only one posting makes, for something nowhere on your resume, aren't ranked.
    @Test func nicheAsksAreOneOffs() {
        let oneOffs = report().oneOffs
        #expect(Set(oneOffs.map(\.title)) == ["ESRI ArcGIS", "Go", "TypeScript"])
        #expect(oneOffs.allSatisfy { $0.jobs.count == 1 })
    }

    /// Your dated roles, overlaps once: 6 months plus 4. A years ask counts as met only if they cover it.
    @Test func yearsCompareYourDatedRolesWithYourTotal() {
        let report = report()
        #expect(report.years.datedMonths == 10 && report.years.stated == 0.5)
        let years = report.fixes.first { $0.kind == .years }
        #expect(years?.asks.map(\.text) == ["1+ years of software development"])
        #expect(years?.toYes == 0)  // 10 months doesn't reach 1 year
    }

    /// Snippets, levels you've turned off, and titles your list misses aren't resume fixes.
    @Test func searchAndHeldReasonsStandApart() {
        let report = report()
        #expect(report.held == [.init(rule: .seniority, jobs: [senior.id])])
        // "Software Development Engineer" has every word of "Software Engineer"; the Senior one
        // would still be dropped for its level, and business development isn't close.
        #expect(report.titleMisses.map(\.phrase) == ["Software Development Engineer"])
        #expect(report.titleMisses.first?.jobs == [JobID(canonicalURL: "https://jobs.example.com/sde")])
    }

    /// A job held at Maybe by years alone: if your dated roles cover the ask, it could be a Yes.
    @Test func yearsYourRolesCoverCouldLiftAMaybe() {
        var longer = resume()
        longer.entries[0] = ResumeEntry(
            fields: .experience(.init(employer: "Harbour Labs", title: "Software Developer")),
            start: YearMonth(year: 2024, month: 1), end: YearMonth(year: 2024, month: 10),
            bullets: [ResumeBullet(text: "Built Flask APIs in Python serving 2,000 users.")])
        var asked = analysis([must("Python", .yes)])
        asked.yearsRequired = 1
        let report = ImproveReport(
            jobs: [junior], screenings: [junior.id.rawValue: record(.maybe, .yearsAboveYours)],
            analyses: [junior.id: asked], filteredByTitle: [], resume: longer, preferences: preferences(),
            profile: WorkProfile(authorization: [.canada: .workPermit]), now: now)
        #expect(report.years.datedMonths == 14)
        let years = report.fixes.first
        #expect(years?.kind == .years && years?.asks.map(\.text) == ["1+ years of experience"])
        #expect(years?.toYes == 1)
    }

    /// A broader term keeps its name, and a skill of yours it covers is where you stand.
    @Test func aBroaderTermKeepsItsName() {
        var yours = resume()
        yours.skills.append(Skill(name: "GCP"))
        let report = ImproveReport(
            jobs: [backend], screenings: [backend.id.rawValue: record(.maybe, .partialMatch)],
            analyses: [
                backend.id: analysis([must("Python", .yes), must("Experience with cloud platforms", .partial)])
            ],
            filteredByTitle: [], resume: yours, preferences: preferences(),
            profile: WorkProfile(authorization: [.canada: .workPermit]), now: now)
        #expect(report.fixes.map(\.title) == ["Cloud"])
        #expect(ImproveReport.conceptNames["nosql"] == "NoSQL")
        #expect(report.fixes.first?.standing == .proven("GCP"))
        // HR platforms aren't security work.
        #expect(ImproveReport.keys("Experience with Workday or identity/HR platforms").map(\.kind) == [.other])
        #expect(ImproveReport.keys("Identity and access management").map(\.id) == ["theme:Security and identity"])
    }
}
