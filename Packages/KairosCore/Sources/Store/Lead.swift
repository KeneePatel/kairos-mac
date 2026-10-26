import Foundation

/// A posting a search sent as a snippet (job collection v3, C2, ADR-018): never a job, since
/// Kairos keeps whole postings only, but a company name worth looking up on public boards, and a
/// count of what Kairos can't read. Local, trimmed after 30 days.
public struct Lead: Sendable, Equatable, Identifiable {
    /// The hash of the posting's canonical URL, like a job's id.
    public let id: String
    public var sourceID: UUID
    public var company: String
    public var title: String
    public var location: String
    public var postedAt: Date?
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(
        id: String, sourceID: UUID, company: String, title: String, location: String = "", postedAt: Date? = nil,
        firstSeenAt: Date, lastSeenAt: Date
    ) {
        self.id = id
        self.sourceID = sourceID
        self.company = company
        self.title = title
        self.location = location
        self.postedAt = postedAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct LeadRepository: Sendable {
    let db: Database

    public init(_ db: Database) { self.db = db }

    /// Stores the leads: a new one as it is, a known one with its last-seen time moved. Returns
    /// how many were new.
    public func record(_ leads: [Lead]) async throws -> Int {
        var new = 0
        for lead in leads {
            let known = try await db.query("SELECT 1 AS n FROM lead WHERE id = ?", [.text(lead.id)]).first != nil
            if !known { new += 1 }
            try await db.execute(
                """
                INSERT INTO lead (id, source_id, company, title, location, posted_at, first_seen_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET company = excluded.company, title = excluded.title,
                    location = excluded.location, posted_at = excluded.posted_at, last_seen_at = excluded.last_seen_at
                """,
                [
                    .text(lead.id), .text(lead.sourceID.lowercased), .text(lead.company), .text(lead.title),
                    .text(lead.location), SQLValue(lead.postedAt), SQLValue(lead.firstSeenAt),
                    SQLValue(lead.lastSeenAt),
                ])
        }
        return new
    }

    /// Companies with leads, the most recently seen first, with how many each has.
    public func companies(limit: Int = 500) async throws -> [(company: String, count: Int, newest: Date)] {
        try await db.query(
            "SELECT company, COUNT(*) AS n, MAX(last_seen_at) AS newest FROM lead GROUP BY company ORDER BY newest DESC, company LIMIT ?",
            [.integer(Int64(limit))]
        ).compactMap { row in
            guard let company = row.string("company"), let newest = row.int64("newest") else { return nil }
            return (company, row.int("n") ?? 0, Date(milliseconds: newest))
        }
    }

    public func leads() async throws -> [Lead] {
        try await db.query("SELECT * FROM lead ORDER BY last_seen_at DESC, id").compactMap { row in
            guard let id = row.string("id"), let source = row.string("source_id").flatMap(UUID.init(uuidString:)),
                let first = row.int64("first_seen_at"), let last = row.int64("last_seen_at")
            else { return nil }
            return Lead(
                id: id, sourceID: source, company: row.string("company") ?? "", title: row.string("title") ?? "",
                location: row.string("location") ?? "", postedAt: row.int64("posted_at").map(Date.init(milliseconds:)),
                firstSeenAt: Date(milliseconds: first), lastSeenAt: Date(milliseconds: last))
        }
    }

    public func count() async throws -> Int {
        try await db.query("SELECT COUNT(*) AS n FROM lead").first?.int("n") ?? 0
    }

    /// Drops leads not seen since `date`. Returns how many.
    @discardableResult
    public func deleteOlder(than date: Date) async throws -> Int {
        let going =
            try await db.query("SELECT COUNT(*) AS n FROM lead WHERE last_seen_at < ?", [SQLValue(date)])
            .first?.int("n") ?? 0
        try await db.execute("DELETE FROM lead WHERE last_seen_at < ?", [SQLValue(date)])
        return going
    }
}
