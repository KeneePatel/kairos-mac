import Foundation
import Jobs
import KairosKit
import SQL

/// What one source's answer does to the stored jobs:
///
/// - A listing seen before is seen again. An edited one is updated, and when it's the job's
///   primary listing the job takes its text and is screened again (unless you've acted on it). A
///   closed one that's back reopens.
/// - A new listing that's another source's copy of a stored job (same company, a title at least
///   0.9 alike, the same city when both say) is attached to it. A company's own board becomes the
///   primary listing over a search's copy. Anything else is a new job, unless it's older than your
///   limit or not one of your roles.
/// - Only a complete answer (a company board lists every job it has open) can close anything: a
///   listing it leaves out twice in a row closes, and a job closes when all its listings have. An
///   "unchanged" answer (HTTP 304) repeats the last one.
/// - Archived jobs stay archived: their listings are seen, and nothing else about them changes.
///
/// One answer's changes are written in one transaction.
public struct ListingLedger: Sendable {
    /// What an answer did, for the fetch's progress and run stats.
    public struct Outcome: Sendable, Equatable {
        /// New jobs.
        public var added = 0
        /// New listings of jobs already stored from another source.
        public var attached = 0
        /// Listings seen before, including another source's copy of the same address.
        public var known = 0
        /// Listings whose title, place or text changed.
        public var changed = 0
        public var closed = 0
        public var reopened = 0
        /// New postings left out: older than your limit, or not one of your roles.
        public var tooOld = 0
        public var otherRoles = 0
        /// New postings whose text the board didn't send this time: left for the next fetch.
        public var unread = 0
        /// Snippets, which are leads and never jobs.
        public var snippets = 0

        public init() {}

        public static func + (lhs: Outcome, rhs: Outcome) -> Outcome {
            var sum = lhs
            sum.added += rhs.added
            sum.attached += rhs.attached
            sum.known += rhs.known
            sum.changed += rhs.changed
            sum.closed += rhs.closed
            sum.reopened += rhs.reopened
            sum.tooOld += rhs.tooOld
            sum.otherRoles += rhs.otherRoles
            sum.unread += rhs.unread
            sum.snippets += rhs.snippets
            return sum
        }
    }

    /// Complete answers in a row that leave a listing out before it closes: one miss can be a glitch.
    public static let missesToClose = 2
    /// A search's listing, which no answer can prove gone, closes when it hasn't been seen for this
    /// long and was posted at least `staleSearchPosted` ago.
    public static let staleSearchUnseen: TimeInterval = .days(30)
    public static let staleSearchPosted: TimeInterval = .days(45)

    let db: Database

    /// Records `listings`, everything `source` answered; `complete` when that's every job it has
    /// open. New postings older than `postedAfter`, or whose title isn't one of `roles`, aren't
    /// stored (one already stored is still seen, so it doesn't close).
    public func record(
        _ listings: [Listing], from source: Source, complete: Bool, at now: Date, postedAfter: Date? = nil,
        roles: RoleMatcher? = nil
    ) async throws -> Outcome {
        try await db.transaction { connection in
            var writer = LedgerWriter(connection: connection, now: now, source: source)
            try writer.record(listings, complete: complete, postedAfter: postedAfter, roles: roles)
            return writer.outcome
        }
    }

    /// The board answered "unchanged": it repeated its last answer. What that answer listed was
    /// seen just now; what it left out is missing once more. Returns how many jobs closed.
    @discardableResult
    public func recordUnchanged(_ source: Source, at now: Date) async throws -> Int {
        try await db.transaction { connection in
            let time = SQLValue(now)
            let listed = "source_id = ? AND closed_at IS NULL AND missing_streak = 0"
            try connection.execute(
                "UPDATE job SET last_seen_at = ? WHERE id IN (SELECT job_id FROM listing WHERE \(listed))",
                [time, .id(source.id)])
            try connection.execute("UPDATE listing SET last_seen_at = ? WHERE \(listed)", [time, .id(source.id)])
            var writer = LedgerWriter(connection: connection, now: now, source: source)
            try writer.closeMissing(seen: nil)
            return writer.outcome.closed
        }
    }

