import Foundation
import Testing

@testable import MasterResume

private func month(_ text: String) -> YearMonth { YearMonth(text)! }

private func validHeader() -> ResumeHeader {
    var header = ResumeHeader()
    header.fullName = "Jordan Rivera"
    header.email = "jordan@example.com"
    header.phone = "416-555-0123"
    header.linkedInURL = "linkedin.com/in/jordan-rivera"
    header.totalYears = 3
    return header
}

private func readyResume(totalYears: Double = 3, proven: Int = 5) -> MasterResume {
    var header = Validator.validate(validHeader()).header
    header.totalYears = totalYears
    let job = ResumeEntry(
        fields: .experience(.init(employer: "Northline Freight", title: "Backend Developer")),
        start: month("2022-10"), isCurrent: true, bullets: [ResumeBullet(text: "Built the tracking API")])
    let skills = (0..<proven).map { Skill(name: "Skill \($0)") } + [Skill(name: "Rust", level: .canDiscuss)]
    return MasterResume(header: header, entries: [job], skills: skills, version: 4)
}

@Suite("Phone numbers")
struct PhoneNumberTests {
    @Test(arguments: [
        ("416-555-0123", "+14165550123"),
        ("(416) 555 0123", "+14165550123"),
        ("416.555.0123", "+14165550123"),
        ("1 416 555 0123", "+14165550123"),
        ("+1 (604) 555-0199", "+16045550199"),
        ("+44 20 7946 0958", "+442079460958"),
        ("0044 20 7946 0958", "+442079460958"),
        ("+91 98765 43210", "+919876543210"),
    ])
    func normalizesToE164(input: String, expected: String) {
        #expect(PhoneNumber.e164(input) == expected)
    }

    @Test(arguments: [
        "", "555-0123", "123-555-0123",  // a North American area code can't start with 0 or 1
        "416-055-0123",  // nor can the exchange
        "416-555-0123 ext 4", "+1 416 555 012", "+1234", "+12345678901234567", "phone", "2 416 555 0123",
    ])
    func rejects(_ input: String) {
        #expect(PhoneNumber.e164(input) == nil)
    }
}

@Suite("Header validation")
struct HeaderValidationTests {
    @Test func aCompleteHeaderIsCleanedAndValid() {
        var header = validHeader()
        header.email = "  Jordan@Example.com "
        header.gitHubURL = "github.com/jrivera"
        header.portfolioURL = "jordan.dev"
        let result = Validator.validate(header)
        #expect(result.issues.isEmpty)
        #expect(result.header.email == "Jordan@Example.com")
        #expect(result.header.phone == "+14165550123")
        #expect(result.header.linkedInURL == "https://www.linkedin.com/in/jordan-rivera")
        #expect(result.header.gitHubURL == "https://github.com/jrivera")
        #expect(result.header.portfolioURL == "https://jordan.dev")
    }

    @Test func missingRequiredFieldsAreEachNamed() {
        let result = Validator.validate(ResumeHeader())
        #expect(result.issues.map(\.field) == [.fullName, .email, .phone, .linkedIn, .totalYears])
        #expect(result.issues.allSatisfy { $0.kind == .missing })
    }

    @Test(arguments: [
        "jordan", "jordan@", "@example.com", "jordan@example", "jordan @example.com", "jordan@@example.com",
        "jordan@example.c", "jordan@.example.com",
    ])
    func rejectsMalformedEmail(_ email: String) {
        var header = validHeader()
        header.email = email
        #expect(Validator.validate(header).issues.map(\.field) == [.email])
    }

