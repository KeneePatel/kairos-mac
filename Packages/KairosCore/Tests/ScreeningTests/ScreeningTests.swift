import AI
import Foundation
import Jobs
import KairosKit
import Resume
import TestKit
import Testing

@testable import Screening

// Made-up postings and the sample persona: fixtures only.
private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let english = [EntryFields.Language(language: "English", proficiency: .native)]

private func job(
    _ title: String = "Software Developer", company: String = "Harbourline Logistics", location: String = "Toronto, ON",
    country: Country? = .canada, region: String? = "ON", remote: RemoteScope = .onsite, daysOld: Double? = 2,
    description: String = "Build backend services in Go and PostgreSQL."
) -> Job {
    Job(
        id: StableID.of(title + company + location), company: company, title: title, location: location, region: region,
        country: country, remoteScope: remote, postedAt: daysOld.map { now.addingTimeInterval(-$0 * 86_400) },
        description: description, url: "https://jobs.example.com/\(title.count)", firstSeenAt: now)
}

/// A Canadian citizen who'd need a visa for the US, with no clearance: the persona's profile.
private func prefilter(
    languages: [EntryFields.Language] = english, applied: [AppliedJob] = [],
    _ change: (inout SearchPreferences, inout WorkProfile) -> Void = { _, _ in }
) -> Prefilter {
    var preferences = SearchPreferences()
    var profile = WorkProfile(authorization: [.canada: .citizen, .unitedStates: .needsSponsorship])
    change(&preferences, &profile)
    return Prefilter(preferences: preferences, profile: profile, languages: languages, applied: applied, now: now)
}

private func check(
    _ filter: Prefilter, _ cases: [(Job, PrefilterRule?)], sourceLocation: SourceLocation = #_sourceLocation
) {
    for (job, expected) in cases {
        #expect(
            filter.rejection(for: job)?.rule == expected, "\(job.title) · \(job.location) · \(job.company)",
            sourceLocation: sourceLocation)
    }
}

@Suite("Prefilter")
struct PrefilterTests {
    @Test func defaultsRejectNothing() {
        check(
            prefilter(),
            [
                (job(), nil), (job("Staff Engineer", daysOld: 900), nil),
                (job("Sales Manager", company: "Anyco", country: nil, region: nil), nil),
                (job(description: "10+ years of experience required."), nil), (job(description: ""), nil),
            ])
    }

    @Test func rolesAndTitles() {
        let roles = prefilter { preferences, _ in
            preferences.roles = [.software]
            preferences.titleInclude = ["solutions engineer"]
            preferences.titleExclude = ["manager", "c++"]
        }
        check(
            roles,
            [
                (job("Senior Software Engineer"), nil), (job("Full-Stack Developer"), nil),
                (job("Solutions Engineer"), nil), (job("Sales Development Representative"), .titleInclude),
                (job("Data Analyst"), .titleInclude), (job("Software Engineering Manager"), .titleExclude),
                (job("Software Development Manager"), .titleInclude),
                (job("C++ Developer"), .titleExclude),
            ])
    }

    @Test func seniorityOutsideYourLevelsIsOut() {
        let filter = prefilter { preferences, _ in preferences.seniority = [.junior, .mid, .senior] }
        check(
            filter,
            [
                (job("Senior Backend Developer"), nil), (job("Software Engineer II"), nil),
                (job("Software Developer"), nil),
                (job("Staff Software Engineer"), .seniority), (job("Software Engineering Intern"), .seniority),
                (job("Engineering Manager"), .seniority),
            ])
    }

