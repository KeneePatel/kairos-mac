import Foundation
import Testing

@testable import Store

/// A migrated in-memory database whose wall clock stands still, so stamps differ only by counter.
func migratedDatabase() async throws -> Database {
    let db = try Database(path: ":memory:", device: "0000beef", now: { 1_760_000_000_000 })
    try await Migrator.migrate(db, with: Migrator.bundled())
    return db
}

let sourceA = UUID(uuidString: "0199f0a0-0000-7000-8000-000000000001")!

func sampleJob(
    _ n: Int, state: JobState = .new, verdict: Verdict? = nil, country: Country? = .canada, rank: Double? = nil,
    seenAt: Int64 = 1_760_000_000_000
) -> Job {
    Job(
        canonicalURL: "https://boards.greenhouse.io/acme/jobs/\(n)", sourceID: sourceA,
        url: "https://boards.greenhouse.io/acme/jobs/\(n)?gh_src=x", dedupKey: "acme|engineer \(n)|toronto",
        company: "Acme", title: "Engineer \(n)", country: country, state: state, verdict: verdict, rank: rank,
        firstSeenAt: Date(milliseconds: seenAt))
}

@Suite("Jobs schema")
struct JobsSchemaTests {
    @Test func allFourTablesAreStrictAndCarrySyncColumns() async throws {
        let db = try await migratedDatabase()
        for table in ["source", "search", "job", "run"] {
            let strict = try await db.query("SELECT strict FROM pragma_table_list WHERE name = ?", [.text(table)])
            #expect(strict.first?.int("strict") == 1, "\(table) is not STRICT")
            let columns = try await db.query("SELECT name FROM pragma_table_info(?)", [.text(table)])
                .compactMap { $0.string("name") }
            #expect(columns.contains("updated_hlc") && columns.contains("deleted"), "\(table) can't sync")
        }
        let foreignKeys = try await db.query("SELECT * FROM pragma_foreign_key_list('job')")
        #expect(foreignKeys.isEmpty)  // synced rows can arrive out of order (SPEC §6.1)
    }

    @Test func strictTablesRejectAWrongType() async throws {
        let db = try await migratedDatabase()
        await #expect(throws: StoreError.self) {
            try await db.execute(
                "INSERT INTO run (id, kind, started_at, updated_hlc) VALUES ('r', 'fetch', 'yesterday', 'h')")
        }
    }
}

@Suite("Job repository")
struct JobRepositoryTests {
    @Test func aJobIDIsTheHashOfItsCanonicalURL() {
        let url = "https://boards.greenhouse.io/acme/jobs/123"
        #expect(JobID(canonicalURL: url).rawValue == "3682592ef7498cb9987654e0e7b2bbb4")  // shasum -a 256
        #expect(JobID(canonicalURL: url) == JobID(canonicalURL: url))
        #expect(JobID(canonicalURL: url) != JobID(canonicalURL: url + "4"))
        #expect(JobID(canonicalURL: "").rawValue == "e3b0c44298fc1c149afbf4c8996fb924")
        #expect(sampleJob(1).id == JobID(canonicalURL: sampleJob(1).canonicalURL))
    }

    @Test func aSavedJobReadsBackUnchanged() async throws {
        let repo = JobRepository(try await migratedDatabase())
        var job = sampleJob(1, verdict: .maybe, rank: 0.75)
        job.location = "Toronto, ON (Hybrid)"
        job.city = "Toronto"
        job.region = "ON"
        job.remoteScope = .hybrid
        job.currency = "CAD"
        job.salary = Salary(min: 95_000, max: 120_000, period: .year)
        job.postedAt = Date(milliseconds: 1_759_900_000_000)
        job.descriptionMarkdown = "## About\nBuild things."
        job.verdictSource = .analysis
        let hlc = try await repo.upsert(job)
        job.updatedHLC = hlc
        #expect(try await repo.job(job.id) == job)
    }