    /// Closes search listings unseen for 30 days and posted 45 days ago, and their jobs when no other
    /// listing is open. Returns how many jobs closed.
    @discardableResult
    public func closeStaleSearchListings(at now: Date) async throws -> Int {
        try await db.transaction { connection in
            let stale = try connection.query(
                """
                SELECT l.id, l.job_id, s.kind FROM listing l JOIN source s ON s.id = l.source_id
                WHERE s.slug = '' AND l.closed_at IS NULL AND l.last_seen_at < ?
                    AND coalesce(l.posted_at, l.first_seen_at) < ?
                """,
                [
                    SQLValue(now.addingTimeInterval(-Self.staleSearchUnseen)),
                    SQLValue(now.addingTimeInterval(-Self.staleSearchPosted)),
                ])
            var closed = 0
            for row in stale {
                guard let id = row.string("id"), let job = row.string("job_id") else { continue }
                try connection.execute("UPDATE listing SET closed_at = ? WHERE id = ?", [SQLValue(now), .text(id)])
                let kind = row.optionalValue("kind", as: SourceKind.self)
                if try LedgerWriter.closeJobIfAllClosed(job, kind: kind, at: now, in: connection) { closed += 1 }
            }
            return closed
        }
    }
}

/// One transaction's work.
private struct LedgerWriter {
    let connection: Connection
    let now: Date
    let source: Source
    var outcome = ListingLedger.Outcome()

    init(connection: Connection, now: Date, source: Source) {
        self.connection = connection
        self.now = now
        self.source = source
    }

    mutating func record(_ listings: [Listing], complete: Bool, postedAfter: Date?, roles: RoleMatcher?) throws {
        var seen: Set<String> = []
        for listing in listings {
            guard !listing.isSnippet else {
                outcome.snippets += 1
                continue
            }
            // A board listing one job twice: the first copy counts.
            guard seen.insert(listing.id).inserted else {
                outcome.known += 1
                continue
            }
            try take(listing, postedAfter: postedAfter, roles: roles)
        }
        if complete { try closeMissing(seen: seen) }
    }

    // MARK: - One listing

    private mutating func take(_ listing: Listing, postedAfter: Date?, roles: RoleMatcher?) throws {
        if let row = try connection.first("SELECT * FROM listing WHERE id = ?", [.text(listing.id)]) {
            // The same address listed by another source (a search linking to a company's board):
            // that source's listing is its own, and this one adds nothing to it.
            guard row.string("source_id") == source.id.lowercased, let jobID = row.string("job_id"),
                let job = try JobRepository.job(jobID, in: connection)
            else {
                outcome.known += 1
                return
            }
            outcome.known += 1
            if job.archivedAt != nil || listing.textOmitted {
                try seen(listing.id, job: job)
            } else {
                try seenAgain(listing, stored: row, job: job)
            }
            return
        }
        // Another source's copy of a stored job is attached whatever its age or title: it isn't a
        // new job.
        if !listing.textOmitted, let copy = try storedCopy(of: listing) {
            try attach(listing, to: copy)
            return
        }
        if let postedAfter, let posted = listing.postedAt, posted < postedAfter {
            outcome.tooOld += 1
            return
        }
        if let roles, !roles.matches(listing.title) {
            outcome.otherRoles += 1
            return
        }
        if listing.textOmitted {
            outcome.unread += 1
            return
        }
        let job = Job(listing, sourceKind: source.kind, at: now)
        try JobRepository.insert(job, at: now, in: connection)
        try insert(listing, jobID: job.id)
        try event(job.id, .found)
        outcome.added += 1
    }

    /// Listed again, without its text or for an archived job: seen, and nothing else changes.
    private mutating func seen(_ listingID: String, job: Job) throws {
        try connection.execute(
            "UPDATE listing SET last_seen_at = ?, missing_streak = 0, closed_at = NULL WHERE id = ?",
            [SQLValue(now), .text(listingID)])
        try touch(job)
    }

