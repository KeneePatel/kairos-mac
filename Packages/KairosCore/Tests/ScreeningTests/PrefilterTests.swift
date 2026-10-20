import Foundation
import MasterResume
import Store
import Testing

@testable import Screening

// Sample persona and made-up postings: fixtures only.

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let source = UUID(uuidString: "0199f0a0-0000-7000-8000-000000000001")!
private let english = [EntryFields.Language(language: "English", proficiency: .native)]

private func job(
    _ title: String = "Software Developer", company: String = "Harbourline Logistics", location: String = "Toronto, ON",
    country: Country? = .canada, region: String? = "ON", remote: RemoteScope = .onsite, daysOld: Double? = 2,
    description: String? = "Build backend services in Go and PostgreSQL."
) -> Job {
    Job(
        canonicalURL: "https://jobs.example.com/\(title.hashValue)", sourceID: source,
        url: "https://jobs.example.com/1",
        dedupKey: "k", company: company, title: title, location: location, region: region, country: country,
        remoteScope: remote, postedAt: daysOld.map { now.addingTimeInterval(-$0 * 86_400) },
        descriptionMarkdown: description, firstSeenAt: now)
}

/// A Canadian citizen who would need a visa for the US, with no clearance: the persona's profile.
private func prefilter(
    languages: [EntryFields.Language] = english, applied: [AppliedJob] = [],
    _ change: (inout SearchPreferences, inout WorkProfile) -> Void = { _, _ in }
) -> Prefilter {
    var preferences = SearchPreferences()
    var profile = WorkProfile(authorization: [.canada: .citizen, .unitedStates: .needsSponsorship])
    change(&preferences, &profile)
    return Prefilter(preferences: preferences, profile: profile, languages: languages, applied: applied, now: now)
}

/// Runs a table: each case is a job and the rule expected to reject it (nil: it passes).
private func check(
    _ filter: Prefilter, _ cases: [(Job, PrefilterRule?)], sourceLocation: SourceLocation = #_sourceLocation
) {
    for (job, expected) in cases {
        #expect(
            filter.rejection(for: job)?.rule == expected, "\(job.title) · \(job.location) · \(job.company)",
            sourceLocation: sourceLocation)
    }
}

@Suite("Prefilter rules")
struct PrefilterTests {
    @Test func defaultsRejectNothing() {
        let filter = prefilter()
        check(
            filter,
            [
                (job(), nil), (job("Staff Engineer", daysOld: 900), nil),
                (job("Sales Manager", company: "Anyco", country: nil, region: nil), nil),
                (job(description: "10+ years of experience required."), nil),
                (job(description: nil), nil),
            ])
    }

    @Test func titleMustMatchOneIncludedPhrase() {
        let filter = prefilter { preferences, _ in
            preferences.titleInclude = ["developer", "software engineer", "backend"]
        }
        check(
            filter,
            [
                (job("Software Developer"), nil), (job("Senior Software Engineer"), nil),
                (job("Backend Engineer"), nil),
                (job("Data Analyst"), .titleInclude),
                (job("Sales Development Representative"), .titleInclude),  // "development" isn't "developer"
                (job("Software Engineering Intern"), .titleInclude),
            ])
    }

    @Test func titleWithAnExcludedPhraseIsOut() {
        let filter = prefilter { preferences, _ in
            preferences.titleInclude = ["developer", "engineer"]
            preferences.titleExclude = ["manager", "sales", "c++"]
        }
        check(
            filter,
            [
                (job("Engineering Manager"), .titleInclude),  // no included phrase comes first
                (job("Sales Engineer"), .titleExclude), (job("Software Developer"), nil),
                (job("Salesforce Developer"), nil),  // "sales" is a whole word only
                (job("C++ Developer"), .titleExclude), (job("Developer, Sales Tools"), .titleExclude),
            ])
    }

    @Test func seniorityOutsideYourLevelsIsOut() {
        let filter = prefilter { preferences, _ in preferences.seniority = [.junior, .mid, .senior] }
        check(
            filter,
            [
                (job("Senior Backend Developer"), nil), (job("Sr. Software Engineer"), nil),
                (job("Software Engineer II"), nil), (job("Software Developer"), nil),  // no level named
                (job("Staff Software Engineer"), .seniority), (job("Principal Engineer"), .seniority),
                (job("Software Engineering Intern"), .seniority), (job("Director of Engineering"), .seniority),
                (job("Engineering Manager"), .seniority),
            ])
    }

