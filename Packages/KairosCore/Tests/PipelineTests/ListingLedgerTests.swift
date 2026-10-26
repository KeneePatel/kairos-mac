import Foundation
import JobSources
import Screening
import Store
import Testing

@testable import Pipeline

private let day0 = Date(timeIntervalSince1970: 1_790_000_000)
private func day(_ n: Double) -> Date { day0.addingTimeInterval(n * 86_400) }

private func posting(
    _ source: SourceID, _ path: String, title: String = "Backend Developer", text: String = "Build APIs in Go.",
    posted: Date? = day0
) -> Posting {
    Posting(
        sourceID: source, url: URL(string: "https://jobs.example/\(path)")!, company: "Acme Robotics", title: title,
        location: "Toronto, ON", postedAt: posted, descriptionHTML: "<p>\(text)</p>")
}

private struct Fixture {
    let db: Database
    let ledger: ListingLedger
    let board: Source
    let adzuna: Source

    init() async throws {
        db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        ledger = ListingLedger(db)
        board = try await SourceRepository(db).add(kind: .greenhouse)
        adzuna = try await SourceRepository(db).add(kind: .adzuna)
    }

    @discardableResult
    func fromBoard(_ postings: [Posting], at date: Date = day0) async throws -> ListingLedger.Outcome {
        try await ledger.record(postings, from: board.id, kind: .greenhouse, complete: true, at: date)
    }

    @discardableResult
    func fromAdzuna(_ postings: [Posting], at date: Date = day0) async throws -> ListingLedger.Outcome {
        try await ledger.record(postings, from: adzuna.id, kind: .adzuna, complete: false, at: date)
    }

    func jobs() async throws -> [Job] { try await JobRepository(db).jobs() }
    func listings(_ job: Job) async throws -> [Listing] { try await ListingRepository(db).listings(of: job.id) }
    func events(_ job: Job) async throws -> [JobEvent.Kind] {
        try await ListingRepository(db).events(of: job.id).map(\.kind)
    }
}

/// Job collection v2: what each source's answer does to the stored jobs
/// (docs/research/job-collection/06-job-tracking.md).
@Suite("Listing ledger")
struct ListingLedgerTests {
    /// A job found on the company's board and on Adzuna is one job with two listings; the board's
    /// stays the one it shows.
    @Test func aCopyOnAnotherSourceIsListedWithItsJob() async throws {
        let f = try await Fixture()
        let added = try await f.fromBoard([posting(f.board.id, "gh/1")])
        let copy = try await f.fromAdzuna([posting(f.adzuna.id, "adzuna/9", text: "Build APIs")], at: day(1))
        #expect(added.added == 1 && copy.attached == 1 && copy.added == 0 && copy.duplicates == 1)
        let job = try #require(try await f.jobs().first)
        #expect(try await f.jobs().count == 1)
        #expect(try await f.listings(job).map(\.sourceID) == [f.board.id, f.adzuna.id])
        #expect(job.sourceID == f.board.id && job.descriptionKind == .full && job.lastSeenAt == day(1))
        #expect(try await f.events(job) == [.found, .postedElsewhere])
    }

    /// An Adzuna snippet found later on the company's board takes the board's full posting and
    /// link, and is screened again; your own verdict stays.
    @Test func aFullPostingReplacesASnippet() async throws {
        let f = try await Fixture()
        try await f.fromAdzuna([posting(f.adzuna.id, "adzuna/1", text: "Build APIs")])
        var job = try #require(try await f.jobs().first)
        #expect(job.descriptionKind == .snippet)
        try await JobRepository(f.db).setVerdict(.maybe, source: .analysis, rank: 1, for: job.id)
        try await AnalysisRepository(f.db).save(
            JobAnalysis(
                requirements: [], yearsRequired: nil, seniority: nil, domains: [],
                flags: .init(
                    sponsorship: .notMentioned, clearance: .notMentioned, french: .notMentioned, remoteScope: .onsite)),
            for: job.id,
            model: "m", promptVersion: 1)

        let upgrade = try await f.fromBoard(
            [posting(f.board.id, "gh/1", text: "Build APIs in Go. Full posting.")], at: day(1))
        #expect(upgrade.upgraded == 1 && upgrade.attached == 1)
        job = try #require(try await f.jobs().first)
        #expect(job.descriptionKind == .full && job.sourceID == f.board.id && job.url == "https://jobs.example/gh/1")
        #expect(job.descriptionMarkdown?.contains("Full posting") == true)
        #expect(job.verdict == nil && job.primaryListingID == JobID(canonicalURL: "https://jobs.example/gh/1"))
        #expect(try await AnalysisRepository(f.db).latest(for: job.id) == nil)
        #expect(try await f.events(job) == [.found, .postedElsewhere, .upgraded])

        // Your verdict stays when a later edit comes in.
        try await JobRepository(f.db).setUserVerdict(.yes, rank: 2, for: job.id)
        try await f.fromBoard([posting(f.board.id, "gh/1", text: "Edited.")], at: day(2))
        #expect(try await f.jobs().first?.verdict == .yes)
    }

