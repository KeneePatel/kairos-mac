import Foundation
import JobSources
import Store

/// What one source's answer does to the stored jobs (job collection v2, docs/design/
/// job-collection.md; rules in docs/research/job-collection/06-job-tracking.md):
///
/// - A posting seen before is seen again; an edited one is updated, and a job whose text changed
///   is screened again. A closed one that's back reopens.
/// - A new posting that's another source's copy of a stored job is attached to that job, and a
///   full posting replaces a snippet. Anything else is a new job.
/// - Only a complete answer (a company board lists every job it has open) can close anything: a
///   listing it leaves out twice in a row closes, and a job closes when all its listings have.
///
/// All of one answer's changes are written in one transaction.
public struct ListingLedger: Sendable {
    /// What an answer did, for the fetch's progress and run stats.
    public struct Outcome: Sendable, Equatable {
        /// New jobs.
        public var added = 0
        /// New listings of jobs already stored from another source.
        public var attached = 0
        /// Listings seen before.
        public var known = 0
        /// Listings whose title, place or text changed.
        public var changed = 0
        /// Jobs whose snippet a full posting replaced.
        public var upgraded = 0
        /// Jobs that closed, and jobs that came back.
        public var closed = 0
        public var reopened = 0
        /// Postings left out: every place outside Canada and the US, or older than your limit.
        public var outside = 0
        public var tooOld = 0

        public init() {}

        /// Postings that didn't make a new job.
        public var duplicates: Int { known + attached }
    }

    /// Complete answers in a row that leave a listing out before it closes: one miss can be a glitch.
    public static let missesToClose = 2
    /// A search's listing (which no answer can prove gone) closes when it hasn't been seen for
    /// this long and was posted at least `staleSearchPosted` ago.
    public static let staleSearchUnseen: TimeInterval = 30 * 86_400
    public static let staleSearchPosted: TimeInterval = 45 * 86_400

    let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// Records `postings`, everything `source` answered. `complete` when that's every job it has
    /// open. `postedAfter`: new postings older than it aren't stored (your "Posted" limit).
    public func record(
        _ postings: [Posting], from source: SourceID, kind: SourceKind, complete: Bool, at now: Date,
        postedAfter: Date? = nil
    ) async throws -> Outcome {
        try await db.write { connection, stamp in
            var writer = Writer(connection: connection, hlc: stamp.hlc, now: now, source: source)
            return try writer.record(postings, kind: kind, complete: complete, postedAfter: postedAfter)
        }
    }

    /// The board answered "unchanged": it repeated its last answer. What that answer listed was
    /// seen just now; what it left out is missing once more, and closes like any other miss.
    /// Returns how many jobs closed.
    @discardableResult
    public func recordUnchanged(_ source: SourceID, at now: Date) async throws -> Int {
        try await db.write { connection, stamp in
            let hlc = SQLValue.text(stamp.hlc.description)
            let time = SQLValue(now)
            try connection.execute(
                """
                UPDATE job SET last_seen_at = ?, updated_hlc = ? WHERE deleted = 0 AND id IN
                    (SELECT job_id FROM listing WHERE source_id = ? AND deleted = 0 AND closed_at IS NULL
                        AND missing_runs = 0)
                """, [time, hlc, .text(source.lowercased)])
            try connection.execute(
                """
                UPDATE listing SET last_seen_at = ?, updated_hlc = ?
                WHERE source_id = ? AND deleted = 0 AND closed_at IS NULL AND missing_runs = 0
                """, [time, hlc, .text(source.lowercased)])
            var writer = Writer(connection: connection, hlc: stamp.hlc, now: now, source: source)
            return try writer.missedAgain(by: source)
        }
    }

    /// Closes search listings unseen for 30 days and posted 45 days ago, and their jobs when no
    /// other listing is open. Returns how many jobs closed.
    @discardableResult
    public func closeStaleSearchListings(of sources: [SourceID], at now: Date) async throws -> Int {
        guard !sources.isEmpty else { return 0 }
        return try await db.write { connection, stamp in
            var writer = Writer(connection: connection, hlc: stamp.hlc, now: now, source: nil)
            let marks = Array(repeating: "?", count: sources.count).joined(separator: ", ")
            let stale = try connection.query(
                """
                SELECT * FROM listing WHERE deleted = 0 AND closed_at IS NULL AND source_id IN (\(marks))
                    AND last_seen_at < ? AND coalesce(posted_at, first_seen_at) < ?
                """,
                sources.map { .text($0.lowercased) } + [
                    SQLValue(now.addingTimeInterval(-Self.staleSearchUnseen)),
                    SQLValue(now.addingTimeInterval(-Self.staleSearchPosted)),
                ])
            var closed = 0
            for row in stale {
                var listing = try ListingRepository.listing(row)
                listing.closedAt = now
                try ListingRepository.upsert(listing, hlc: stamp.hlc, in: connection)
                if try writer.closeJobIfAllClosed(listing.jobID, by: listing.sourceID) { closed += 1 }
            }
            return closed
        }
    }
}