    @Test func upsertingAgainReplacesFieldsButKeepsTheFirstSeenTime() async throws {
        let repo = JobRepository(try await migratedDatabase())
        try await repo.upsert(sampleJob(1, seenAt: 1_000))
        var later = sampleJob(1, state: .shortlisted, verdict: .yes, seenAt: 9_000)
        later.title = "Senior Engineer"
        try await repo.upsert(later)
        let stored = try #require(try await repo.job(later.id))
        #expect(stored.title == "Senior Engineer")
        #expect(stored.state == .shortlisted && stored.verdict == .yes)
        #expect(stored.firstSeenAt == Date(milliseconds: 1_000))
        #expect(try await repo.jobs().count == 1)
    }

    @Test func everyWriteStampsANewerHLC() async throws {
        let db = try await migratedDatabase()
        let repo = JobRepository(db)
        let first = try await repo.upsert(sampleJob(1))
        let second = try await repo.upsert(sampleJob(1, state: .skipped))
        let third = try await repo.tombstone(sampleJob(1).id)
        #expect(first < second && second < third)
        #expect(third.device == "0000beef")
        let stored = try await db.query("SELECT updated_hlc FROM job").first?.string("updated_hlc")
        #expect(stored == third.description)
    }

    @Test func oneUpsertOfManyJobsSharesOneStamp() async throws {
        let db = try await migratedDatabase()
        let hlc = try await JobRepository(db).upsert([sampleJob(1), sampleJob(2), sampleJob(3)])
        let stamps = try await db.query("SELECT DISTINCT updated_hlc AS h FROM job").compactMap { $0.string("h") }
        #expect(stamps == [hlc.description])
    }

    @Test func aTombstoneHidesTheJobButKeepsTheRowForSync() async throws {
        let db = try await migratedDatabase()
        let repo = JobRepository(db)
        var job = sampleJob(1)
        job.descriptionMarkdown = "A long posting"
        try await repo.upsert([job, sampleJob(2)])
        try await repo.tombstone(job.id)
        #expect(try await repo.job(job.id) == nil)
        #expect(try await repo.jobs().map(\.id) == [sampleJob(2).id])
        let raw = try #require(try await db.query("SELECT * FROM job WHERE id = ?", [.text(job.id.rawValue)]).first)
        #expect(raw.bool("deleted") == true)
        #expect(raw["description"] == .null)
        #expect(try await repo.knownIDs(among: [job.id]) == [job.id])  // a fetch still skips it
    }

    @Test func upsertingATombstonedJobBringsItBack() async throws {
        let repo = JobRepository(try await migratedDatabase())
        try await repo.upsert(sampleJob(1))
        try await repo.tombstone(sampleJob(1).id)
        try await repo.upsert(sampleJob(1))
        #expect(try await repo.job(sampleJob(1).id) != nil)
    }