    @Test func titlesNameTheirLevel() {
        let cases: [(String, Seniority?)] = [
            ("Software Developer", nil), ("Junior Developer", .junior), ("Jr. Backend Engineer", .junior),
            ("New Grad Software Engineer", .junior), ("Intermediate Developer", .mid), ("Software Engineer II", .mid),
            ("Software Engineer III", .senior), ("Senior Staff Engineer", .staff), ("Lead Developer", .lead),
            ("Software Engineer, Co-op (Winter 2027)", .intern), ("VP, Engineering", .director),
            ("Head of Platform", .director), ("Product Manager", nil), ("Engineering Manager", .manager),
            // A team called "Management" isn't a manager level (Ramp's "Token Spend Management", a real run).
            ("Software Engineer, Spend Management", nil), ("Senior Backend Engineer | Token Spend Management", .senior),
        ]
        for (title, level) in cases { #expect(Seniority.of(title: title) == level, "\(title)") }
    }

    @Test func askingForMoreYearsThanYourMaximumIsOut() {
        let filter = prefilter { preferences, _ in preferences.maxYearsRequired = 5 }
        check(
            filter,
            [
                (job(description: "5+ years of experience with Go."), nil),
                (job(description: "7+ years of professional software development experience."), .yearsRequired),
                (job(description: "3-5 years of experience."), nil),
                (job(description: "Minimum of eight years building distributed systems."), .yearsRequired),
                (job(description: "Founded 12 years ago. 2+ years of experience with Go."), nil),
                (job(description: "Au moins 7 ans d'expérience en développement."), .yearsRequired),
                (job(description: "Nice to have: 10+ years with Kubernetes.\n- 3+ years of experience"), nil),
            ])
    }

    @Test func placesCountriesAndRemote() {
        let filter = prefilter { preferences, _ in
            preferences.countries = [.canada]
            preferences.regions = ["CA": ["ON", "BC"]]
        }
        check(
            filter,
            [
                (job(), nil), (job(location: "Montréal, QC", region: "QC"), .location),
                (job(location: "Seattle, WA", country: .unitedStates, region: "WA"), .location),
                (job(location: "Remote (Canada)", region: nil, remote: .remoteCountry), nil),
                (job(location: "Somewhere", country: nil, region: nil, remote: .unknown), nil),
            ])
        // "Remote (US only)" needs you to live and work in the US.
        check(
            prefilter(),
            [
                (
                    job(location: "Remote (US only)", country: .unitedStates, region: nil, remote: .remoteCountry),
                    .remoteScope
                ),
                (
                    job(
                        location: "Remote", country: nil, region: nil, remote: .remote,
                        description: "This is a fully remote role. Candidates must reside in the United States."),
                    .remoteScope
                ),
                (job(location: "Remote - North America", country: nil, region: nil, remote: .remoteAnywhere), nil),
            ])
    }

    @Test func authorizationClearanceAndFrench() {
        func us(_ text: String) -> Job {
            job(location: "Austin, TX", country: .unitedStates, region: "TX", description: text)
        }
        check(
            prefilter(),
            [
                (us("We are unable to sponsor visas for this role."), .workAuthorization),
                (us("Sponsorship is not available now or in the future."), .workAuthorization),
                (us("Visa sponsorship is available."), nil),
                (job(description: "Must be authorized to work in Canada."), nil),
                (us("Active Top Secret clearance required."), .clearance), (us("No security clearance required."), nil),
                (job(description: "Must be able to obtain Government of Canada Reliability Status."), nil),
                (job(description: "Bilingual (English/French) required."), .french),
                (job(description: "French is an asset."), nil),
                (job(description: "You must be bilingual."), .french),
                (
                    job(
                        location: "Miami, FL", country: .unitedStates, region: "FL",
                        description: "Bilingual Spanish is a plus."), nil
                ),
            ])
        let french = prefilter(languages: english + [.init(language: "French", proficiency: .conversational)])
        check(french, [(job(description: "Bilingual (English/French) required."), nil)])
    }

    @Test func blockedCompaniesAgenciesAgeAndApplied() {
        let filter = prefilter(applied: [AppliedJob(company: "Maplepay Inc.", title: "Backend Developer")]) {
            preferences, _ in
            preferences.blacklist = ["Amazon"]
            preferences.maxAgeDays = 14
        }
        check(
            filter,
            [
                (job(company: "Amazon Web Services"), .blacklist), (job(company: "Amazonia Labs"), nil),
                (job(company: "Randstad Canada"), .agency), (job(company: "Northline Staffing Inc."), .agency),
                (
                    job(company: "Harbourline", description: "Our client, a Toronto bank, needs a Go developer."),
                    .agency
                ),
                (job(daysOld: 20), .postingAge), (job(daysOld: nil), nil),
                (job("Backend Developer", company: "Maplepay"), .alreadyApplied),
            ])
        let kept = prefilter { preferences, _ in preferences.showAgencies = true }
        check(kept, [(job(company: "Randstad Canada"), nil)])
    }

    @Test func aCopyOfAnAppliedJobIsKnown() {
        let text = String(repeating: "Build the fleet API in Go with PostgreSQL and Kafka. ", count: 6)
        let applied = job("DevOps Engineer (Vac DST)", company: "Institute of Free Technology", description: text)
        let twin = job("DevOps Engineer (Vac DST)", company: "Logos", location: "Toronto, Ontario", description: text)
        #expect(Prefilter.isCopy(twin, of: applied) && !Prefilter.isCopy(applied, of: applied))
        #expect(!Prefilter.isCopy(job("Data Engineer", company: "Logos", description: text), of: applied))
    }

    @Test func theFirstKairossSettingsRead() throws {
        let saved =
            #"{"countries":["CA"],"maxAgeDays":7,"roles":["software","devops","nonsense"],"seniority":["junior","mid","intern"],"thresholds":{"yesAt":0.8},"watchCatalog":true,"places":[{"city":"Halifax","region":"Nova Scotia","country":"CA"}]}"#
        let preferences = try SearchPreferences.fromJSON(saved)
        #expect(preferences.roles == [.software, .devops] && preferences.countries == [.canada])
        #expect(preferences.seniority == [.junior, .mid, .intern] && preferences.maxAgeDays == 7)
        #expect(preferences.thresholds.yesAt == 0.8 && preferences.thresholds.maybeAt == 0.5)
        #expect(preferences.effectivePlaces.map(\.city) == ["Halifax"])
        #expect(try SearchPreferences.fromJSON(try preferences.jsonText()) == preferences)
        let profile = try WorkProfile.fromJSON(
            #"{"authorization":{"CA":"work_permit"},"hasClearance":false,"enrolment":"graduated"}"#)
        #expect(profile.authorization[.canada] == .workPermit && profile.enrolment == .graduated)
    }
}

@Suite("Years and posting cleanup")
struct TextTests {
    @Test(arguments: [
        ("3+ years of experience with Go.", 3), ("Minimum of five years building services.", 5),
        ("2-4 years of professional experience.", 2), ("We were founded 12 years ago.", nil),
        ("At least 7 years in software.", 7), ("Au moins 4 ans d'expérience.", 4),
        ("Nice to have: 8+ years of Rust.", nil),
    ])
    func readsTheYearsAsked(text: String, years: Int?) {
        #expect(YearsParser.requiredYears(in: text) == years)
    }

    @Test func boilerplateGoesAndRequirementsComeFirstWhenShortened() {
        let posting = """
            We build freight software.

            ## What you'll do
            - Build services.

            ## What you bring
            - 3+ years with Go

            ## Benefits
            - Dental

            We are an equal opportunity employer and consider applicants without regard to race.
            """
        let cleaned = PostingCleaner.clean(posting, limit: 10_000)
        #expect(!cleaned.contains("Dental") && !cleaned.contains("equal opportunity") && cleaned.hasPrefix("We build"))
        let short = PostingCleaner.clean(posting, limit: 60)
        #expect(short.hasPrefix("## What you bring") && short.hasSuffix(PostingCleaner.shortened) && short.count <= 60)
    }
}

/// The posting the first Kairos recorded real replies for (fixtures, made-up company).
private let samplePosting = """
    Northline Freight is hiring a Backend Developer II in Toronto, ON (hybrid, 2 days a week).

    ## What you'll do
    - Build the services that track two million shipments a day.

    ## What you bring
    - 3+ years building services in Go or Java
    - Strong PostgreSQL
    - Experience with message queues such as RabbitMQ or Kafka
    - Must be legally entitled to work in Canada; we can't sponsor visas.

    ## Nice to have
    - Kubernetes, gRPC, French
    """

private func sampleInput() -> AnalyzeJobTask.Input {
    var resume = MasterResume()
    resume.skills = [
        Skill(name: "Go"), Skill(name: "PostgreSQL"), Skill(name: "Kafka"), Skill(name: "Docker", level: .canDiscuss),
    ]
    resume.entries = [ResumeEntry(fields: .language(.init(language: "English", proficiency: .native)))]
    let northline = job(
        "Backend Developer II", company: "Northline Freight", remote: .hybrid, description: samplePosting)
    return AnalyzeJobTask.Input(job: northline, profile: ScreeningProfile(resume))
}

@Suite("Analysis and verdict")
struct AnalysisTests {
    private func verdicts(_ change: (inout SearchPreferences, inout WorkProfile) -> Void = { _, _ in }) -> VerdictEngine
    {
        var preferences = SearchPreferences()
        var profile = WorkProfile(authorization: [.canada: .citizen, .unitedStates: .needsSponsorship])
        change(&preferences, &profile)
        return VerdictEngine(preferences: preferences, profile: profile, languages: english, totalYears: 5)
    }

    private func analysis(
        must: [JobAnalysis.Requirement.Match], nice: [JobAnalysis.Requirement.Match] = [],
        years: Int? = nil, seniority: Seniority? = nil, flags: JobAnalysis.Flags = JobAnalysis.Flags()
    ) -> JobAnalysis {
        JobAnalysis(
            requirements: must.enumerated().map {
                .init(text: "Must \($0.offset)", kind: .must, category: .skill, match: $0.element)
            }
                + nice.enumerated().map {
                    .init(text: "Nice \($0.offset)", kind: .nice, category: .skill, match: $0.element)
                },
            yearsRequired: years, seniority: seniority, flags: flags)
    }

    /// Every recorded reply passes its checks and reads as the fit it is: never a No.
    @Test func recordedRepliesFromRealModelsRead() throws {
        for name in ["gemini-flash-lite-latest", "qwen3.5_4B-thinking-off", "qwen3.5_4B-thinking-on"] {
            let text = try Fixtures.text("screening/analyzeJob-\(name).json")
            let input = sampleInput()
            guard case .success(let output) = OutputCheck.output(from: text, task: AnalyzeJobTask(), input: input)
            else {
                Issue.record("\(name) failed its checks")
                continue
            }
            let analysis = JobAnalysis(output, input: input)
            #expect(analysis.flags.sponsorship == .notOffered && analysis.flags.french == .asset, "\(name)")
            let decision = verdicts().decide(analysis, for: job(description: samplePosting))
            #expect(decision.verdict != .no, "\(name): \(decision.reasons)")
            if name.hasPrefix("gemini") { #expect(decision.verdict == .yes && decision.rule == .strongMatch) }
        }
    }

    @Test func coverageCountsPartialsAsHalf() {
        let cases: [([JobAnalysis.Requirement.Match], Verdict, VerdictRule)] = [
            ([.yes, .yes, .yes, .no], .yes, .strongMatch),  // 0.75
            ([.yes, .partial, .yes], .yes, .strongMatch),  // 0.83
            ([.yes, .yes, .no], .maybe, .partialMatch),  // 0.67
            ([.yes, .no], .maybe, .partialMatch),  // 0.5
            ([.yes, .no, .no], .no, .weakMatch),
            ([], .maybe, .noRequirements),
        ]
        for (must, verdict, rule) in cases {
            let decision = verdicts().decide(analysis(must: must), for: job())
            #expect(decision.verdict == verdict && decision.rule == rule, "\(must)")
        }
    }

    @Test func profileAndPolicyComeBeforeCoverage() {
        let austin = job(location: "Austin, TX", country: .unitedStates, region: "TX")
        #expect(
            verdicts().decide(analysis(must: [.yes], flags: .init(sponsorship: .notOffered)), for: austin).rule
                == .workAuthorization)
        #expect(
            verdicts().decide(analysis(must: [.yes], flags: .init(sponsorship: .notOffered)), for: job()).verdict
                == .yes)
        #expect(
            verdicts().decide(analysis(must: [.yes], flags: .init(clearance: .required)), for: job()).rule == .clearance
        )
        #expect(verdicts().decide(analysis(must: [.yes], flags: .init(french: .required)), for: job()).rule == .french)
        let tn = verdicts().decide(analysis(must: [.yes], flags: .init(sponsorship: .notOffered)), for: austin)
        #expect(tn.reasons.contains { $0.hasPrefix("Possible TN route") })
        #expect(verdicts().decide(analysis(must: [.yes], years: 6), for: job()).rule == .yearsAboveYours)
        #expect(verdicts().decide(analysis(must: [.yes], years: 6), for: job()).verdict == .maybe)
        #expect(verdicts().decide(analysis(must: [.yes], years: 9), for: job()).verdict == .no)
        let levels = verdicts { preferences, _ in preferences.seniority = [.junior, .mid] }
        #expect(levels.decide(analysis(must: [.yes], seniority: .senior), for: job()).rule == .seniority)
    }