    /// Where a job lives (v3, C1) follows its shown listing: stored with the job, kept while a
    /// search's copy is attached, and replaced when a fuller posting takes over.
    @Test func whereAJobLivesFollowsItsShownListing() async throws {
        let f = try await Fixture()
        var snippet = posting(f.adzuna.id, "adzuna/1", text: "Build APIs")
        snippet.via = "Adzuna"
        snippet.applyURL = URL(string: "https://www.adzuna.ca/land/ad/1")
        try await f.fromAdzuna([snippet])
        var job = try #require(try await f.jobs().first)
        #expect(job.via == "Adzuna" && job.applyURL == "https://www.adzuna.ca/land/ad/1")
        #expect(job.openURL == "https://www.adzuna.ca/land/ad/1")

        var full = posting(f.board.id, "gh/1", text: "Build APIs in Go. Full posting.")
        full.applyURL = URL(string: "https://jobs.example/gh/1?apply=1")
        try await f.fromBoard([full], at: day(1))
        job = try #require(try await f.jobs().first)
        #expect(job.applyURL == "https://jobs.example/gh/1?apply=1" && job.via == nil)
        #expect(job.openURL == "https://jobs.example/gh/1?apply=1")
    }

    /// A snippet-only job archived by v3 comes back to the Inbox, whole and screened afresh, when
    /// its company's board lists the posting; one you'd saved stays saved.
    @Test func anArchivedSnippetComesBackWhenItsWholePostingArrives() async throws {
        let f = try await Fixture()
        try await f.fromAdzuna([posting(f.adzuna.id, "adzuna/1", text: "Build APIs")])
        var job = try #require(try await f.jobs().first)
        try await JobRepository(f.db).setVerdict(.maybe, source: .analysis, rank: 1, for: job.id)
        try await f.db.execute("UPDATE job SET state = 'archived' WHERE id = ?", [.text(job.id.rawValue)])
        try await f.fromBoard([posting(f.board.id, "gh/1", text: "Build APIs in Go. Full posting.")], at: day(1))
        job = try #require(try await f.jobs().first)
        #expect(job.state == .new && job.descriptionKind == .full && job.verdict == nil)
        #expect(try await f.events(job) == [.found, .postedElsewhere, .upgraded])
    }

    /// Seen again, a posting moves its job's last-seen time; edited, it's updated and screened
    /// again, unless you've acted on the job.
    @Test func anEditedPostingIsUpdatedAndScreenedAgain() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")])
        let jobs = try await f.jobs()
        for job in jobs { try await JobRepository(f.db).setVerdict(.yes, source: .analysis, rank: 1, for: job.id) }
        let saved = try #require(jobs.first { $0.title == "Data Engineer" })
        try await JobRepository(f.db).setState(.shortlisted, for: saved.id)

