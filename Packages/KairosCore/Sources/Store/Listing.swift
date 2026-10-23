import CryptoKit
import Foundation

/// One source's copy of a job (SPEC §6.2, `listing`): the company's board, an Adzuna advert. A job
/// keeps every listing it's found under; its id comes from the listing's canonical URL, like a
/// job's, so the first listing of a job shares the job's id.
public struct Listing: Sendable, Equatable, Identifiable {
    public let id: JobID
    public var jobID: JobID
    public var sourceID: UUID
    public var url: String
    public let canonicalURL: String
    public var title: String
    public var company: String
    public var location: String
    public var postedAt: Date?
    /// Markdown. It stays on this Mac; the job's copy is the one that syncs.
    public var descriptionMarkdown: String?
    public var descriptionKind: DescriptionKind
    /// Of the title, the place and the text: when it changes, the posting was edited.
    public var contentHash: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    /// Complete answers from its source in a row that didn't list it.
    public var missingRuns: Int
    public var closedAt: Date?

    public init(
        canonicalURL: String, jobID: JobID, sourceID: UUID, url: String, title: String, company: String,
        location: String, postedAt: Date?, descriptionMarkdown: String?, descriptionKind: DescriptionKind,
        firstSeenAt: Date, lastSeenAt: Date? = nil, missingRuns: Int = 0, closedAt: Date? = nil
    ) {
        id = JobID(canonicalURL: canonicalURL)
        self.canonicalURL = canonicalURL
        self.jobID = jobID
        self.sourceID = sourceID
        self.url = url
        self.title = title
        self.company = company
        self.location = location
        self.postedAt = postedAt
        self.descriptionMarkdown = descriptionMarkdown
        self.descriptionKind = descriptionKind
        contentHash = Self.hash(title: title, location: location, description: descriptionMarkdown)
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt ?? firstSeenAt
        self.missingRuns = missingRuns
        self.closedAt = closedAt
    }

    public var isOpen: Bool { closedAt == nil }

    /// Whitespace doesn't count: a board that reflows its HTML hasn't edited the posting.
    public static func hash(title: String, location: String, description: String?) -> String {
        let text = [title, location, description ?? ""]
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Something that happened to a job (SPEC §6.2, `job_event`).
public struct JobEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// First stored.
        case found
        /// Another source lists it too.
        case postedElsewhere = "posted_elsewhere"
        /// Its text, title or place changed.
        case changed
        /// A full posting replaced a snippet.
        case upgraded
        case closed
        case reopened
    }

    public let jobID: JobID
    public let at: Date
    public let kind: Kind
    public let sourceID: UUID?
    public let detail: String?

    public init(jobID: JobID, at: Date, kind: Kind, sourceID: UUID? = nil, detail: String? = nil) {
        self.jobID = jobID
        self.at = at
        self.kind = kind
        self.sourceID = sourceID
        self.detail = detail
    }
}

