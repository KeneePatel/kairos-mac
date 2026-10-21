import Foundation
import MasterResume
import Store
import Testing

@testable import Screening

private let english = [EntryFields.Language(language: "English", proficiency: .native)]
private let plain = JobAnalysis.Flags(
    sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .onsite)

/// Must-haves and nice-to-haves as (text, your matching skill).
private func analysis(
    must: [(String, String?)], nice: [(String, String?)] = [], years: Int? = nil, seniority: Seniority? = nil,
    flags: JobAnalysis.Flags = plain
) -> JobAnalysis {
    JobAnalysis(
        requirements: must.map { .init(text: $0.0, kind: .must, matchedSkill: $0.1) }
            + nice.map { .init(text: $0.0, kind: .nice, matchedSkill: $0.1) },
        yearsRequired: years, seniority: seniority, domains: [], flags: flags)
}

/// The sample persona: a Canadian citizen with 5 years, who'd need a visa for the US.
private func engine(
    languages: [EntryFields.Language] = english, years: Double? = 5,
    _ change: (inout SearchPreferences, inout WorkProfile) -> Void = { _, _ in }
) -> VerdictEngine {
    var preferences = SearchPreferences()
    var profile = WorkProfile(authorization: [.canada: .citizen, .unitedStates: .needsSponsorship])
    change(&preferences, &profile)
    return VerdictEngine(preferences: preferences, profile: profile, languages: languages, totalYears: years)
}

private let toronto = sampleJob()
private let austin = Job(
    canonicalURL: "https://jobs.example.com/austin", sourceID: UUID(), url: "https://jobs.example.com/a", dedupKey: "a",
    company: "Rivet Studio", title: "Backend Developer", location: "Austin, TX", region: "TX", country: .unitedStates,
    remoteScope: .onsite, firstSeenAt: Date(timeIntervalSince1970: 1_790_000_000))

@Suite("Verdict")
struct VerdictTests {
    /// The T28 sample: work authorization is a condition the flags judge, so it doesn't count
    /// against your skills.
    @Test func coveringTheMustHavesIsAYes() {
        let sample = analysis(
            must: [
                ("3+ years building services in Go or Java", "Go"), ("Strong PostgreSQL", "PostgreSQL"),
                ("Message queues such as RabbitMQ or Kafka", "Kafka"), ("Legally entitled to work in Canada", nil),
            ], nice: [("Kubernetes", nil), ("gRPC", nil), ("French", nil)], years: 3, seniority: .mid,
            flags: .init(sponsorship: .notOffered, clearance: .notMentioned, french: .asset, remoteScope: .hybrid))
        let decision = engine().decide(sample, for: toronto)
        #expect(decision.verdict == .yes && decision.rule == .strongMatch)
        #expect(decision.coverage == Coverage(mustCovered: 3, mustTotal: 3, niceCovered: 0, niceTotal: 2))
        #expect(decision.reasons.contains("Covers 3 of 3 must-haves and 0 of 2 nice-to-haves."))
        #expect(decision.reasons.contains("French is an asset."))
        #expect(abs(decision.coverage.match - 0.8) < 0.001)  // musts weigh 80%, nice-to-haves 20%
    }