/// One transaction's work.
private struct Writer {
    let connection: Connection
    let hlc: HLCTimestamp
    let now: Date
    let source: SourceID?
    var ids = UUIDv7Generator()
    var outcome = ListingLedger.Outcome()

    init(connection: Connection, hlc: HLCTimestamp, now: Date, source: SourceID?) {
        self.connection = connection
        self.hlc = hlc
        self.now = now
        self.source = source
    }

    mutating func record(_ postings: [Posting], kind: SourceKind, complete: Bool, postedAfter: Date?) throws
        -> ListingLedger.Outcome
    {
        guard let source else { return outcome }
        var seen: Set<JobID> = []
        for posting in postings {
            guard case .job(let candidate) = Normalizer.normalize(posting, firstSeenAt: now) else {
                outcome.outside += 1
                continue
            }
            // A board listing one job twice: the first copy counts.
            guard seen.insert(candidate.id).inserted else {
                outcome.known += 1
                continue
            }
            let text: DescriptionKind =
                candidate.descriptionMarkdown == nil ? .none : kind.sendsSnippets ? .snippet : .full
            try take(candidate, kind: text, from: source, postedAfter: postedAfter)
        }
        if complete { try closeMissing(from: source, seen: seen) }
        return outcome
    }

    // MARK: - One posting

    private mutating func take(_ candidate: Job, kind: DescriptionKind, from source: SourceID, postedAfter: Date?)
        throws
    {
        if let row = try connection.query("SELECT * FROM listing WHERE id = ?", [.text(candidate.id.rawValue)]).first {
            let stored = try ListingRepository.listing(row)
            let deleted = row.bool("deleted") ?? false
            // A job you cleared comes back as new; one retention removed stays gone.
            let cleared = try JobRepository.job(stored.jobID, in: connection)?.cleared ?? false
            if !deleted {
                try seenAgain(stored, as: candidate, kind: kind)
                return
            }
            if !cleared {
                outcome.known += 1
                return
            }
        }
        if let postedAfter, let posted = candidate.postedAt, posted < postedAfter {
            outcome.tooOld += 1
            return
        }
        if let copyOf = try storedCopy(of: candidate, from: source) {
            try attach(candidate, kind: kind, to: copyOf, from: source)
        } else {
            try add(candidate, kind: kind, from: source)
        }
    }

    private mutating func add(_ candidate: Job, kind: DescriptionKind, from source: SourceID) throws {
        var job = candidate
        job.lastSeenAt = now
        job.descriptionKind = kind
        job.primaryListingID = candidate.id
        try JobRepository.upsert(job, hlc: hlc, in: connection)
        try ListingRepository.upsert(listing(candidate, kind: kind, of: job.id, from: source), hlc: hlc, in: connection)
        try event(job.id, .found, source)
        outcome.added += 1
    }

    /// Another source's copy of a stored job: attached, and promoted when it's the fuller posting.
    private mutating func attach(_ candidate: Job, kind: DescriptionKind, to stored: Job, from source: SourceID) throws
    {
        try ListingRepository.upsert(
            listing(candidate, kind: kind, of: stored.id, from: source), hlc: hlc, in: connection)
        try event(stored.id, .postedElsewhere, source)
        outcome.attached += 1
        var job = stored
        job.lastSeenAt = now
        if job.closedAt != nil {
            job.closedAt = nil
            try event(job.id, .reopened, source)
            outcome.reopened += 1
        }
        if kind == .full && stored.descriptionKind != .full {
            take(text: candidate, kind: kind, primary: candidate.id, source: source, into: &job)
            try event(job.id, .upgraded, source)
            outcome.upgraded += 1
            try JobRepository.upsert(job, hlc: hlc, in: connection)
            try screenAgain(job)
            return
        }
        try JobRepository.upsert(job, hlc: hlc, in: connection)
    }

    private mutating func seenAgain(_ stored: Listing, as candidate: Job, kind: DescriptionKind) throws {
        outcome.known += 1
        var updated = listing(candidate, kind: kind, of: stored.jobID, from: stored.sourceID)
        updated.firstSeenAt = stored.firstSeenAt
        let edited = updated.contentHash != stored.contentHash
        if edited { outcome.changed += 1 }
        let reopened = stored.closedAt != nil
        try ListingRepository.upsert(updated, hlc: hlc, in: connection)
        guard var job = try JobRepository.job(stored.jobID, in: connection)?.job else { return }
        job.lastSeenAt = now
        if reopened || job.closedAt != nil {
            job.closedAt = nil
            try event(job.id, .reopened, stored.sourceID)
            outcome.reopened += 1
        }
        let isPrimary = (job.primaryListingID ?? job.id) == stored.id
        if edited {
            try event(job.id, .changed, stored.sourceID)
            if isPrimary { take(text: candidate, kind: kind, primary: stored.id, source: stored.sourceID, into: &job) }
        }
        try JobRepository.upsert(job, hlc: hlc, in: connection)
        if edited && isPrimary { try screenAgain(job) }
    }