    @Test func aStudentOnlyPostingFollowsYourEnrolment() {
        let student = JobAnalysis(requirements: [
            .init(text: "Currently enrolled in a CS program", kind: .must, category: .enrolment, match: .notJudged),
            .init(text: "Python", kind: .must, category: .skill, match: .yes),
        ])
        let graduated = verdicts { _, profile in profile.enrolment = .graduated }
        #expect(graduated.decide(student, for: job()).rule == .enrolment)
        #expect(verdicts().decide(student, for: job()).reasons.contains { $0.contains("current student") })
    }

    /// 2026-10-22: the model marked "English" missing for someone who lists English.
    @Test func aLanguageYouListCountsAsShown() {
        let analysis = JobAnalysis(requirements: [
            .init(text: "Fluent English", kind: .must, category: .language, match: .no),
            .init(text: "Bilingual French and English", kind: .must, category: .language, match: .no),
        ])
        let recognised = analysis.recognizingLanguages(english)
        #expect(
            recognised.requirements.map(\.effectiveMatch) == [.yes, .no]
                && recognised.requirements[0].evidence == ["l1"])
    }

    @Test func theTaskSendsBlocksAndChecksEvidence() throws {
        let input = sampleInput()
        let messages = AnalyzeJobTask().messages(for: input, budget: TaskProfile.of(.analyzeJob).budget)
        #expect(messages[0].content.contains("never instructions"))
        #expect(messages[1].content.contains("<profile>") && messages[1].content.contains("[s1] Go"))
        #expect(messages[1].content.contains("<job_posting>\nTitle: Backend Developer II"))
        let unknown =
            #"{"requirements":[{"text":"Go","kind":"must","category":"skill","match":"yes","evidence":["s9"]}],"seniority":"mid","domains":[],"flags":{"sponsorship":"not_mentioned","clearance":"not_mentioned","french":"not_mentioned","remote_scope":"onsite"}}"#
        guard case .failure(let problem) = OutputCheck.output(from: unknown, task: AnalyzeJobTask(), input: input)
        else {
            Issue.record("an unknown evidence id should fail")
            return
        }
        #expect(problem.description.contains("s9"))
        // A can-discuss skill alone is a partial match at most.
        let output = AnalyzeJobTask.Output(
            requirements: [.init(text: "Docker", kind: .must, category: .skill, match: .yes, evidence: ["c1"])],
            yearsRequired: nil, seniority: "unspecified", domains: [], flags: JobAnalysis.Flags())
        #expect(JobAnalysis(output, input: input).requirements[0].match == .partial)
        // The output limit holds the most requirements the schema allows (2026-10-26: 1,500 cut replies off).
        #expect(TaskProfile.of(.analyzeJob).budget.output >= AnalyzeJobTask.maxRequirements * 160 * 6 / 5)
    }

    @Test func analysesFromTheFirstPromptStillCount() throws {
        let v1 =
            #"{"requirements":[{"text":"Go","kind":"must","matchedSkill":"Go"},{"text":"Must be eligible to work in Canada","kind":"must"},{"text":"Rust","kind":"must"}],"domains":[],"flags":{"sponsorship":"not_mentioned","clearance":"not_mentioned","french":"not_mentioned","remoteScope":"onsite"}}"#
        let analysis = try JobAnalysis.fromJSON(v1)
        let coverage = Coverage(analysis)
        #expect(coverage.mustTotal == 2 && coverage.mustCovered == 1)  // the condition doesn't count
    }

    @Test func rankingPutsCanadaFirst() {
        let countries: [Country] = [.canada, .unitedStates]
        func rank(_ verdict: Verdict, _ country: Country?, _ match: Double) -> Double {
            Ranking.rank(verdict, country: country, match: match, countries: countries)
        }
        #expect(rank(.yes, .canada, 0.6) > rank(.yes, .unitedStates, 1.0))
        #expect(rank(.yes, .unitedStates, 0.0) > rank(.maybe, .canada, 1.0))
        #expect(rank(.yes, .canada, 0.9) > rank(.yes, .canada, 0.8))
        #expect(rank(.no, .canada, 1.0) < rank(.maybe, nil, 0.0))
    }

    @Test func suggestionsCiteYourResumeAndAskQuestions() async throws {
        let chat = ScriptedChat([
            .suggestEvidence: [
                .json(
                    #"{"suggestions":[{"evidence":["s1"],"question":"Did the Go services have dashboards.","angle":"A tool"}],"otherwise":""}"#
                ),
                .json(
                    #"{"suggestions":[{"evidence":["s1"],"question":"Did the Go services have dashboards?","angle":"A tool"}],"otherwise":""}"#
                ),
            ]
        ])
        let input = SuggestEvidenceTask.Input(
            fix: "Observability", asks: ["Prometheus", "prometheus ", "Grafana"], profile: sampleInput().profile)
        #expect(input.asks == ["Prometheus", "Grafana"])
        let result = try await scriptedRouter(chat).run(SuggestEvidenceTask(), input: input)
        #expect(result.repaired && result.output.suggestions.count == 1)
    }
}