/// Reads listings and job events. Fetching writes them through `ListingLedger` in `Pipeline`, all
/// of a source's changes in one transaction.
public struct ListingRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// A job's listings, the one it shows first, then oldest first.
    public func listings(of job: JobID) async throws -> [Listing] {
        let rows = try await db.query(
            "SELECT * FROM listing WHERE job_id = ? AND deleted = 0 ORDER BY id = ? DESC, first_seen_at, id",
            [.text(job.rawValue), .text(job.rawValue)])
        return try rows.map(Self.listing)
    }

    /// The listings with these ids, tombstones included, by id.
    public func listings(ids: [JobID]) async throws -> [JobID: (listing: Listing, deleted: Bool)] {
        var found: [JobID: (listing: Listing, deleted: Bool)] = [:]
        for start in stride(from: 0, to: ids.count, by: 500) {
            let batch = ids[start..<min(start + 500, ids.count)]
            let marks = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            for row in try await db.query(
                "SELECT * FROM listing WHERE id IN (\(marks))", batch.map { .text($0.rawValue) })
            {
                let listing = try Self.listing(row)
                found[listing.id] = (listing, row.bool("deleted") ?? false)
            }
        }
        return found
    }

    /// A source's listings still open.
    public func openListings(of source: UUID) async throws -> [Listing] {
        try await db.query(
            "SELECT * FROM listing WHERE source_id = ? AND deleted = 0 AND closed_at IS NULL ORDER BY id",
            [.text(source.lowercased)]
        ).map(Self.listing)
    }

    /// A job's history, oldest first.
    public func events(of job: JobID) async throws -> [JobEvent] {
        try await db.query(
            "SELECT * FROM job_event WHERE job_id = ? AND deleted = 0 ORDER BY at, id", [.text(job.rawValue)]
        ).map { row in
            let r = RowReader(row: row, table: "job_event")
            return JobEvent(
                jobID: JobID(rawValue: try r.string("job_id")), at: try r.date("at"),
                kind: try r.value("kind", as: JobEvent.Kind.self),
                sourceID: row.string("source_id").flatMap(UUID.init(uuidString:)), detail: row.string("detail"))
        }
    }

    // MARK: - Writing, inside a transaction

    static let columns = [
        "id", "job_id", "source_id", "url", "canonical_url", "title", "company", "location", "posted_at",
        "description", "description_kind", "content_hash", "first_seen_at", "last_seen_at", "missing_runs",
        "closed_at", "updated_hlc",
    ]

    /// Inserts or replaces `listing` (a tombstone comes back), stamped with `hlc`.
    public static func upsert(_ listing: Listing, hlc: HLCTimestamp, in connection: Connection) throws {
        let updates = columns.filter { $0 != "id" && $0 != "first_seen_at" }.map { "\($0) = excluded.\($0)" }
        try connection.execute(
            """
            INSERT INTO listing (\(columns.joined(separator: ", ")), deleted)
            VALUES (\(Array(repeating: "?", count: columns.count).joined(separator: ", ")), 0)
            ON CONFLICT (id) DO UPDATE SET \(updates.joined(separator: ", ")), deleted = 0
            """,
            [
                .text(listing.id.rawValue), .text(listing.jobID.rawValue), .text(listing.sourceID.lowercased),
                .text(listing.url), .text(listing.canonicalURL), .text(listing.title), .text(listing.company),
                .text(listing.location), SQLValue(listing.postedAt), SQLValue(listing.descriptionMarkdown),
                SQLValue(listing.descriptionKind), .text(listing.contentHash), SQLValue(listing.firstSeenAt),
                SQLValue(listing.lastSeenAt), SQLValue(listing.missingRuns), SQLValue(listing.closedAt),
                .text(hlc.description),
            ])
    }

    public static func record(_ event: JobEvent, id: UUID, hlc: HLCTimestamp, in connection: Connection) throws {
        try connection.execute(
            """
            INSERT INTO job_event (id, job_id, at, kind, source_id, detail, updated_hlc)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id.lowercased), .text(event.jobID.rawValue), SQLValue(event.at), .text(event.kind.rawValue),
                SQLValue(event.sourceID?.lowercased), SQLValue(event.detail), .text(hlc.description),
            ])
    }

    public static func listing(_ row: Row) throws(StoreError) -> Listing {
        let r = RowReader(row: row, table: "listing")
        var listing = Listing(
            canonicalURL: try r.string("canonical_url"), jobID: JobID(rawValue: try r.string("job_id")),
            sourceID: try r.uuid("source_id"), url: try r.string("url"), title: try r.string("title"),
            company: try r.string("company"), location: try r.string("location"), postedAt: r.optionalDate("posted_at"),
            descriptionMarkdown: row.string("description"),
            descriptionKind: try r.value("description_kind", as: DescriptionKind.self),
            firstSeenAt: try r.date("first_seen_at"), lastSeenAt: try r.date("last_seen_at"),
            missingRuns: try r.int("missing_runs"), closedAt: r.optionalDate("closed_at"))
        // The stored hash wins: a listing backfilled from before v2 has none until it's seen again.
        if let stored = row.string("content_hash") { listing.contentHash = stored }
        return listing
    }
}
