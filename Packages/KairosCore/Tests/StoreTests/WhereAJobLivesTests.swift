import Foundation
import Testing

@testable import Store

/// Where a job lives (job collection v3, C1, migration 015): the page to open and the site it was
/// taken from read back with the job, and jobs that linked to Google's search page step aside.
@Suite("Where a job lives")
struct WhereAJobLivesTests {
    @Test func applyLinkAndViaReadBack() async throws {
        let db = try await migratedDatabase()
        var job = sampleJob(1)
        job.applyURL = "https://careers.acme.example/jobs/1"
        job.via = "LinkedIn"
        _ = try await JobRepository(db).upsert(job)
        let stored = try #require(try await JobRepository(db).job(job.id))
        #expect(stored.applyURL == "https://careers.acme.example/jobs/1" && stored.via == "LinkedIn")
        #expect(stored.openURL == "https://careers.acme.example/jobs/1")
        var bare = sampleJob(2)
        bare.applyURL = nil
        _ = try await JobRepository(db).upsert(bare)
        #expect(try await JobRepository(db).job(bare.id)?.openURL == bare.url)
    }

    /// Before v3, Google Jobs jobs linked to Google's search page. Migration 015 archives the ones
    /// you hadn't acted on, so the next fetch stores each posting again with its own page; ones
    /// you acted on, and every other job, stay as they were.
    @Test func jobsLinkedToGooglesSearchPageAreArchived() async throws {
        let db = try Database(path: ":memory:")
        let bundled = try Migrator.bundled()
        try await Migrator.migrate(db, with: Array(bundled.prefix(14)))
        func insert(_ id: String, url: String, state: String) async throws {
            try await db.execute(
                """
                INSERT INTO job (id, source_id, url, canonical_url, dedup_key, company, title, state, first_seen_at, updated_hlc)
                VALUES (?, ?, ?, ?, ?, 'Acme', 'Engineer', ?, 1, '0')
                """,
                [
                    .text(id), .text(sourceA.lowercased), .text(url), .text(url), .text("acme|engineer|" + id),
                    .text(state),
                ])
        }
        try await insert(
            "g-new", url: "https://www.google.com/search?ibp=htl;jobs#htivrt=jobs&htidocid=1", state: "new")
        try await insert(
            "g-applied", url: "https://www.google.com/search?ibp=htl;jobs#htivrt=jobs&htidocid=2", state: "applied")
        try await insert("board", url: "https://boards.greenhouse.io/acme/jobs/3", state: "new")
        try await Migrator.migrate(db, with: bundled)
        func state(_ id: String) async throws -> String? {
            try await db.query("SELECT state FROM job WHERE id = ?", [.text(id)]).first?.string("state")
        }
        #expect(try await state("g-new") == "archived")
        #expect(try await state("g-applied") == "applied")
        #expect(try await state("board") == "new")
    }
}