        let same = try await f.fromBoard(
            [posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")], at: day(1))
        #expect(same.known == 2 && same.changed == 0 && same.added == 0)
        #expect(try await f.jobs().allSatisfy { $0.lastSeenAt == day(1) && $0.verdict == .yes })

        let edited = try await f.fromBoard(
            [
                posting(f.board.id, "gh/1", text: "Build APIs in Rust."),
                posting(f.board.id, "gh/2", title: "Data Engineer", text: "Now with Spark."),
            ], at: day(2))
        #expect(edited.changed == 2)
        let after = try await f.jobs()
        let backend = try #require(after.first { $0.title == "Backend Developer" })
        #expect(backend.descriptionMarkdown?.contains("Rust") == true && backend.verdict == nil)
        #expect(after.first { $0.id == saved.id }?.verdict == .yes)
        #expect(try await f.events(backend) == [.found, .changed])
    }

    /// Only a complete answer closes: a listing missing twice in a row closes, and its job with it;
    /// a search's answer closes nothing; a job back on the board reopens.
    @Test func missingTwiceClosesAndBackAgainReopens() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")])
        let once = try await f.fromBoard([posting(f.board.id, "gh/1")], at: day(1))
        #expect(once.closed == 0)
        #expect(try await f.jobs().allSatisfy(\.isOpen))
        let twice = try await f.fromBoard([posting(f.board.id, "gh/1")], at: day(2))
        #expect(twice.closed == 1)
        let closed = try #require(try await f.jobs().first { $0.title == "Data Engineer" })
        #expect(closed.closedAt == day(2) && closed.lastSeenAt == day0)
        #expect(try await f.listings(closed).first?.closedAt == day(2))
        #expect(try await JobRepository(f.db).jobs(matching: JobFilter(openOnly: true)).count == 1)

        let back = try await f.fromBoard(
            [posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")], at: day(3))
        #expect(back.reopened == 1)
        #expect(try await f.jobs().allSatisfy(\.isOpen))
        #expect(try await f.events(closed) == [.found, .closed, .reopened])

        // Adzuna leaving a job out of its matches proves nothing.
        try await f.fromAdzuna([posting(f.adzuna.id, "adzuna/5", title: "QA Analyst")], at: day(3))
        for n in 4...6 { try await f.fromAdzuna([], at: day(Double(n))) }
        #expect(try await f.jobs().allSatisfy(\.isOpen))
    }

    /// "Unchanged" repeats the last answer: a job that answer left out is missing again, and closes.
    @Test func unchangedAfterAMissIsASecondMiss() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")])
        try await f.fromBoard([posting(f.board.id, "gh/1")], at: day(1))
        #expect(try await f.ledger.recordUnchanged(f.board.id, at: day(2)) == 1)
        let jobs = try await f.jobs()
        #expect(jobs.first { $0.title == "Data Engineer" }?.closedAt == day(2))
        #expect(jobs.first { $0.title == "Backend Developer" }?.lastSeenAt == day(2))
        #expect(jobs.first { $0.title == "Data Engineer" }?.lastSeenAt == day0)
    }

    /// Screening skips a job no longer posted: no AI call for it.
    @Test func screeningSkipsClosedJobs() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")])
        for n in 1...2 { try await f.fromBoard([posting(f.board.id, "gh/1")], at: day(Double(n))) }
        var last = ScreeningRun.Progress()
        for await progress in ScreeningRun(db: f.db, router: nil, now: { day(3) }).start() { last = progress }
        #expect(last.total == 1)
    }