    @Test func filtersByStateVerdictAndCountry() async throws {
        let repo = JobRepository(try await migratedDatabase())
        try await repo.upsert([
            sampleJob(1, verdict: .yes, country: .canada),
            sampleJob(2, verdict: .maybe, country: .unitedStates),
            sampleJob(3, verdict: .no, country: .canada),
            sampleJob(4, state: .shortlisted, verdict: .yes, country: .unitedStates),
            sampleJob(5, country: nil),
        ])
        func titles(_ filter: JobFilter) async throws -> [String] {
            try await repo.jobs(matching: filter).map(\.title).sorted()
        }
        #expect(try await titles(JobFilter()).count == 5)
        #expect(try await titles(JobFilter(states: [.new], verdicts: [.yes, .maybe])) == ["Engineer 1", "Engineer 2"])
        #expect(try await titles(JobFilter(countries: [.canada])) == ["Engineer 1", "Engineer 3"])
        #expect(
            try await titles(JobFilter(states: [.shortlisted], countries: [.unitedStates])) == ["Engineer 4"])
        #expect(try await titles(JobFilter(verdicts: [])).isEmpty)
        #expect(try await titles(JobFilter(limit: 2)).count == 2)
    }

    @Test func listsBestRankedFirstThenNewest() async throws {
        let repo = JobRepository(try await migratedDatabase())
        try await repo.upsert([
            sampleJob(1, rank: nil, seenAt: 5_000),
            sampleJob(2, rank: 0.2, seenAt: 1_000),
            sampleJob(3, rank: 0.9, seenAt: 1_000),
            sampleJob(4, rank: nil, seenAt: 9_000),
        ])
        #expect(try await repo.jobs().map(\.title) == ["Engineer 3", "Engineer 2", "Engineer 4", "Engineer 1"])
    }

    @Test func knownIDsWorksAcrossMoreIDsThanOneQueryHolds() async throws {
        let repo = JobRepository(try await migratedDatabase())
        try await repo.upsert([sampleJob(7), sampleJob(777), sampleJob(1_100)])
        let candidates = (0..<1_200).map { sampleJob($0).id }
        #expect(
            try await repo.knownIDs(among: candidates) == [sampleJob(7).id, sampleJob(777).id, sampleJob(1_100).id])
        #expect(try await repo.knownIDs(among: []).isEmpty)
    }

    @Test func aValueThisVersionDoesntKnowIsReportedNotGuessed() async throws {
        let db = try await migratedDatabase()
        let repo = JobRepository(db)
        let job = sampleJob(1)
        try await repo.upsert(job)
        try await db.execute("UPDATE job SET state = 'pinned'")
        await #expect(throws: StoreError.corruptRow(table: "job", id: job.id.rawValue, column: "state")) {
            try await repo.job(job.id)
        }
    }

    @Test func aRowWhoseIDNoLongerMatchesItsURLIsReported() async throws {
        let db = try await migratedDatabase()
        let repo = JobRepository(db)
        try await repo.upsert(sampleJob(1))
        try await db.execute("UPDATE job SET canonical_url = 'https://elsewhere.example/1'")
        await #expect(throws: StoreError.self) { try await repo.jobs() }
    }

    @Test func aPayRangeThatCantBeStoredWritesNothing() async throws {
        let repo = JobRepository(try await migratedDatabase())
        var job = sampleJob(1)
        job.salary = Salary(min: .infinity, max: nil, period: .year)
        await #expect(throws: StoreError.self) { try await repo.upsert([sampleJob(2), job]) }
        #expect(try await repo.jobs().isEmpty)
    }
}

@Suite("Dedup entries and run history")
struct DedupAndRunTests {
    @Test func dedupEntriesMatchTheWholeCompanyNameOnly() async throws {
        let db = try await migratedDatabase()
        var acme = sampleJob(1)
        acme.dedupKey = "acme|engineer|toronto"
        var acmeRobotics = sampleJob(2)
        acmeRobotics.dedupKey = "acme robotics|engineer|toronto"
        var gone = sampleJob(3)
        gone.dedupKey = "acme|designer|"
        let repo = JobRepository(db)
        try await repo.upsert([acme, acmeRobotics, gone])
        try await repo.tombstone(gone.id)
        let entries = try await repo.dedupEntries(companies: ["acme"])
        #expect(entries.map(\.dedupKey) == ["acme|engineer|toronto"])  // not "acme robotics", not the tombstone
        #expect(entries.first?.sourceID == sourceA)
        #expect(try await repo.dedupEntries(companies: []).isEmpty)
    }

    @Test func aRunIsRecordedFromStartToFinish() async throws {
        let runs = RunRepository(try await migratedDatabase())
        let first = try await runs.begin(kind: "fetch")
        let second = try await runs.begin(kind: "screen")
        try await runs.finish(first, stats: #"{"found":3}"#, error: "cancelled")
        let fetches = try await runs.runs(kind: "fetch")
        #expect(fetches.map(\.id) == [first])
        #expect(fetches.first?.stats == #"{"found":3}"# && fetches.first?.error == "cancelled")
        #expect(fetches.first?.finishedAt != nil)
        #expect(try await runs.runs().map(\.id).sorted { $0.lowercased < $1.lowercased } == [first, second])
        #expect(try await runs.runs(kind: "screen").first?.finishedAt == nil)
    }
}