    @Test(arguments: [
        ("https://www.linkedin.com/in/jordan-rivera", "https://www.linkedin.com/in/jordan-rivera"),
        ("https://ca.linkedin.com/in/jordan-rivera/", "https://www.linkedin.com/in/jordan-rivera"),
        ("http://linkedin.com/in/jordan-rivera?trk=x", "https://www.linkedin.com/in/jordan-rivera"),
        ("www.linkedin.com/in/Jordan_Rivera-42", "https://www.linkedin.com/in/Jordan_Rivera-42"),
    ])
    func tidiesLinkedInURLs(input: String, expected: String) {
        var header = validHeader()
        header.linkedInURL = input
        let result = Validator.validate(header)
        #expect(result.issues.isEmpty)
        #expect(result.header.linkedInURL == expected)
    }

    @Test(arguments: [
        "https://www.linkedin.com/company/northline", "https://www.linkedin.com/in/", "https://example.com/in/jordan",
        "jordan-rivera", "https://www.linkedin.com/in/jo",
    ])
    func rejectsWhatIsntAProfileURL(_ url: String) {
        var header = validHeader()
        header.linkedInURL = url
        #expect(Validator.validate(header).issues.map(\.field) == [.linkedIn])
    }

    @Test(arguments: [
        ("https://github.com/jrivera", "https://github.com/jrivera"),
        ("github.com/j-rivera/", "https://github.com/j-rivera"),
        ("http://www.github.com/JRivera", "https://github.com/JRivera"),
    ])
    func tidiesGitHubURLs(input: String, expected: String) {
        var header = validHeader()
        header.gitHubURL = input
        #expect(Validator.validate(header).header.gitHubURL == expected)
    }

    @Test(arguments: [
        "https://github.com/jrivera/kairos", "https://github.com/-jrivera", "https://github.com/j--rivera",
        "https://gitlab.com/jrivera", String(repeating: "a", count: 40),
    ])
    func rejectsWhatIsntAGitHubProfile(_ url: String) {
        var header = validHeader()
        header.gitHubURL = url
        #expect(Validator.validate(header).issues.map(\.field) == [.gitHub])
    }

    @Test(arguments: ["http://jordan.dev", "ftp://jordan.dev", "https://", "https://localhost", "not a url"])
    func aPortfolioMustBeAnHTTPSAddress(_ url: String) {
        var header = validHeader()
        header.portfolioURL = url
        #expect(Validator.validate(header).issues.map(\.field) == [.portfolio])
    }

    @Test func emptyOptionalURLsBecomeNil() {
        var header = validHeader()
        header.gitHubURL = "  "
        header.portfolioURL = ""
        let result = Validator.validate(header)
        #expect(result.issues.isEmpty)
        #expect(result.header.gitHubURL == nil && result.header.portfolioURL == nil)
    }

    @Test(arguments: [-1.0, 61, .nan])
    func totalYearsMustBeSensible(_ years: Double) {
        var header = validHeader()
        header.totalYears = years
        #expect(Validator.validate(header).issues.map(\.field) == [.totalYears])
    }
}

@Suite("Build readiness")
struct BuildReadinessTests {
    let now = month("2025-10")

    @Test func aCompleteResumeIsReady() {
        let readiness = Validator.readiness(readyResume(), now: now)
        #expect(readiness.isReady)
        #expect(readiness.missing.isEmpty && readiness.warnings.isEmpty)
    }

