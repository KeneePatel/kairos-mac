import Foundation
import Testing

@testable import Store

private let day0 = Date(milliseconds: 1_790_000_000_000)
private func day(_ n: Double) -> Date { day0.addingTimeInterval(n * 86_400) }

private func lead(_ n: Int, _ company: String, seen: Date = day0) -> Lead {
    Lead(
        id: "lead-\(n)", sourceID: sourceA, company: company, title: "Developer \(n)", location: "Toronto, ON",
        postedAt: day0, firstSeenAt: seen, lastSeenAt: seen)
}

/// Leads (job collection v3, C2): what a search sent as snippets, kept as company names.
@Suite("Leads")
struct LeadRepositoryTests {
    @Test func newLeadsAreCountedAndSeenAgainOnesMoveTheirLastSeenTime() async throws {
        let db = try await migratedDatabase()
        let leads = LeadRepository(db)
        #expect(try await leads.record([lead(1, "Acme"), lead(2, "Acme"), lead(3, "Bolt")]) == 3)
        #expect(try await leads.record([lead(1, "Acme", seen: day(2)), lead(4, "Cobalt", seen: day(1))]) == 1)
        #expect(try await leads.count() == 4)
        let stored = try await leads.leads()
        #expect(stored.first { $0.id == "lead-1" }?.lastSeenAt == day(2))
        #expect(stored.first { $0.id == "lead-1" }?.firstSeenAt == day0)
        // Companies, the most recently seen first, with their counts.
        let companies = try await leads.companies()
        #expect(companies.map(\.company) == ["Acme", "Cobalt", "Bolt"])
        #expect(companies.map(\.count) == [2, 1, 1])
        // Trimmed after 30 days of not being seen.
        #expect(try await leads.deleteOlder(than: day(1)) == 2)
        #expect(try await leads.companies().map(\.company) == ["Acme", "Cobalt"])
    }

    /// Migration 016 archives the jobs Kairos only saw as snippets, unless you acted on them.
    @Test func snippetOnlyJobsAreArchived() async throws {
        let db = try Database(path: ":memory:")
        let bundled = try Migrator.bundled()
        try await Migrator.migrate(db, with: Array(bundled.prefix(15)))
        func insert(_ id: String, kind: String, state: String) async throws {
            try await db.execute(
                """
                INSERT INTO job (id, source_id, url, canonical_url, dedup_key, company, title, state, description_kind, first_seen_at, updated_hlc)
                VALUES (?, ?, ?, ?, ?, 'Acme', 'Engineer', ?, ?, 1, '0')
                """,
                [
                    .text(id), .text(sourceA.lowercased), .text("https://x.example/\(id)"),
                    .text("https://x.example/\(id)"),
                    .text("acme|engineer|" + id), .text(state), .text(kind),
                ])
        }
        try await insert("snippet-new", kind: "snippet", state: "new")
        try await insert("snippet-saved", kind: "snippet", state: "shortlisted")
        try await insert("full-new", kind: "full", state: "new")
        try await Migrator.migrate(db, with: bundled)
        func state(_ id: String) async throws -> String? {
            try await db.query("SELECT state FROM job WHERE id = ?", [.text(id)]).first?.string("state")
        }
        #expect(try await state("snippet-new") == "archived")
        #expect(try await state("snippet-saved") == "shortlisted")
        #expect(try await state("full-new") == "new")
    }
}