    @Test func coverageDecidesWhenNothingElseDoes() {
        let cases: [([(String, String?)], Verdict, VerdictRule)] = [
            ([("Go", "Go"), ("Kafka", "Kafka"), ("AWS", nil), ("Terraform", "Terraform")], .yes, .strongMatch),  // 0.75
            ([("Go", "Go"), ("Kafka", "Kafka"), ("AWS", nil)], .maybe, .partialMatch),  // 0.67
            ([("Go", "Go"), ("Rust", nil)], .maybe, .partialMatch),  // 0.5
            ([("Go", "Go"), ("Rust", nil), ("Scala", nil)], .no, .weakMatch),  // 0.33
            (
                [("Bachelor's degree in computer science", nil), ("Must be able to travel", nil)], .maybe,
                .noRequirements
            ),
            ([], .maybe, .noRequirements),
        ]
        for (must, verdict, rule) in cases {
            let decision = engine().decide(analysis(must: must), for: toronto)
            #expect(decision.verdict == verdict && decision.rule == rule, "\(must.map(\.0))")
        }
        let strict = engine { preferences, _ in preferences.thresholds = VerdictThresholds(yesAt: 0.9, maybeAt: 0.7) }
        #expect(
            strict.decide(analysis(must: [("Go", "Go"), ("Kafka", "Kafka"), ("AWS", nil)]), for: toronto).verdict == .no
        )
    }

    @Test func whatTheFlagsSayAboutYouComesFirst() {
        let strong = [("Go", "Go" as String?)]
        func flags(
            sponsorship: JobAnalysis.Flags.Sponsorship = .notMentioned,
            clearance: JobAnalysis.Flags.Clearance = .notMentioned, french: JobAnalysis.Flags.French = .notMentioned,
            remote: RemoteScope = .onsite
        ) -> JobAnalysis.Flags {
            .init(sponsorship: sponsorship, clearance: clearance, french: french, remoteScope: remote)
        }
        let cases: [(JobAnalysis, Job, VerdictRule?)] = [
            (analysis(must: strong, flags: flags(sponsorship: .notOffered)), austin, .workAuthorization),
            (analysis(must: strong, flags: flags(sponsorship: .notOffered)), toronto, nil),  // you're a citizen
            (analysis(must: strong, flags: flags(remote: .remoteCountry)), austin, .remoteScope),
            (analysis(must: strong, flags: flags(clearance: .required)), toronto, .clearance),
            (analysis(must: strong, flags: flags(clearance: .obtainable)), austin, .clearance),
            (analysis(must: strong, flags: flags(clearance: .obtainable)), toronto, nil),
            (analysis(must: strong, flags: flags(french: .required)), toronto, .french),
            (analysis(must: strong, flags: flags(french: .asset)), toronto, nil),
        ]
        for (analysis, job, rule) in cases {
            let decision = engine().decide(analysis, for: job)
            if let rule {
                #expect(decision.verdict == .no && decision.rule == rule, "\(analysis.flags) · \(job.location)")
            } else {
                #expect(decision.verdict == .yes, "\(analysis.flags) · \(job.location)")
            }
        }
        let bilingual = engine(languages: english + [EntryFields.Language(language: "French", proficiency: .fluent)])
        #expect(bilingual.decide(analysis(must: strong, flags: flags(french: .required)), for: toronto).verdict == .yes)
        let cleared = engine { _, profile in profile.hasClearance = true }
        #expect(
            cleared.decide(analysis(must: strong, flags: flags(clearance: .required)), for: toronto).verdict == .yes)
    }

    /// SPEC §5.9: informational only; it never changes a verdict.
    @Test func aCanadianCitizenSeesAPossibleTNRoute() {
        let decision = engine().decide(
            analysis(
                must: [("Go", "Go")],
                flags: .init(
                    sponsorship: .notOffered, clearance: .notMentioned, french: .notMentioned, remoteScope: .onsite)
            ), for: austin)
        #expect(decision.verdict == .no && decision.rule == .workAuthorization)
        #expect(decision.reasons.contains { $0.hasPrefix("Possible TN route") })
        let permanentResident = engine { _, profile in profile.authorization[.canada] = .permanentResident }
        #expect(
            !permanentResident.decide(
                analysis(
                    must: [("Go", "Go")],
                    flags: .init(
                        sponsorship: .notOffered, clearance: .notMentioned, french: .notMentioned, remoteScope: .onsite)
                ), for: austin
            )
            .reasons.contains { $0.hasPrefix("Possible TN route") })
    }

    @Test func yearsAndLevelFollowYourPolicy() {
        let strong = [("Go", "Go" as String?)]
        let limited = engine { preferences, _ in
            preferences.maxYearsRequired = 7
            preferences.seniority = [.junior, .mid, .senior]
        }
        let cases: [(JobAnalysis, Verdict, VerdictRule)] = [
            (analysis(must: strong, years: 8), .no, .yearsRequired),  // over your limit
            (analysis(must: strong, years: 5), .yes, .strongMatch),
            (analysis(must: strong, years: 6), .maybe, .yearsAboveYours),  // a year more than you have
            (analysis(must: strong, years: 7), .maybe, .yearsAboveYours),  // within 2 of yours
            (analysis(must: strong, seniority: .staff), .no, .seniority),
            (analysis(must: strong, seniority: .senior), .yes, .strongMatch),
        ]
        for (analysis, verdict, rule) in cases {
            let decision = limited.decide(analysis, for: toronto)
            #expect(decision.verdict == verdict && decision.rule == rule, "\(analysis.yearsRequired ?? -1) \(rule)")
        }
        #expect(engine().decide(analysis(must: strong, years: 9), for: toronto).rule == .yearsAboveYours)
        #expect(engine().decide(analysis(must: strong, years: 9), for: toronto).verdict == .no)
        #expect(engine(years: nil).decide(analysis(must: strong, years: 9), for: toronto).verdict == .yes)
    }

    @Test func thresholdsSurviveMissingFields() throws {
        let decoded = try JSONDecoder().decode(SearchPreferences.self, from: Data("{}".utf8))
        #expect(decoded.thresholds == VerdictThresholds())
        #expect(VerdictThresholds().yesAt == 0.75 && VerdictThresholds().maybeAt == 0.5)
    }
}