    private mutating func seenAgain(_ listing: Listing, stored: Row, job: Job) throws {
        let edited = stored.string("content_hash") != listing.contentHash
        try connection.execute(
            """
            UPDATE listing SET url = ?, apply_url = ?, title = ?, company = ?, location = ?, posted_at = ?,
                content_hash = ?, last_seen_at = ?, missing_streak = 0, closed_at = NULL
            WHERE id = ?
            """,
            [
                .text(listing.url), SQLValue(listing.applyURL), .text(listing.title), .text(listing.company),
                .text(listing.location), SQLValue(listing.postedAt), .text(listing.contentHash), SQLValue(now),
                .text(listing.id),
            ])
        guard edited else {
            try touch(job)
            return
        }
        outcome.changed += 1
        try event(job.id, .changed)
        if job.primaryListingID == listing.id {
            try takeText(of: listing, for: job, sourceKind: source.kind)
            try JobRepository.screenAgain(job.id, in: connection)
        }
        try touch(job)
    }

    /// Another source's copy of a stored job: attached, and made primary when it's the company's
    /// own board and the job showed a search's copy.
    private mutating func attach(_ listing: Listing, to job: Job) throws {
        try insert(listing, jobID: job.id)
        try event(job.id, .postedElsewhere)
        outcome.attached += 1
        if source.kind.isBoard, job.sourceKind?.isBoard != true, job.archivedAt == nil {
            try takeText(of: listing, for: job, sourceKind: source.kind)
            if StableID.of(job.description) != StableID.of(listing.description) {
                try JobRepository.screenAgain(job.id, in: connection)
            }
        }
        try touch(job)
    }

    /// The job shows `listing`: its text, its link and what it says about the place.
    private func takeText(of listing: Listing, for job: Job, sourceKind: SourceKind) throws {
        try connection.execute(
            """
            UPDATE job SET primary_listing_id = ?, source_kind = ?, url = ?, apply_url = ?, via = ?, title = ?,
                location = ?, city = ?, region = ?, country = ?, remote_scope = ?, posted_at = coalesce(?, posted_at),
                description = ?, salary = coalesce(?, salary), updated_at = ?
            WHERE id = ?
            """,
            [
                .text(listing.id), .text(sourceKind.rawValue), .text(listing.url), SQLValue(listing.applyURL),
                SQLValue(listing.via), .text(listing.title), .text(listing.location), SQLValue(listing.city),
                SQLValue(listing.region), SQLValue(listing.country?.rawValue), .text(listing.remoteScope.rawValue),
                SQLValue(listing.postedAt), .text(listing.description), try .json(listing.salary), SQLValue(now),
                .text(job.id),
            ])
    }

    /// The job was seen now, and is open again if it had closed.
    private mutating func touch(_ job: Job) throws {
        try connection.execute(
            "UPDATE job SET last_seen_at = ?, closed_at = NULL WHERE id = ?", [SQLValue(now), .text(job.id)])
        if job.closedAt != nil {
            try event(job.id, .reopened)
            outcome.reopened += 1
        }
    }

    /// A stored job from another source with the same company, title and place; or the same posting
    /// under another company name (Himalayas listed one job for a foundation and for its lab,
    /// 2026-10-26): the same title and the same whole text.
    private func storedCopy(of listing: Listing) throws -> Job? {
        let company = String(DedupKey.company(of: listing.dedupKey))
        let rows = try connection.query(
            """
            SELECT id, dedup_key FROM job WHERE dedup_key >= ? AND dedup_key < ?
                AND id NOT IN (SELECT job_id FROM listing WHERE source_id = ?)
            ORDER BY first_seen_at, id
            """, [.text(company + "|"), .text(company + "}"), .id(source.id)])
        for row in rows {
            guard let key = row.string("dedup_key"), let id = row.string("id"),
                Similarity.isSameJob(key, listing.dedupKey)
            else { continue }
            return try JobRepository.job(id, in: connection)
        }
        guard listing.description.count >= 200 else { return nil }
        let twin = try connection.first(
            """
            SELECT id FROM job WHERE closed_at IS NULL AND title = ? AND description = ?
                AND id NOT IN (SELECT job_id FROM listing WHERE source_id = ?)
            ORDER BY first_seen_at, id LIMIT 1
            """, [.text(listing.title), .text(listing.description), .id(source.id)])
        return try twin?.string("id").flatMap { try JobRepository.job($0, in: connection) }
    }