    @Test func anEmptyResumeListsEverythingMissing() {
        let readiness = Validator.readiness(MasterResume(), now: now)
        #expect(
            readiness.missing == [
                .header(.init(field: .fullName, kind: .missing)), .header(.init(field: .email, kind: .missing)),
                .header(.init(field: .phone, kind: .missing)), .header(.init(field: .linkedIn, kind: .missing)),
                .header(.init(field: .totalYears, kind: .missing)), .experienceBullet,
                .provenSkills(have: 0, need: 5),
            ])
        #expect(!readiness.isReady)
        #expect(readiness.missing.last?.message == "Mark at least 5 skills as Proven (you have 0).")
    }

    @Test func canDiscussSkillsDontCountTowardTheFive() {
        let readiness = Validator.readiness(readyResume(proven: 4), now: now)
        #expect(readiness.missing == [.provenSkills(have: 4, need: 5)])
    }

    @Test func anExperienceWithoutBulletsIsNotEnough() {
        var resume = readyResume()
        resume.entries[0].bullets = [ResumeBullet(text: "   ")]
        resume.entries.append(
            ResumeEntry(fields: .project(.init(name: "Side project")), bullets: [ResumeBullet(text: "x")]))
        #expect(Validator.readiness(resume, now: now).missing == [.experienceBullet])
    }

    @Test func aMalformedFieldBlocksABuildToo() {
        var resume = readyResume()
        resume.header.email = "jordan@"
        #expect(Validator.readiness(resume, now: now).missing == [.header(.init(field: .email, kind: .invalid))])
    }

    @Test func aMalformedOptionalLinkIsLeftOffRatherThanBlocking() {
        var resume = readyResume()
        resume.header.gitHubURL = "gitlab.com/jrivera"
        resume.header.portfolioURL = "http://jordan.dev"
        let readiness = Validator.readiness(resume, now: now)
        #expect(readiness.isReady)
        #expect(
            readiness.warnings == [
                "Your GitHub link is left off resumes until it's a profile address, like https://github.com/your-name.",
                "Your portfolio is left off resumes until its address starts with https://.",
            ])
    }

    @Test func warnsWhenTotalYearsDisagreesWithTheDatesByMoreThanAYear() {
        // The fixture's one job runs 2022-10 to now (2025-10): 3 years.
        #expect(Validator.readiness(readyResume(totalYears: 3.9), now: now).warnings.isEmpty)
        #expect(Validator.readiness(readyResume(totalYears: 2.1), now: now).warnings.isEmpty)
        let warnings = Validator.readiness(readyResume(totalYears: 5), now: now).warnings
        #expect(warnings == ["You entered 5 years of experience, but your work dates add up to 3. Check one of them."])
        #expect(Validator.readiness(readyResume(totalYears: 5), now: now).isReady)  // a warning never blocks
    }

    @Test func overlappingJobsCountOnce() {
        var resume = readyResume(totalYears: 3)
        resume.entries.append(
            ResumeEntry(
                fields: .experience(.init(employer: "Maplepay", title: "Contractor")), start: month("2023-01"),
                end: month("2024-01"), bullets: [ResumeBullet(text: "Freelance work")]))
        #expect(Validator.experienceYears(resume.entries, now: now) == 3)
        #expect(Validator.readiness(resume, now: now).warnings.isEmpty)
    }

    @Test func undatedExperienceSkipsTheYearsCheck() {
        var resume = readyResume(totalYears: 20)
        resume.entries[0].start = nil
        #expect(Validator.readiness(resume, now: now).warnings.isEmpty)
    }
}

@Suite("Validation messages")
struct ValidationMessageTests {
    @Test(arguments: ResumeField.allCases)
    func everyFieldHasAMessageForEachProblem(_ field: ResumeField) {
        for kind in [FieldIssue.Kind.missing, .invalid] {
            #expect(!FieldIssue(field: field, kind: kind).message.isEmpty)
        }
    }

    @Test func linkMessagesNameTheirSite() {
        #expect(FieldIssue(field: .linkedIn, kind: .invalid).message.contains("LinkedIn"))
        #expect(FieldIssue(field: .gitHub, kind: .invalid).message.contains("GitHub"))
        #expect(FieldIssue(field: .portfolio, kind: .invalid).message.contains("portfolio"))
    }

    @Test func onlyTheLinksAreOptional() {
        #expect(ResumeField.allCases.filter(\.isOptional) == [.gitHub, .portfolio])
    }

    @Test func theCurrentMonthComesFromTheCalendar() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(YearMonth.containing(Date(timeIntervalSince1970: 1_760_000_000), calendar: utc) == month("2025-10"))
        #expect(YearMonth.containing(Date(timeIntervalSince1970: 0), calendar: utc) == month("1970-01"))
    }
}
