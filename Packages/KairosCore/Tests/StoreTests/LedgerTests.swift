import Foundation
import Jobs
import KairosKit
import Screening
import Store
import Testing

@Suite("Listing ledger")
struct LedgerTests {
    @Test func newListingsBecomeJobsWithAFoundEvent() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        let outcome = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        #expect(outcome.added == 1)
        let jobs = try await store.jobs.summaries()
        #expect(jobs.count == 1)
        let detail = try #require(try await store.jobs.detail(jobs[0].id))
        #expect(detail.job.sourceKind == .greenhouse)
        #expect(detail.listings.map(\.sourceName) == ["Acme"])
        #expect(detail.events.map(\.kind) == [.found])
        #expect(try await store.jobs.knownURLs(of: acme.id) == ["https://job-boards.greenhouse.io/acme/jobs/1"])
    }

    @Test func aListingSeenAgainIsKnownAndAnEditUpdatesTheJobAndScreensItAgain() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let id = try #require(try await store.jobs.summaries().first?.id)
        try await store.screening.record(ScreeningState(stage: .judged, verdict: .yes, screenedAt: now), for: id)

        let same = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: day(1))
        #expect(same.known == 1 && same.changed == 0 && same.added == 0)
        #expect(try await store.screening.state(for: id)?.verdict == .yes)

        let edited = listing("acme/jobs/1", title: "Senior Software Engineer", description: "Now with Rust.")
        let outcome = try await store.ledger.record([edited], from: acme, complete: true, at: day(2))
        #expect(outcome.changed == 1)
        let job = try #require(try await store.jobs.job(id))
        #expect(job.title == "Senior Software Engineer")
        #expect(job.description == "Now with Rust.")
        #expect(job.lastSeenAt == day(2))
        #expect(try await store.screening.state(for: id) == nil)
        #expect(try await store.jobs.detail(id)?.events.map(\.kind) == [.found, .changed])
    }

    @Test func anEditKeepsTheScreeningOfAJobYouActedOn() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let id = try #require(try await store.jobs.summaries().first?.id)
        try await store.screening.record(ScreeningState(stage: .judged, verdict: .maybe, screenedAt: now), for: id)
        try await store.jobs.setDecision(.saved, for: id, at: now)

        _ = try await store.ledger.record(
            [listing("acme/jobs/1", description: "Changed text.")], from: acme, complete: true, at: day(1))
        #expect(try await store.screening.state(for: id)?.verdict == .maybe)
        #expect(try await store.jobs.job(id)?.description == "Changed text.")
    }

    @Test func anotherSourcesCopyIsAttachedAndABoardWinsOverASearch() async throws {
        let store = try await emptyStore()
        let google = try await store.sources.search(.googleJobs, at: now)
        let searchCopy = listing(
            "search/123", host: "www.example-jobs.com", company: "Acme Inc.", title: "Sr. Software Engineer",
            description: "Search copy.")
        _ = try await store.ledger.record([searchCopy], from: google, complete: false, at: now)
        let id = try #require(try await store.jobs.summaries().first?.id)
        #expect(try await store.jobs.job(id)?.sourceKind == .googleJobs)

        let acme = try await store.board("acme")
        let boardCopy = listing("acme/jobs/9", title: "Senior Software Engineer", description: "The board's own text.")
        let outcome = try await store.ledger.record([boardCopy], from: acme, complete: true, at: day(1))
        #expect(outcome.attached == 1 && outcome.added == 0)
        let job = try #require(try await store.jobs.job(id))
        #expect(job.sourceKind == .greenhouse)
        #expect(job.primaryListingID == boardCopy.id)
        #expect(job.description == "The board's own text.")
        #expect(try await store.jobs.detail(id)?.listings.count == 2)
    }

    @Test func theSameAddressFromAnotherSourceAddsNothing() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let google = try await store.sources.search(.googleJobs, at: now)
        let outcome = try await store.ledger.record([listing("acme/jobs/1")], from: google, complete: false, at: day(1))
        #expect(outcome.known == 1)
        #expect(try await store.count("listing") == 1)
    }

    @Test func aListingClosesAfterTwoCompleteAnswersWithoutItAndReopensWhenBack() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record(
            [listing("acme/jobs/1"), listing("acme/jobs/2", title: "Data Engineer")], from: acme, complete: true,
            at: now)
        let first = try await store.ledger.record(
            [listing("acme/jobs/2", title: "Data Engineer")], from: acme, complete: true, at: day(1))
        #expect(first.closed == 0)
        // A search's answer is never complete: it can't close anything.
        _ = try await store.ledger.record([], from: acme, complete: false, at: day(2))
        let second = try await store.ledger.record(
            [listing("acme/jobs/2", title: "Data Engineer")], from: acme, complete: true, at: day(3))
        #expect(second.closed == 1)
        let closed = try #require(try await store.jobs.summaries().first { $0.title == "Software Engineer" })
        #expect(closed.closedAt == day(3))

        let back = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: day(4))
        #expect(back.reopened == 1)
        #expect(try await store.jobs.job(closed.id)?.closedAt == nil)
        #expect(try await store.jobs.detail(closed.id)?.events.map(\.kind) == [.found, .closed, .reopened])
    }

    @Test func anUnchangedAnswerRepeatsTheLastOne() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record(
            [listing("acme/jobs/1"), listing("acme/jobs/2", title: "Data Engineer")], from: acme, complete: true,
            at: now)
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: day(1))
        // 304: job 1 is seen again; job 2, already missing once, misses again and closes.
        let closed = try await store.ledger.recordUnchanged(acme, at: day(2))
        #expect(closed == 1)
        let jobs = try await store.jobs.summaries()
        #expect(jobs.first { $0.title == "Data Engineer" }?.closedAt == day(2))
        let open = try #require(jobs.first { $0.title == "Software Engineer" })
        #expect(open.closedAt == nil)
        #expect(try await store.jobs.job(open.id)?.lastSeenAt == day(2))
    }

    @Test func newPostingsOutsideYourLimitsAreLeftOutButKnownOnesAreStillSeen() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        let roles = RoleMatcher(families: [.software])
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let outcome = try await store.ledger.record(
            [
                listing("acme/jobs/1"),
                listing("acme/jobs/2", title: "Account Executive"),
                listing("acme/jobs/3", title: "Backend Developer", postedAt: day(-90)),
                listing("acme/jobs/4", title: "iOS Developer", textOmitted: true),
                listing("acme/ads/5", title: "Software Developer", isSnippet: true),
            ], from: acme, complete: true, at: day(1), postedAfter: day(-30), roles: roles)
        #expect(outcome.known == 1)
        #expect(outcome.otherRoles == 1)
        #expect(outcome.tooOld == 1)
        #expect(outcome.unread == 1)
        #expect(outcome.snippets == 1)
        #expect(outcome.added == 0)
        #expect(try await store.count("job") == 1)
    }

    @Test func aListingWithoutItsTextIsSeenAndKeepsItsText() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let outcome = try await store.ledger.record(
            [listing("acme/jobs/1", description: "", textOmitted: true)], from: acme, complete: true, at: day(1))
        #expect(outcome.known == 1 && outcome.changed == 0)
        let job = try #require(try await store.jobs.summaries().first)
        #expect(try await store.jobs.job(job.id)?.description == "Build services in Swift and Go.")
        #expect(try await store.jobs.job(job.id)?.lastSeenAt == day(1))
    }

    @Test func anArchivedJobStaysArchivedWhenItsListingIsSeen() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: day(-70))
        #expect(try await store.jobs.applyRetention(at: now).archived == 1)
        let outcome = try await store.ledger.record(
            [listing("acme/jobs/1", description: "Edited.")], from: acme, complete: true, at: day(1))
        #expect(outcome.known == 1 && outcome.added == 0 && outcome.changed == 0)
        #expect(try await store.jobs.summaries().isEmpty)
        #expect(try await store.jobs.summaries(.archived).count == 1)
    }

    @Test func aStaleSearchListingCloses() async throws {
        let store = try await emptyStore()
        let google = try await store.sources.search(.googleJobs, at: now)
        _ = try await store.ledger.record(
            [listing("x/1", host: "careers.example.com", postedAt: day(-50))], from: google, complete: false,
            at: day(-35))
        _ = try await store.ledger.record(
            [listing("x/2", host: "careers.example.com", title: "QA Engineer", postedAt: day(-10))], from: google,
            complete: false, at: day(-35))
        #expect(try await store.ledger.closeStaleSearchListings(at: now) == 1)
        #expect(try await store.jobs.summaries().filter { $0.closedAt != nil }.map(\.title) == ["Software Engineer"])
    }

    @Test func theSamePostingUnderAnotherCompanyNameIsOneJob() async throws {
        let store = try await emptyStore()
        let text = String(repeating: "We build open tools for science and publish everything we make. ", count: 4)
        let himalayas = try await store.sources.search(.himalayas, at: now)
        _ = try await store.ledger.record(
            [listing("j/1", host: "himalayas.app", company: "Open Science Foundation", description: text)],
            from: himalayas,
            complete: false, at: now)
        let lab = try await store.board("openlab", .ashby)
        let outcome = try await store.ledger.record(
            [listing("openlab/7", host: "jobs.ashbyhq.com", company: "Open Science Lab", description: text)], from: lab,
            complete: true, at: day(1))
        #expect(outcome.attached == 1)
        #expect(try await store.count("job") == 1)
    }

    @Test func clearingDeletesJobsYouHaventActedOnAndForgetsETags() async throws {
        let store = try await emptyStore()
        var acme = try await store.board("acme")
        acme.etag = "\"v1\""
        try await store.sources.save(acme)
        _ = try await store.ledger.record(
            [listing("acme/jobs/1"), listing("acme/jobs/2", title: "Data Engineer")], from: acme, complete: true,
            at: now)
        let saved = try #require(try await store.jobs.summaries().first { $0.title == "Data Engineer" })
        try await store.jobs.setDecision(.saved, for: saved.id, at: now)

        #expect(try await store.jobs.clearingPreview() == .init(deleted: 1, saved: 1))
        #expect(try await store.jobs.clear() == 1)
        #expect(try await store.jobs.summaries().map(\.id) == [saved.id])
        #expect(try await store.sources.source(acme.id)?.etag == nil)
        // The cleared posting comes back as new.
        let outcome = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: day(1))
        #expect(outcome.added == 1)
    }
}