@Suite("Ranking")
struct RankingTests {
    /// Success criterion S7: Canadian postings rank above US ones of equal verdict and match.
    @Test func rankingCanadaFirst() {
        let countries: [Country] = [.canada, .unitedStates]
        func rank(_ verdict: Verdict, _ country: Country?, _ match: Double) -> Double {
            Ranking.rank(verdict, country: country, match: match, countries: countries)
        }
        #expect(rank(.yes, .canada, 0.8) > rank(.yes, .unitedStates, 0.8))
        #expect(rank(.maybe, .canada, 0.6) > rank(.maybe, .unitedStates, 0.6))
        #expect(rank(.yes, .canada, 0.6) > rank(.yes, .unitedStates, 1.0))  // country before match
        #expect(rank(.yes, .unitedStates, 0.0) > rank(.maybe, .canada, 1.0))  // verdict before country
        #expect(rank(.yes, .canada, 0.9) > rank(.yes, .canada, 0.8))  // then match
        #expect(rank(.yes, .unitedStates, 0.5) > rank(.yes, nil, 0.5))  // an unknown country after yours
        #expect(rank(.no, .canada, 1.0) < rank(.maybe, nil, 0.0))
        // Your order decides: US first if you put it first.
        #expect(
            Ranking.rank(.yes, country: .unitedStates, match: 0.5, countries: [.unitedStates, .canada])
                > Ranking.rank(.yes, country: .canada, match: 0.5, countries: [.unitedStates, .canada]))
    }
}

@Suite("Screening trail")
struct ScreeningTrailTests {
    /// A search's snippet (Adzuna) can't make a Yes: a strong match is a Maybe that says why, and a
    /// snippet naming no skills says the same. What a snippet does show can still rule a job out.
    @Test func aSnippetCanRuleOutButNotPromise() {
        let strong = analysis(must: [("Go", "Go"), ("Kafka", "Kafka"), ("PostgreSQL", "PostgreSQL")])
        let capped = engine().decide(strong, for: toronto, snippetOnly: true)
        #expect(capped.verdict == .maybe && capped.rule == .snippetOnly)
        #expect(capped.reasons.first == VerdictEngine.snippetReason)
        #expect(engine().decide(strong, for: toronto).verdict == .yes)  // the whole posting: a Yes
        let bare = engine().decide(analysis(must: []), for: toronto, snippetOnly: true)
        #expect(bare.verdict == .maybe && bare.rule == .snippetOnly)
        let weak = engine().decide(
            analysis(must: [("Go", "Go"), ("Rust", nil), ("Scala", nil)]), for: toronto, snippetOnly: true)
        #expect(weak.verdict == .no && weak.rule == .weakMatch)
        let french = analysis(
            must: [("Go", "Go")],
            flags: .init(sponsorship: .notMentioned, clearance: .notMentioned, french: .required, remoteScope: .onsite))
        #expect(engine().decide(french, for: toronto, snippetOnly: true).rule == .french)
    }