    /// With roles set, a new posting at another role is counted, not stored; one already stored is
    /// still seen, so narrowing your roles doesn't close it.
    @Test func otherRolesAreCountedNotStored() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Account Executive")])
        let roles = RoleMatcher(families: [.software])
        let outcome = try await f.ledger.record(
            [
                posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Account Executive"),
                posting(f.board.id, "gh/3", title: "Sales Development Representative"),
                posting(f.board.id, "gh/4", title: "SDE II"),
            ], from: f.board.id, kind: .greenhouse, complete: true, at: day(1), roles: roles)
        #expect(outcome.otherRoles == 1 && outcome.added == 1 && outcome.known == 2)
        let jobs = try await f.jobs()
        #expect(jobs.count == 3 && jobs.allSatisfy(\.isOpen))
    }

    /// A board that didn't send a known job's text (SmartRecruiters, BambooHR) still saw it, and
    /// nothing about it changes; a new job without its text waits for the next fetch.
    @Test func aPostingWithoutItsTextCountsAsSeen() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1")])
        var bare = posting(f.board.id, "gh/1", text: "")
        bare.textOmitted = true
        var newBare = posting(f.board.id, "gh/2", title: "Data Engineer", text: "")
        newBare.textOmitted = true
        let outcome = try await f.fromBoard([bare, newBare], at: day(1))
        #expect(outcome.known == 1 && outcome.changed == 0 && outcome.unread == 1 && outcome.added == 0)
        let job = try #require(try await f.jobs().first)
        #expect(job.descriptionMarkdown?.contains("Build APIs") == true && job.lastSeenAt == day(1))
        #expect(try await f.events(job) == [.found])
    }

    /// A search linking to a company board's own address doesn't touch the board's listing.
    @Test func anotherSourcesAddressIsLeftAlone() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1")])
        let same = try await f.fromAdzuna([posting(f.adzuna.id, "gh/1", text: "A search's own words.")], at: day(1))
        #expect(same.known == 1 && same.changed == 0)
        let job = try #require(try await f.jobs().first)
        #expect(job.descriptionMarkdown?.contains("Build APIs in Go") == true)
        #expect(try await f.listings(job).map(\.sourceID) == [f.board.id])
    }

    /// Different jobs at one company and city stay different across sources: titles are compared
    /// alone (on whole keys "QA Engineer" and "Data Engineer" were 0.91 alike).
    @Test func similarTitlesAtOneCompanyStayApart() async throws {
        let f = try await Fixture()
        try await f.fromBoard([
            posting(f.board.id, "gh/1", title: "Data Engineer"),
            posting(f.board.id, "gh/2", title: "Software Engineer, Payments"),
        ])
        let other = try await f.fromAdzuna(
            [
                posting(f.adzuna.id, "a/1", title: "QA Engineer"),
                posting(f.adzuna.id, "a/2", title: "Software Engineer, Payouts"),
                posting(f.adzuna.id, "a/3", title: "Data Engineer"),
            ], at: day(1))
        #expect(other.added == 2 && other.attached == 1)
        #expect(Deduplicator.titleSimilarity("acme|qa engineer|toronto", "acme|data engineer|toronto") < 0.9)
        #expect(Deduplicator.titleSimilarity("acme|data engineer|toronto", "other|data engineer|toronto") == 0)
        #expect(Deduplicator.titleSimilarity("acme|data engineer|", "acme|data engineer|toronto") == 1)
    }

    /// A job stays open while any of its listings is.
    @Test func aJobClosesOnlyWhenAllItsListingsHave() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1")])
        try await f.fromAdzuna([posting(f.adzuna.id, "adzuna/1")])
        try await f.fromBoard([], at: day(1))
        let quiet = try await f.fromBoard([], at: day(2))
        #expect(quiet.closed == 0)
        let job = try #require(try await f.jobs().first)
        #expect(job.isOpen)
        #expect(try await f.listings(job).map(\.isOpen) == [false, true])
    }

    /// A board answering "unchanged" saw every job it had open; a search's listing long unseen and
    /// long posted closes on its own.
    @Test func unchangedBoardsAndStaleSearches() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")])
        try await f.ledger.recordUnchanged(f.board.id, at: day(2))
        let jobs = try await f.jobs()
        #expect(jobs.allSatisfy { $0.lastSeenAt == day(2) })
        #expect(try await ListingRepository(f.db).openListings(of: f.board.id).allSatisfy { $0.missingRuns == 0 })

        try await f.fromAdzuna([posting(f.adzuna.id, "adzuna/7", title: "QA Analyst", posted: day0)])
        #expect(try await f.ledger.closeStaleSearchListings(of: [f.adzuna.id], at: day(40)) == 0)
        #expect(try await f.ledger.closeStaleSearchListings(of: [f.adzuna.id], at: day(46)) == 1)
        #expect(try await f.jobs().first { $0.title == "QA Analyst" }?.isOpen == false)
    }

    /// A job you cleared comes back when it's still posted; one retention removed stays gone; your
    /// "Posted" limit applies to new postings only.
    @Test func clearedComeBackRemovedStayGoneAndTheLimitIsForNewPostings() async throws {
        let f = try await Fixture()
        try await f.fromBoard([posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")])
        let removed = try #require(try await f.jobs().first { $0.title == "Data Engineer" })
        try await f.db.write { connection, stamp in
            for table in ["job", "listing"] {
                try connection.execute(
                    "UPDATE \(table) SET deleted = 1, updated_hlc = ? WHERE \(table == "job" ? "id" : "job_id") = ?",
                    [.text(stamp.hlc.description), .text(removed.id.rawValue)])
            }
        }
        try await JobRepository(f.db).setState(.new, for: removed.id)
        #expect(try await JobRepository(f.db).clearAll() == 1)
        let again = try await f.fromBoard(
            [posting(f.board.id, "gh/1"), posting(f.board.id, "gh/2", title: "Data Engineer")], at: day(1))
        #expect(again.added == 1 && again.known == 1)
        #expect(try await f.jobs().map(\.title) == ["Backend Developer"])

        let old = try await f.ledger.record(
            [posting(f.board.id, "gh/1"), posting(f.board.id, "gh/3", title: "Old Job", posted: day(-30))],
            from: f.board.id, kind: .greenhouse, complete: true, at: day(2), postedAfter: day(-7))
        #expect(old.tooOld == 1 && old.known == 1)
    }
}
