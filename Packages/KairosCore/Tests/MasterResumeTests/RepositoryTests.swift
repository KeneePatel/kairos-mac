import Foundation
import Store
import Testing

@testable import MasterResume

private func repository() async throws -> (MasterResumeRepository, Database) {
    let db = try Database(path: ":memory:")
    try await Migrator.migrate(db, with: Migrator.bundled())
    return (MasterResumeRepository(db), db)
}

private func month(_ text: String) -> YearMonth { YearMonth(text)! }

/// Jordan Rivera is the design's sample persona: fixtures only, never shipped data.
private func sampleHeader() -> ResumeHeader {
    var header = ResumeHeader()
    header.fullName = "Jordan Rivera"
    header.email = "jordan@example.com"
    header.phone = "+14165550123"
    header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
    header.gitHubURL = "https://github.com/jrivera"
    header.city = "Toronto"
    header.region = "ON"
    header.country = "CA"
    header.headline = "Backend developer"
    header.highlights = "Shipped a freight-tracking platform."
    header.totalYears = 5.5
    return header
}

private func northline() -> ResumeEntry {
    ResumeEntry(
        fields: .experience(
            .init(employer: "Northline Freight", title: "Backend Developer II", location: "Toronto, ON")),
        start: month("2021-03"), isCurrent: true,
        bullets: [
            ResumeBullet(
                text: "Cut p95 latency of the tracking API", metrics: ["40% faster"], skills: ["Go", "Postgres"]),
            ResumeBullet(text: "Led the move to event sourcing", skills: ["Kafka"]),
        ])
}

@Suite("Master resume schema")
struct MasterResumeSchemaTests {
    @Test func theFourTablesAreStrictAndSync() async throws {
        let (_, db) = try await repository()
        for table in ["resume_contact", "resume_entry", "resume_bullet", "skill"] {
            let strict = try await db.query("SELECT strict FROM pragma_table_list WHERE name = ?", [.text(table)])
            #expect(strict.first?.int("strict") == 1, "\(table) is not STRICT")
            let columns = try await db.query("SELECT name FROM pragma_table_info(?)", [.text(table)])
                .compactMap { $0.string("name") }
            #expect(columns.contains("updated_hlc") && columns.contains("deleted"), "\(table) can't sync")
        }
    }
}

@Suite("Master resume repository")
struct MasterResumeRepositoryTests {
    @Test func anEmptyResumeIsVersionZero() async throws {
        let (repo, _) = try await repository()
        #expect(try await repo.load() == MasterResume())
    }

    @Test func everySaveAddsOneToTheVersion() async throws {
        let (repo, _) = try await repository()
        let entry = northline()
        let skill = Skill(name: "Go", category: "language")
        #expect(try await repo.saveHeader(sampleHeader()) == 1)
        #expect(try await repo.save([entry]) == 2)
        #expect(try await repo.save([skill]) == 3)
        #expect(try await repo.reorderSkills([skill.id]) == 4)
        #expect(try await repo.deleteSkill(skill.id) == 5)
        #expect(try await repo.deleteEntry(entry.id) == 6)
        #expect(try await repo.load().version == 6)
    }

    @Test func aSavedResumeReadsBackUnchanged() async throws {
        let (repo, _) = try await repository()
        let entry = northline()
        let skills = [
            Skill(name: "Go", category: "language"), Skill(name: "Rust", category: "language", level: .canDiscuss),
        ]
        try await repo.saveHeader(sampleHeader())
        try await repo.save([entry])
        try await repo.save(skills)
        let loaded = try await repo.load()
        #expect(loaded.header == sampleHeader())
        #expect(loaded.entries == [entry])
        #expect(loaded.skills == skills)
        #expect(loaded.version == 3)
    }

    @Test func savingEntriesBeforeTheHeaderStillCounts() async throws {
        let (repo, _) = try await repository()
        try await repo.save([northline()])
        let loaded = try await repo.load()
        #expect(loaded.version == 1 && loaded.header == ResumeHeader())
        #expect(loaded.entries.count == 1)
    }

    @Test(arguments: [
        EntryFields.experience(.init(employer: "Maplepay", title: "Engineer", employmentType: "Contract")),
        .project(
            .init(name: "Tidewatch", role: "Author", tech: ["Swift", "SQLite"], repoURL: "https://github.com/x/y")),
        .education(.init(institution: "University of Waterloo", credential: "BMath", field: "CS", coursework: ["OS"])),
        .certification(.init(name: "AWS SAA", issuer: "Amazon", credentialURL: "https://aws.example/cred")),
        .award(.init(title: "Hackathon winner", organization: "Hack the North")),
        .volunteering(.init(title: "Mentor", organization: "Code Club")),
        .publication(.init(title: "Event sourcing at scale", organization: "InfoQ", url: "https://infoq.example/a")),
        .language(.init(language: "French", proficiency: .conversational)),
        .custom(.init(section: "Talks", title: "Postgres tips")),
    ])
    func everyEntryKindRoundTrips(_ fields: EntryFields) async throws {
        let (repo, _) = try await repository()
        let entry = ResumeEntry(fields: fields, start: month("2019-09"), end: month("2020-04"))
        try await repo.save([entry])
        #expect(try await repo.load().entries == [entry])
    }

