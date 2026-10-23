import Foundation
import Testing

@testable import Store

private let seen = Date(milliseconds: 1_760_000_000_000)

private func listing(_ n: Int, of job: JobID, source: UUID = sourceA, at date: Date = seen) -> Listing {
    Listing(
        canonicalURL: "https://jobs.example/\(n)", jobID: job, sourceID: source, url: "https://jobs.example/\(n)",
        title: "Engineer", company: "Acme", location: "Toronto", postedAt: nil, descriptionMarkdown: "Text \(n)",
        descriptionKind: .full, firstSeenAt: date)
}

private func write(_ listings: [Listing], events: [JobEvent] = [], in db: Database) async throws {
    try await db.write { connection, stamp in
        for listing in listings { try ListingRepository.upsert(listing, hlc: stamp.hlc, in: connection) }
        var ids = UUIDv7Generator()
        for event in events {
            try ListingRepository.record(event, id: ids.next(now: 1), hlc: stamp.hlc, in: connection)
        }
    }
}

/// Job collection v2's tables: listings, job events, fetch state and the fetch log (migration 011).
@Suite("Listings and job lifecycle")
struct ListingStoreTests {
    /// Every job stored before v2 becomes its own first listing, Adzuna's a snippet, and a job
    /// without text has none.
    @Test func existingJobsBecomeTheirOwnFirstListing() async throws {
        let db = try Database(path: ":memory:", device: "0000beef", now: { 1_760_000_000_000 })
        let all = try Migrator.bundled()
        try await Migrator.migrate(db, with: all.filter { $0.version < 11 })
        for (id, kind) in [("0199f0a0-0000-7000-8000-00000000000a", "adzuna"), (sourceA.lowercased, "greenhouse")] {
            try await db.execute(
                "INSERT INTO source (id, kind, updated_hlc) VALUES (?, ?, 'h')", [.text(id), .text(kind)])
        }
        for (n, source, text) in [
            (1, sourceA.lowercased, "Full posting"), (2, "0199f0a0-0000-7000-8000-00000000000a", "A snippet"),
            (3, sourceA.lowercased, nil),
        ] {
            let job = sampleJob(n)
            try await db.write { connection, stamp in
                try connection.execute(
                    """
                    INSERT INTO job (id, source_id, url, canonical_url, dedup_key, company, title, description,
                        first_seen_at, updated_hlc) VALUES (?, ?, ?, ?, ?, 'Acme', ?, ?, ?, ?)
                    """,
                    [
                        .text(job.id.rawValue), .text(source), .text(job.url), .text(job.canonicalURL),
                        .text(job.dedupKey), .text(job.title), SQLValue(text), SQLValue(seen),
                        .text(stamp.hlc.description),
                    ])
            }
        }
        try await Migrator.migrate(db, with: all)

        let jobs = try await JobRepository(db).jobs().sorted { $0.title < $1.title }
        #expect(jobs.map(\.descriptionKind) == [.full, .snippet, .none])
        #expect(jobs.allSatisfy { $0.lastSeenAt == seen && $0.primaryListingID == $0.id && $0.isOpen })
        let first = try await ListingRepository(db).listings(of: jobs[0].id)
        #expect(first.map(\.id) == [jobs[0].id] && first[0].descriptionMarkdown == "Full posting")
        #expect(first[0].contentHash == Listing.hash(title: "Engineer 1", location: "", description: "Full posting"))
        #expect(try await ListingRepository(db).listings(of: jobs[1].id).first?.descriptionKind == .snippet)
    }

    /// A job's lifecycle survives a round trip, and Review's "open only" leaves closed jobs out.
    @Test func closedJobsCanBeLeftOut() async throws {
        let db = try await migratedDatabase()
        var open = sampleJob(1)
        open.lastSeenAt = seen
        var closed = sampleJob(2)
        closed.closedAt = seen
        closed.descriptionKind = .snippet
        closed.primaryListingID = JobID(rawValue: "abc")
        try await JobRepository(db).upsert([open, closed])
        let stored = try await JobRepository(db).jobs()
        #expect(stored.first { $0.id == closed.id }?.closedAt == seen)
        #expect(stored.first { $0.id == closed.id }?.descriptionKind == .snippet)
        #expect(stored.first { $0.id == closed.id }?.primaryListingID == JobID(rawValue: "abc"))
        #expect(stored.first { $0.id == open.id }?.lastSeenAt == seen)
        #expect(try await JobRepository(db).jobs(matching: JobFilter(openOnly: true)).map(\.id) == [open.id])
    }