    // MARK: - Closing

    /// Open listings of this source that `seen` leaves out miss once more; nil `seen` (an unchanged
    /// answer) means the ones the last answer already left out.
    mutating func closeMissing(seen: Set<String>?) throws {
        let open = try connection.query(
            "SELECT id, job_id, missing_streak FROM listing WHERE source_id = ? AND closed_at IS NULL", [.id(source.id)]
        )
        for row in open {
            guard let id = row.string("id"), let job = row.string("job_id") else { continue }
            let streak = row.int("missing_streak") ?? 0
            if let seen {
                if seen.contains(id) { continue }
            } else if streak == 0 {
                continue
            }
            let missing = streak + 1
            let closes = missing >= ListingLedger.missesToClose
            try connection.execute(
                "UPDATE listing SET missing_streak = ?, closed_at = ? WHERE id = ?",
                [SQLValue(missing), closes ? SQLValue(now) : .null, .text(id)])
            if closes, try Self.closeJobIfAllClosed(job, kind: source.kind, at: now, in: connection) {
                outcome.closed += 1
            }
        }
    }

    /// Closes the job when none of its listings is open. Returns whether it closed.
    static func closeJobIfAllClosed(_ id: String, kind: SourceKind?, at now: Date, in connection: Connection) throws
        -> Bool
    {
        let open =
            try connection.first(
                "SELECT count(*) AS n FROM listing WHERE job_id = ? AND closed_at IS NULL", [.text(id)])?
            .int("n") ?? 0
        guard open == 0 else { return false }
        try connection.execute(
            "UPDATE job SET closed_at = ?, updated_at = ? WHERE id = ? AND closed_at IS NULL",
            [SQLValue(now), SQLValue(now), .text(id)])
        guard connection.changes > 0 else { return false }
        try connection.execute(
            "INSERT INTO job_event (job_id, at, kind, source_kind) VALUES (?, ?, 'closed', ?)",
            [.text(id), SQLValue(now), SQLValue(kind?.rawValue)])
        return true
    }

    // MARK: - Helpers

    private func insert(_ listing: Listing, jobID: String) throws {
        try connection.execute(
            """
            INSERT INTO listing (id, job_id, source_id, canonical_url, url, apply_url, title, company, location,
                posted_at, content_hash, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(listing.id), .text(jobID), .id(source.id), .text(listing.canonicalURL), .text(listing.url),
                SQLValue(listing.applyURL), .text(listing.title), .text(listing.company), .text(listing.location),
                SQLValue(listing.postedAt), .text(listing.contentHash), SQLValue(now), SQLValue(now),
            ])
    }

    private func event(_ job: String, _ kind: JobEvent.Kind) throws {
        try connection.execute(
            "INSERT INTO job_event (job_id, at, kind, source_kind) VALUES (?, ?, ?, ?)",
            [.text(job), SQLValue(now), .text(kind.rawValue), .text(source.kind.rawValue)])
    }
}

extension JobRepository {
    /// Its analysis and screening go, so the next screening reads the new text. A job you've acted
    /// on (saved, overruled, brought back, built for or applied to) keeps them.
    static func screenAgain(_ id: String, in connection: Connection) throws {
        let acted =
            try connection.first(
                """
                SELECT (coalesce(decision, '') = 'saved'
                    OR EXISTS (SELECT 1 FROM screening WHERE job_id = j.id AND (your_verdict IS NOT NULL OR brought_back = 1))
                    OR EXISTS (SELECT 1 FROM build WHERE job_id = j.id)
                    OR EXISTS (SELECT 1 FROM application WHERE job_id = j.id)) AS acted
                FROM job j WHERE id = ?
                """, [.text(id)])?.bool("acted") ?? true
        guard !acted else { return }
        try connection.execute("DELETE FROM analysis WHERE job_id = ?", [.text(id)])
        try connection.execute("DELETE FROM screening WHERE job_id = ?", [.text(id)])
    }
}