    @Test func editsKeepEntryAndBulletIDsAndDroppedBulletsAreTombstoned() async throws {
        let (repo, db) = try await repository()
        var entry = northline()
        try await repo.save([entry])
        let (first, second) = (entry.bullets[0], entry.bullets[1])

        entry.bullets = [second, first]  // reorder
        entry.bullets[1].text = "Cut p95 latency of the tracking API by 40%"  // edit
        entry.bullets.append(ResumeBullet(text: "Mentored two new hires"))  // add
        try await repo.save([entry])
        var loaded = try #require(try await repo.load().entries.first)
        #expect(loaded.id == entry.id)
        #expect(loaded.bullets.map(\.id) == [second.id, first.id, entry.bullets[2].id])
        #expect(loaded.bullets[1].text.hasSuffix("by 40%"))

        entry.bullets.removeFirst()  // drop the event-sourcing bullet
        try await repo.save([entry])
        loaded = try #require(try await repo.load().entries.first)
        #expect(loaded.bullets.map(\.id) == [first.id, entry.bullets[1].id])
        let tombstone = try await db.query(
            "SELECT deleted FROM resume_bullet WHERE id = ?", [.text(second.id.lowercased)])
        #expect(tombstone.first?.bool("deleted") == true)  // kept for sync and for builds that cited it
    }

    @Test func aCurrentEntryHasNoEndDate() async throws {
        let (repo, _) = try await repository()
        var entry = northline()
        entry.end = month("2024-01")  // contradicts isCurrent
        try await repo.save([entry])
        #expect(try await repo.load().entries.first?.end == nil)
    }

    @Test func newEntriesGoLastInTheirKindAndReorderingSticks() async throws {
        let (repo, _) = try await repository()
        let a = ResumeEntry(fields: .project(.init(name: "A")))
        let b = ResumeEntry(fields: .project(.init(name: "B")))
        let job = northline()
        try await repo.save([a])
        try await repo.save([job])
        try await repo.save([b])
        #expect(try await repo.load().entries(.project).map(\.id) == [a.id, b.id])
        try await repo.reorderEntries([b.id, a.id])
        try await repo.save([a])  // editing doesn't move it
        #expect(try await repo.load().entries(.project).map(\.id) == [b.id, a.id])
        #expect(try await repo.load().entries(.experience).map(\.id) == [job.id])
    }

    @Test func aReorderNamingAnUnknownIDChangesNothing() async throws {
        let (repo, _) = try await repository()
        let go = Skill(name: "Go")
        let sql = Skill(name: "SQL")
        try await repo.save([go, sql])
        let stranger = UUID()
        await #expect(throws: MasterResumeError.unknownIDs([stranger])) {
            try await repo.reorderSkills([sql.id, stranger, go.id])
        }
        let loaded = try await repo.load()
        #expect(loaded.skills.map(\.id) == [go.id, sql.id])
        #expect(loaded.version == 1)  // the bump rolled back with the rest
    }

    @Test func deletingAnEntryRemovesItsBulletsToo() async throws {
        let (repo, db) = try await repository()
        let entry = northline()
        try await repo.save([entry, ResumeEntry(fields: .project(.init(name: "Kept")))])
        try await repo.deleteEntry(entry.id)
        #expect(try await repo.load().entries.map(\.kind) == [.project])
        let live = try await db.query("SELECT count(*) AS c FROM resume_bullet WHERE deleted = 0")
        #expect(live.first?.int("c") == 0)
    }

    @Test func aSkillCanMoveBetweenProvenAndCanDiscuss() async throws {
        let (repo, _) = try await repository()
        var kotlin = Skill(name: "Kotlin", category: "language", level: .canDiscuss)
        try await repo.save([kotlin])
        kotlin.level = .proven
        try await repo.save([kotlin])
        #expect(try await repo.load().skills == [kotlin])
    }

    @Test func aKindThisVersionDoesntKnowIsReported() async throws {
        let (repo, db) = try await repository()
        let entry = northline()
        try await repo.save([entry])
        try await db.execute("UPDATE resume_entry SET kind = 'patent'")
        await #expect(throws: StoreError.corruptRow(table: "resume_entry", id: entry.id.lowercased, column: "kind")) {
            try await repo.load()
        }
    }

    @Test func fieldsThatDontMatchTheirKindAreReported() async throws {
        let (repo, db) = try await repository()
        let entry = northline()
        try await repo.save([entry])
        try await db.execute("UPDATE resume_entry SET kind = 'language'")  // experience fields, language kind
        await #expect(throws: StoreError.corruptRow(table: "resume_entry", id: entry.id.lowercased, column: "fields")) {
            try await repo.load()
        }
    }
}

@Suite("Year and month")
struct YearMonthTests {
    @Test(arguments: ["2021-03", "1999-12", "2200-01"])
    func parsesAndPrints(_ text: String) {
        #expect(YearMonth(text)?.description == text)
    }

    @Test(arguments: ["2021-13", "2021-00", "21-03", "2021-3", "2021/03", "1899-01", "", "abcd-ef"])
    func rejects(_ text: String) {
        #expect(YearMonth(text) == nil)
    }

    @Test func ordersAndCountsMonths() {
        #expect(month("2020-12") < month("2021-01"))
        #expect(month("2020-11").months(until: month("2022-02")) == 15)
        #expect(month("2022-02").months(until: month("2020-11")) == -15)
    }

    @Test func aNewIDIsVersion7() {
        #expect(UUID.v7().uuid.6 >> 4 == 7)
    }
}
