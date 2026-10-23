import Foundation
import Testing

@testable import Store

private let all = RoleMatcher(families: Set(RoleFamily.allCases))

/// Job collection v2, J3: the kinds of work you look for, matched on whole words with the
/// abbreviations titles use. Titles from the owner's own fetches (2026-10-23).
@Suite("Role families")
struct RoleMatcherTests {
    /// Developer titles in every shape, including the one a literal phrase list missed.
    @Test(arguments: [
        "Software Development Engineer, Navigator", "SDE II, Payments", "Sr. SWE (Backend)", "Full-Stack Developer",
        "Front End Engineer", "Backend Engineer, Platform API", "Software Developer – Senior", "iOS Developer",
        "Programmer Analyst", ".NET Full Stack Developer with Node.JS", "Founding Engineer",
        "Member of Technical Staff", "Embedded Software Developer", "JavaScript Developer",
        "Software Engineer, Integrations (US + Calgary)", "Product Engineer",
    ])
    func softwareTitlesMatch(_ title: String) {
        #expect(RoleMatcher(families: [.software]).matches(title), "\(title)")
    }

    /// Titles that only look like developer jobs.
    @Test(arguments: [
        "Business Development Manager (Player-Coach)", "Sales Development Representative", "VP Business Development",
        "Learning & Development Analyst Student", "Business Developer, Enterprise", "Developer Advocate",
        "Real Estate Developer", "Account Development Specialist", "Solutions Engineer", "Mechanical Engineer",
    ])
    func lookalikesDont(_ title: String) {
        #expect(!all.matches(title), "\(title)")
    }

    /// Each family covers its own titles and not the others'.
    @Test func eachFamilyHasItsTitles() {
        let devops = RoleMatcher(families: [.devops])
        let data = RoleMatcher(families: [.data])
        let qa = RoleMatcher(families: [.qa])
        #expect(devops.matches("Site Reliability Engineer") && devops.matches("Cloud Platform Engineer"))
        #expect(devops.matches("DevOps Engineer with Terraform exp.") && devops.matches("SRE II"))
        #expect(data.matches("Machine Learning Engineer") && data.matches("ML Engineer, Ranking"))
        #expect(
            data.matches("Data Engineer, Temporary") && data.matches("AI Engineer") && data.matches("MLOps Engineer"))
        #expect(qa.matches("QA Automation Engineer") && qa.matches("SDET") && qa.matches("Software Engineer in Test"))
        #expect(qa.matches("Quality Assurance Analyst"))
        #expect(!qa.matches("QA Technician, Food Production") && !qa.matches("Quality Control Inspector"))
        #expect(!devops.matches("Data Engineer") && !data.matches("DevOps Engineer"))
        #expect(!RoleMatcher(families: [.software]).matches("Data Center Technician"))
    }

    /// Your own phrases count too; with no families and no phrases, everything matches.
    @Test func yourPhrasesAndAnOpenMatcher() {
        let mine = RoleMatcher(families: [], extra: ["Technical Writer"])
        #expect(mine.matches("Senior Technical Writer") && !mine.matches("Software Engineer"))
        #expect(RoleMatcher(families: []).isOpen && RoleMatcher(families: []).matches("Anything at all"))
        #expect(!all.isOpen)
    }

    /// Saved search settings without roles get the owner's four (2026-10-23); ones with roles keep
    /// them; a fresh install has none.
    @Test func migrationGivesSavedSettingsTheFourRoles() async throws {
        for (saved, expected) in [
            (#"{"titleInclude":["Developer"]}"#, #"["software","devops","data","qa"]"#),
            (#"{"roles":["qa"]}"#, #"["qa"]"#),
        ] {
            let db = try Database(path: ":memory:", device: "0000beef", now: { 1_760_000_000_000 })
            let all = try Migrator.bundled()
            try await Migrator.migrate(db, with: all.filter { $0.version < 12 })
            try await db.write { connection, stamp in
                try connection.execute(
                    "INSERT INTO setting (key, value, updated_hlc) VALUES ('screening', ?, ?)",
                    [.text(saved), .text(stamp.hlc.description)])
            }
            try await Migrator.migrate(db, with: all)
            let roles = try await db.query("SELECT json_extract(value, '$.roles') AS roles FROM setting").first
            #expect(roles?.string("roles") == expected)
        }
        let fresh = try await migratedDatabase()
        #expect(try await fresh.query("SELECT * FROM setting").isEmpty)
    }

    /// Changing roles changes the fingerprint a board's ETag is kept under.
    @Test func theFingerprintFollowsTheRoles() {
        #expect(all.fingerprint == "data,devops,qa,software")
        #expect(RoleMatcher(families: [.qa], extra: ["Writer"]).fingerprint == "qa,writer")
        #expect(RoleMatcher(families: [.qa]).fingerprint != RoleMatcher(families: [.data]).fingerprint)
    }

    /// What a search asks for: each family's searches, then your phrases, without repeats.
    @Test func searchesComeFromFamiliesThenPhrases() {
        let matcher = RoleMatcher(families: [.software, .qa], extra: ["Software Engineer", "Technical Writer"])
        #expect(matcher.searches.first == "software engineer")
        #expect(matcher.searches.contains("qa engineer") && matcher.searches.last == "technical writer")
        #expect(matcher.searches.count == Set(matcher.searches).count)
        #expect(RoleFamily.allCases.allSatisfy { !$0.title.isEmpty && !$0.searches.isEmpty && !$0.example.isEmpty })
    }
}