    /// Screening knows which sources give snippets: Adzuna's.
    @Test func screeningKnowsWhichSourcesGiveSnippets() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let adzuna = try await SourceRepository(db).add(kind: .adzuna)
        let board = try await SourceRepository(db).add(kind: .lever)
        let context = try await ScreeningContext.load(from: db)
        #expect(context.snippetSources == [adzuna.id])
        var job = toronto
        job.sourceID = adzuna.id
        #expect(context.isSnippet(job))
        job.sourceID = board.id
        #expect(!context.isSnippet(job))
    }

    @Test func everyVerdictIsStoredWithItsRule() async throws {
        let db = try Database(path: ":memory:", device: "0000beef", now: { 1_790_000_000_000 })
        try await Migrator.migrate(db, with: Migrator.bundled())
        let repo = ScreeningRepository(db)
        let job = toronto.id
        #expect(try await repo.trail(for: job).isEmpty)

        try await repo.record(Rejection(rule: .postingAge, reason: "Posted 40 days ago; your limit is 30."), for: job)
        let decision = engine().decide(analysis(must: [("Go", "Go"), ("Rust", nil)]), for: toronto)
        try await repo.record(decision, for: job)

        let trail = try await repo.trail(for: job)
        #expect(trail.map(\.stage) == [.prefilter, .analysis])
        #expect(trail.map(\.verdict) == [.no, .maybe])
        #expect(trail.map(\.ruleID) == ["posting_age", "partial_match"])
        #expect(trail[0].reasons == ["Posted 40 days ago; your limit is 30."] && trail[0].coverage == nil)
        #expect(trail[1].coverage == Coverage(mustCovered: 1, mustTotal: 2, niceCovered: 0, niceTotal: 0))
        #expect(try await repo.trail(for: austin.id).isEmpty)
    }
}

@Suite("Screening trail: overrules and latest")
struct ScreeningLatestTests {
    @Test func theLatestDecisionPerJobAndYourOverrule() async throws {
        let db = try Database(path: ":memory:", device: "0000beef", now: { 1_790_000_000_000 })
        try await Migrator.migrate(db, with: Migrator.bundled())
        let repo = ScreeningRepository(db)
        let decision = engine().decide(analysis(must: [("Go", "Go"), ("Rust", nil)]), for: toronto)
        try await repo.record(decision, for: toronto.id)
        try await repo.record(
            Rejection(rule: .postingAge, reason: "Posted 40 days ago; your limit is 30."), for: austin.id)
        try await repo.recordOverrule(.yes, for: toronto.id)

        let latest = try await repo.latestByJob()
        #expect(latest.count == 2)
        let mine = try #require(latest[toronto.id.rawValue])
        #expect(mine.stage == .user && mine.verdict == .yes && mine.ruleID == nil)
        #expect(mine.reasons == ["You marked it Yes."])
        #expect(latest[austin.id.rawValue]?.ruleID == "posting_age")
        // The trail keeps what screening decided before you.
        #expect(try await repo.trail(for: toronto.id).map(\.stage) == [.analysis, .user])
    }
}

@Suite("Verdict reasons")
struct VerdictReasonTests {
    /// Today shows the deciding reason under the company, so a partial match names the gap.
    @Test func aPartialOrWeakMatchNamesWhatsMissing() {
        let maybe = engine().decide(analysis(must: [("Go", "Go"), ("Rust", nil)]), for: toronto)
        #expect(maybe.reasons.first == "Missing Rust")
        let two = engine().decide(analysis(must: [("Go", "Go"), ("Rust", nil), ("Scala", nil)]), for: toronto)
        #expect(two.reasons.first == "Missing Rust and Scala")
        let many = engine().decide(
            analysis(must: [
                ("Go", "Go"), ("Rust", nil), ("Scala", nil), ("Elixir", nil), ("Legally entitled to work", nil),
            ]),
            for: toronto)
        #expect(many.reasons.first == "Missing Rust, Scala and 1 more")  // conditions aren't skills
        let strong = engine().decide(analysis(must: [("Go", "Go")]), for: toronto)
        #expect(strong.reasons.first == "Covers 1 of 1 must-haves and 0 of 0 nice-to-haves.")
    }
}