    /// A job lists the listing it shows first; its history reads oldest first; whitespace isn't an edit.
    @Test func listingsAndEventsReadBack() async throws {
        let db = try await migratedDatabase()
        let job = sampleJob(1)
        try await JobRepository(db).upsert(job)
        let other = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000b2")!
        var own = listing(1, of: job.id)
        own = Listing(
            canonicalURL: job.canonicalURL, jobID: job.id, sourceID: sourceA, url: job.url, title: "Engineer",
            company: "Acme", location: "Toronto", postedAt: nil, descriptionMarkdown: "Text", descriptionKind: .full,
            firstSeenAt: seen.addingTimeInterval(60))
        try await write(
            [listing(2, of: job.id, source: other), own],
            events: [
                JobEvent(jobID: job.id, at: seen.addingTimeInterval(60), kind: .postedElsewhere, sourceID: other),
                JobEvent(jobID: job.id, at: seen, kind: .found, sourceID: sourceA, detail: "first"),
            ], in: db)
        #expect(try await ListingRepository(db).listings(of: job.id).map(\.sourceID) == [sourceA, other])
        let events = try await ListingRepository(db).events(of: job.id)
        #expect(events.map(\.kind) == [.found, .postedElsewhere] && events[0].detail == "first")
        #expect(events[1].sourceID == other)
        let found = try await ListingRepository(db).listings(ids: [own.id, JobID(rawValue: "none")])
        #expect(found.count == 1 && found[own.id]?.deleted == false)
        #expect(try await ListingRepository(db).openListings(of: other).count == 1)
        #expect(
            Listing.hash(title: "Engineer", location: "Toronto", description: "Build  things\n")
                == Listing.hash(title: "Engineer ", location: "Toronto", description: "Build things"))
        #expect(
            Listing.hash(title: "Engineer", location: "Toronto", description: "Build things")
                != Listing.hash(title: "Engineer", location: "Toronto", description: "Build more things"))
    }

    /// Clearing jobs takes their listings and history with them and forgets every board's ETag, so
    /// the next fetch can bring back what's still posted; removing one job removes its listings.
    @Test func clearingTakesListingsAndForgetsAnswers() async throws {
        let db = try await migratedDatabase()
        let kept = sampleJob(1, state: .shortlisted)
        let going = sampleJob(2)
        let single = sampleJob(3, state: .shortlisted)
        try await JobRepository(db).upsert([kept, going, single])
        try await write(
            [listing(1, of: kept.id), listing(2, of: going.id), listing(3, of: single.id)],
            events: [JobEvent(jobID: going.id, at: seen, kind: .found)], in: db)
        try await FetchLog(db).save(SourceFetchState(etag: "v1", fingerprint: "f"), of: sourceA)
        #expect(try await JobRepository(db).clearAll() == 1)
        #expect(try await ListingRepository(db).listings(of: going.id).isEmpty)
        #expect(try await ListingRepository(db).events(of: going.id).isEmpty)
        #expect(try await ListingRepository(db).listings(of: kept.id).count == 1)
        #expect(try await FetchLog(db).state(of: sourceA) == SourceFetchState())
        try await JobRepository(db).tombstone(single.id)
        #expect(try await ListingRepository(db).listings(of: single.id).isEmpty)
    }

    /// Each source's fetch state round-trips; forgetting answers keeps the rest; the log reads back
    /// newest first and trims at 30 days.
    @Test func fetchStateAndLog() async throws {
        let db = try await migratedDatabase()
        let log = FetchLog(db)
        #expect(try await log.state(of: sourceA) == SourceFetchState())
        let state = SourceFetchState(etag: #"W/"1""#, fingerprint: "v2|posted:7", lastOKAt: seen, failRuns: 2)
        try await log.save(state, of: sourceA)
        #expect(try await log.state(of: sourceA) == state)
        try await log.forgetAnswers()
        let forgotten = try await log.state(of: sourceA)
        #expect(forgotten.etag == nil && forgotten.lastOKAt == seen)

        let old = FetchLogEntry(runID: nil, sourceID: sourceA, at: seen, request: "board", outcome: .ok, items: 3)
        let run = UUID.v7()
        let new = FetchLogEntry(
            runID: run, sourceID: sourceA, at: seen.addingTimeInterval(60), request: "board", outcome: .failed,
            error: "Network error", milliseconds: 120)
        try await log.record(old)
        try await log.record(new)
        #expect(try await log.entries(of: sourceA, since: seen) == [new, old])
        #expect(try await log.deleteOlder(than: seen.addingTimeInterval(1)) == 1)
        #expect(try await log.entries(of: sourceA, since: .distantPast) == [new])
    }
}