    /// The job shows this listing: its text, its link and what it says about the place.
    private func take(text candidate: Job, kind: DescriptionKind, primary: JobID, source: SourceID, into job: inout Job)
    {
        job.primaryListingID = primary
        job.sourceID = source
        job.url = candidate.url
        job.title = candidate.title
        job.location = candidate.location
        job.city = candidate.city
        job.region = candidate.region
        job.country = candidate.country
        job.remoteScope = candidate.remoteScope
        job.postedAt = candidate.postedAt ?? job.postedAt
        job.descriptionMarkdown = candidate.descriptionMarkdown
        job.descriptionKind = kind
    }

    /// A stored job from another source with the same company, title and place.
    private func storedCopy(of candidate: Job, from source: SourceID) throws -> Job? {
        let company = String(DedupKey.company(of: candidate.dedupKey))
        let rows = try connection.query(
            """
            SELECT * FROM job WHERE deleted = 0 AND dedup_key >= ? AND dedup_key < ?
                AND id NOT IN (SELECT job_id FROM listing WHERE source_id = ? AND deleted = 0)
            ORDER BY first_seen_at, id
            """, [.text(company + "|"), .text(company + "}"), .text(source.lowercased)])
        for row in rows {
            guard let key = row.string("dedup_key"), Deduplicator.isSameJob(key, candidate.dedupKey) else {
                continue
            }
            return try JobRepository.job(JobID(rawValue: row.string("id") ?? ""), in: connection)?.job
        }
        return nil
    }

    // MARK: - Closing

    private mutating func closeMissing(from source: SourceID, seen: Set<JobID>) throws {
        let open = try connection.query(
            "SELECT * FROM listing WHERE source_id = ? AND deleted = 0 AND closed_at IS NULL",
            [.text(source.lowercased)])
        for row in open {
            var listing = try ListingRepository.listing(row)
            guard !seen.contains(listing.id) else { continue }
            listing.missingRuns += 1
            if listing.missingRuns >= ListingLedger.missesToClose { listing.closedAt = now }
            try ListingRepository.upsert(listing, hlc: hlc, in: connection)
            if listing.closedAt != nil, try closeJobIfAllClosed(listing.jobID, by: source) { outcome.closed += 1 }
        }
    }

    /// After an "unchanged" answer: the listings the last answer already left out miss once more.
    mutating func missedAgain(by source: SourceID) throws -> Int {
        let missing = try connection.query(
            "SELECT * FROM listing WHERE source_id = ? AND deleted = 0 AND closed_at IS NULL AND missing_runs > 0",
            [.text(source.lowercased)])
        var closed = 0
        for row in missing {
            var listing = try ListingRepository.listing(row)
            listing.missingRuns += 1
            if listing.missingRuns >= ListingLedger.missesToClose { listing.closedAt = now }
            try ListingRepository.upsert(listing, hlc: hlc, in: connection)
            if listing.closedAt != nil, try closeJobIfAllClosed(listing.jobID, by: source) { closed += 1 }
        }
        return closed
    }

    /// Closes the job when none of its listings is open. Returns whether it closed.
    mutating func closeJobIfAllClosed(_ id: JobID, by source: SourceID) throws -> Bool {
        let open =
            try connection.query(
                "SELECT COUNT(*) AS open FROM listing WHERE job_id = ? AND deleted = 0 AND closed_at IS NULL",
                [.text(id.rawValue)]
            ).first?.int("open") ?? 0
        guard open == 0, var job = try JobRepository.job(id, in: connection), !job.deleted, job.job.closedAt == nil
        else { return false }
        job.job.closedAt = now
        try JobRepository.upsert(job.job, hlc: hlc, in: connection)
        try event(id, .closed, source)
        return true
    }

    // MARK: - Helpers

    private func listing(_ candidate: Job, kind: DescriptionKind, of job: JobID, from source: SourceID) -> Listing {
        Listing(
            canonicalURL: candidate.canonicalURL, jobID: job, sourceID: source, url: candidate.url,
            title: candidate.title, company: candidate.company, location: candidate.location,
            postedAt: candidate.postedAt, descriptionMarkdown: candidate.descriptionMarkdown, descriptionKind: kind,
            firstSeenAt: now, lastSeenAt: now)
    }

    /// Its verdict and analysis go, so the next screening reads the new text. Your own verdict, and
    /// a job you've acted on, stay as they are.
    private func screenAgain(_ job: Job) throws {
        guard job.state == .new, job.verdictSource != .user else { return }
        try connection.execute(
            "UPDATE job SET verdict = NULL, verdict_source = NULL, rank = NULL, updated_hlc = ? WHERE id = ?",
            [.text(hlc.description), .text(job.id.rawValue)])
        try connection.execute(
            "UPDATE job_analysis SET deleted = 1, updated_hlc = ? WHERE job_id = ? AND deleted = 0",
            [.text(hlc.description), .text(job.id.rawValue)])
    }

    private mutating func event(_ job: JobID, _ kind: JobEvent.Kind, _ source: SourceID?) throws {
        let id = ids.next(now: UInt64(max(0, now.milliseconds)))
        try ListingRepository.record(
            JobEvent(jobID: job, at: now, kind: kind, sourceID: source), id: id, hlc: hlc, in: connection)
    }
}