    @Test func titlesNameTheirLevel() {
        let cases: [(String, Seniority?)] = [
            ("Software Developer", nil), ("Junior Developer", .junior), ("Jr. Backend Engineer", .junior),
            ("New Grad Software Engineer", .junior), ("Intermediate Developer", .mid), ("Software Engineer II", .mid),
            ("Software Engineer III", .senior), ("Senior Staff Engineer", .staff), ("Lead Developer", .lead),
            ("Software Engineer, Co-op (Winter 2027)", .intern), ("VP, Engineering", .director),
            ("Head of Platform", .director), ("Product Manager", nil),  // a role, not a level
            ("Engineering Manager", .manager), ("Principal Software Engineer", .principal),
        ]
        for (title, level) in cases {
            #expect(Seniority.of(title: title) == level, "\(title)")
        }
    }

    /// A team or product area called "Management" doesn't make a role a manager's (found in a real
    /// run: Ramp's "Senior Backend Engineer | Token Spend Management" read as Manager level).
    @Test func aTeamCalledManagementIsntAManagerLevel() {
        let cases: [(String, Seniority?)] = [
            ("Software Engineer, Spend Management", nil), ("Senior Backend Engineer | Token Spend Management", .senior),
            ("Identity & Access Management Engineer II", .mid), ("Engineering Manager, Revenue Management", .manager),
        ]
        for (title, level) in cases {
            #expect(Seniority.of(title: title) == level, "\(title)")
        }
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
                (job(description: nil), nil),
            ])
    }

    @Test func locationOutsideYourCountriesOrRegionsIsOut() {
        let filter = prefilter { preferences, _ in
            preferences.countries = [.canada]
            preferences.regions = ["CA": ["ON", "BC"]]
        }
        check(
            filter,
            [
                (job(), nil), (job(location: "Montréal, QC", region: "QC"), .location),
                (job(location: "Vancouver, BC", region: "BC", remote: .hybrid), nil),
                (job(location: "Seattle, WA", country: .unitedStates, region: "WA"), .location),
                (job(location: "Remote (Canada)", region: nil, remote: .remoteCountry), nil),
                (job(location: "Remote", country: nil, region: nil, remote: .remote), nil),
                (job(location: "Somewhere", country: nil, region: nil, remote: .unknown), nil),  // can't tell
            ])
        let onsiteOnly = prefilter { preferences, _ in preferences.remoteAllowed = false }
        check(
            onsiteOnly,
            [
                (job(location: "Remote (Canada)", region: nil, remote: .remoteCountry), .location),
                (job(location: "Hybrid, Toronto", remote: .hybrid), nil),
            ])
    }

    /// "Remote (US only)" needs you to live and work in the US.
    @Test func remoteOnlyInACountryYouCantWorkInIsOut() {
        let filter = prefilter()
        let us = (country: Country.unitedStates, region: String?.none)
        check(
            filter,
            [
                (
                    job(location: "Remote (US only)", country: us.country, region: us.region, remote: .remoteCountry),
                    .remoteScope
                ),
                (job(location: "Remote (Canada)", region: nil, remote: .remoteCountry), nil),
                (
                    job(
                        location: "Remote", country: nil, region: nil, remote: .remote,
                        description: "This is a fully remote role. Candidates must reside in the United States."),
                    .remoteScope
                ),
                (job(location: "Remote - North America", country: nil, region: nil, remote: .remoteAnywhere), nil),
                (
                    job(
                        location: "Remote", country: nil, region: nil, remote: .remote,
                        description: "Remote within Canada or the US."), nil
                ),
            ])
        let unknownUS = prefilter { _, profile in profile.authorization[.unitedStates] = nil }
        check(
            unknownUS,
            [(job(location: "Remote (US only)", country: .unitedStates, region: nil, remote: .remoteCountry), nil)])
        let usCitizen = prefilter { _, profile in profile.authorization[.unitedStates] = .citizen }
        check(
            usCitizen,
            [(job(location: "Remote (US only)", country: .unitedStates, region: nil, remote: .remoteCountry), nil)])
    }

    @Test func noSponsorshipWhereYouNeedItIsOut() {
        let filter = prefilter()
        func us(_ text: String) -> Job {
            job(location: "Austin, TX", country: .unitedStates, region: "TX", description: text)
        }
        check(
            filter,
            [
                (us("We are unable to sponsor visas for this role."), .workAuthorization),
                (
                    us("Must be legally authorized to work in the United States without sponsorship."),
                    .workAuthorization
                ),
                (us("Visa sponsorship is available."), nil), (us("Build backend services."), nil),
                (job(description: "Must be authorized to work in Canada."), nil),  // you're a citizen there
                (us("Sponsorship is not available now or in the future."), .workAuthorization),
            ])
        let canadaPermit = prefilter { _, profile in profile.authorization[.canada] = .needsSponsorship }
        check(canadaPermit, [(job(description: "No sponsorship available."), .workAuthorization)])
        let greenCard = prefilter { _, profile in profile.authorization[.unitedStates] = .permanentResident }
        check(
            greenCard,
            [
                (us("Must be a U.S. citizen."), .workAuthorization),
                (us("Must be authorized to work in the US without sponsorship."), nil),
            ])
    }

    @Test func aClearanceYouDontHoldIsOut() {
        let filter = prefilter()
        func us(_ text: String) -> Job {
            job(location: "Arlington, VA", country: .unitedStates, region: "VA", description: text)
        }
        check(
            filter,
            [
                (us("Active Top Secret clearance required."), .clearance), (us("TS/SCI with polygraph."), .clearance),
                (us("Must be able to obtain a security clearance."), .clearance),
                (us("No security clearance required."), nil), (us("Work on our inventory clearance tools."), nil),
                (job(description: "Must be able to obtain Government of Canada Reliability Status."), nil),
            ])
        let cleared = prefilter { _, profile in profile.hasClearance = true }
        check(cleared, [(us("Active Secret clearance required."), nil)])
    }

    @Test func frenchWhenYouDontSpeakItIsOut() {
        let filter = prefilter()
        let french = """
            Nous recherchons un développeur backend pour rejoindre notre équipe à Montréal. Vous travaillerez avec \
            nous sur des services en Go et PostgreSQL. Le poste est hybride, deux jours par semaine au bureau. Nous \
            offrons des avantages sociaux complets et un environnement de travail flexible pour les membres de \
            l'équipe.
            """
        check(
            filter,
            [
                (job(description: "Bilingual (English/French) required."), .french),
                (job(description: "French is an asset."), nil),
                (job("Développeur backend", description: french), .french),
                (job(description: "Fluency in French is required to support our Quebec clients."), .french),
                (job(description: "Maîtrise du français exigée."), .french),
                (
                    job(
                        location: "Miami, FL", country: .unitedStates, region: "FL",
                        description: "Bilingual Spanish is a plus."), nil
                ),
                (job(description: "You must be bilingual."), .french),  // in Canada, bilingual means French
                (job(description: "Build backend services in Go."), nil),
            ])
        let speaksFrench = prefilter(
            languages: english + [EntryFields.Language(language: "French", proficiency: .conversational)])
        check(
            speaksFrench,
            [(job(description: "Bilingual (English/French) required."), nil), (job(description: french), nil)])
    }

    @Test func blacklistedCompaniesAreOut() {
        let filter = prefilter { preferences, _ in preferences.blacklist = ["Amazon", "Revature"] }
        check(
            filter,
            [
                (job(company: "Amazon Web Services"), .blacklist),
                (job(company: "Amazon.com Services LLC"), .blacklist),
                (job(company: "REVATURE"), .blacklist), (job(company: "Amazonia Labs"), nil), (job(), nil),
            ])
    }

    @Test func postingsOlderThanYourLimitAreOut() {
        let filter = prefilter { preferences, _ in preferences.maxAgeDays = 30 }
        check(
            filter,
            [
                (job(daysOld: 2), nil), (job(daysOld: 30), nil), (job(daysOld: 31), .postingAge),
                (job(daysOld: 400), .postingAge), (job(daysOld: nil), nil),  // no date: can't tell
            ])
    }

    @Test func aJobYouAppliedToIsOut() {
        let applied = [AppliedJob(company: "Harbourline Logistics Inc.", title: "Software Developer, Backend")]
        let filter = prefilter(applied: applied)
        check(
            filter,
            [
                (job("Backend Software Developer"), .alreadyApplied),
                (job("software developer - backend", company: "HARBOURLINE LOGISTICS"), .alreadyApplied),
                (job("Software Developer, Backend", company: "Rivet Studio"), nil),
                (job("Senior Software Developer, Payments"), nil), (job("Data Engineer"), nil),
            ])
        check(prefilter(), [(job("Backend Software Developer"), nil)])
    }

    /// SPEC §5.2: the first failing rule wins, in order, and is recorded with a reason you can read.
    @Test func theFirstFailingRuleIsRecorded() throws {
        let filter = prefilter(applied: [AppliedJob(company: "Amazon", title: "Sales Manager")]) { preferences, _ in
            preferences.titleExclude = ["manager"]
            preferences.blacklist = ["Amazon"]
            preferences.maxAgeDays = 7
            preferences.maxYearsRequired = 3
        }
        let everything = job(
            "Sales Manager", company: "Amazon", daysOld: 90, description: "10+ years of experience. French required.")
        #expect(filter.rejection(for: everything)?.rule == .titleExclude)
        let rejection = try #require(filter.rejection(for: job(description: "8+ years of experience.")))
        #expect(rejection.rule == .yearsRequired && rejection.reason == "Asks for 8+ years; your limit is 3.")
        #expect(
            PrefilterRule.allCases.map(\.rawValue) == [
                "title_include", "title_exclude", "seniority", "years_required", "location", "remote_scope",
                "work_authorization", "clearance", "french", "blacklist", "posting_age", "already_applied",
            ])
    }

    @Test func preferencesSurviveMissingFields() throws {
        let decoded = try JSONDecoder().decode(SearchPreferences.self, from: Data(#"{"maxYearsRequired":4}"#.utf8))
        #expect(
            decoded.maxYearsRequired == 4 && decoded.countries == [.canada, .unitedStates] && decoded.remoteAllowed)
        var preferences = SearchPreferences()
        preferences.seniority = [.junior]
        preferences.regions = ["CA": ["ON"]]
        let again = try JSONDecoder().decode(SearchPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(again == preferences)
        let profile = WorkProfile(authorization: [.canada: .citizen], hasClearance: true)
        #expect(try JSONDecoder().decode(WorkProfile.self, from: JSONEncoder().encode(profile)) == profile)
    }
}

@Suite("Years parser")
struct YearsParserTests {
    @Test func findsTheYearsAPostingRequires() {
        let cases: [(String, Int?)] = [
            ("5+ years of experience with Go", 5), ("3-5 years of experience", 3), ("3 to 5 years experience", 3),
            ("At least seven years building web services", 7), ("Minimum of 4 yrs. professional experience", 4),
            ("Five (5) years of relevant experience", 5), ("3+ years’ experience in fintech", 3),
            ("Experience: 6 years minimum", 6), ("2+ years of Python. 6+ years of software development experience.", 6),
            ("5 ans et plus d'expérience", 5), ("Au moins 7 ans d’expérience en développement", 7),
            ("De 3 à 5 ans d'expérience", 3),
        ]
        for (text, years) in cases {
            #expect(YearsParser.requiredYears(in: text) == years, "\(text)")
        }
    }

    @Test func ignoresYearsThatArentARequirement() {
        let cases = [
            "We were founded 12 years ago.", "Over the past 3 years we've grown 10x.",
            "401(k) match after 1 year of service.", "For over 20 years, we've helped carriers move freight.",
            "Nice to have: 10+ years with Kubernetes", "8+ years of experience preferred.",
            "Build backend services in Go.", "A 2-year contract.",
        ]
        for text in cases {
            #expect(YearsParser.requiredYears(in: text) == nil, "\(text)")
        }
    }

    @Test func skipsPreferredSections() {
        let posting = """
            ## Bonus points
            - 10+ years in fintech

            ## Requirements
            - 4+ years of experience building APIs
            **Nice to have**
            - 9+ years with Kafka
            """
        #expect(YearsParser.requiredYears(in: posting) == 4)
    }
}
