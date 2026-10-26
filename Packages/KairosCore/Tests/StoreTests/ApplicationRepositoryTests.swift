import Foundation
import Testing

@testable import Store

private let day: TimeInterval = 86_400
private let applied = Date(milliseconds: 1_760_000_000_000)

/// Story 6: mark a job applied, then move it through screen, interview, offer, rejected or ghosted,
/// with notes and a follow-up reminder (T45).
@Suite("Applications")
struct ApplicationRepositoryTests {
    @Test func bothTablesAreStrictAndCarrySyncColumns() async throws {
        let db = try await migratedDatabase()
        for table in ["application", "application_event"] {
            let strict = try await db.query("SELECT strict FROM pragma_table_list WHERE name = ?", [.text(table)])
            #expect(strict.first?.int("strict") == 1, "\(table) is not STRICT")
            let columns = try await db.query("SELECT name FROM pragma_table_info(?)", [.text(table)])
                .compactMap { $0.string("name") }
            #expect(columns.contains("updated_hlc") && columns.contains("deleted"), "\(table) can't sync")
        }
    }

    /// Applying records when and how, starts the timeline, and marks the job applied. Applying to the
    /// same job again changes nothing.
    @Test func applyingStartsTheTimelineAndMarksTheJob() async throws {
        let db = try await migratedDatabase()
        let job = sampleJob(1)
        try await JobRepository(db).upsert([job])
        let build = UUID.v7()
        let repo = ApplicationRepository(db)
        let application = try await repo.apply(job: job.id, build: build, channel: "Greenhouse", at: applied)
        #expect(application.status == .applied && application.buildID == build && application.channel == "Greenhouse")
        #expect(try await repo.application(for: job.id) == application)
        #expect(try await repo.events(for: application.id).map(\.kind) == [.status(.applied)])
        #expect(try await JobRepository(db).job(job.id)?.state == .applied)
        let again = try await repo.apply(job: job.id, at: applied.addingTimeInterval(day))
        let all = try await repo.applications()
        #expect(again == application && all.count == 1)
    }

    /// Each status change appends a line with your note; notes alone don't move the status.
    @Test func theTimelineKeepsEveryStepInOrder() async throws {
        let db = try await migratedDatabase()
        let repo = ApplicationRepository(db)
        let id = try await repo.apply(job: sampleJob(1).id, at: applied).id
        try await repo.setStatus(
            .screen, for: id, at: applied.addingTimeInterval(5 * day), note: " 30 min recruiter call ")
        try await repo.addNote("Sent the take-home", to: id, at: applied.addingTimeInterval(7 * day))
        try await repo.addNote("   ", to: id, at: applied.addingTimeInterval(7 * day))  // nothing to add
        try await repo.setStatus(.interview, for: id, at: applied.addingTimeInterval(9 * day))
        try await repo.setStatus(.rejected, for: id, at: applied.addingTimeInterval(12 * day), note: "Role filled")

        let events = try await repo.events(for: id)
        #expect(
            events.map(\.kind) == [.status(.applied), .status(.screen), .note, .status(.interview), .status(.rejected)])
        #expect(events.map(\.note) == [nil, "30 min recruiter call", "Sent the take-home", nil, "Role filled"])
        let application = try #require(try await repo.application(id))
        #expect(application.status == .rejected && application.status.isClosed)
        #expect(application.statusAt == applied.addingTimeInterval(12 * day))
        #expect(!ApplicationStatus.offer.isClosed && ApplicationStatus.ghosted.isClosed)
    }

    @Test func aFollowUpAndNotesAreKept() async throws {
        let db = try await migratedDatabase()
        let repo = ApplicationRepository(db)
        let id = try await repo.apply(job: sampleJob(1).id, at: applied).id
        let due = applied.addingTimeInterval(7 * day)
        try await repo.setFollowUp(due, "Email the recruiter", for: id)
        try await repo.setNotes("Team runs on Go and Kafka.", for: id)
        var application = try #require(try await repo.application(id))
        #expect(application.nextActionAt == due && application.nextAction == "Email the recruiter")
        #expect(application.notes == "Team runs on Go and Kafka.")
        try await repo.setFollowUp(nil, "ignored", for: id)
        application = try #require(try await repo.application(id))
        #expect(application.nextActionAt == nil && application.nextAction == nil)
    }

    /// The most recently moved first.
    @Test func theListPutsTheLatestMoveFirst() async throws {
        let db = try await migratedDatabase()
        let repo = ApplicationRepository(db)
        let first = try await repo.apply(job: sampleJob(1).id, at: applied).id
        let second = try await repo.apply(job: sampleJob(2).id, at: applied.addingTimeInterval(day)).id
        #expect(try await repo.applications().map(\.id) == [second, first])
        try await repo.setStatus(.interview, for: first, at: applied.addingTimeInterval(2 * day))
        #expect(try await repo.applications().map(\.id) == [first, second])
    }

    /// Deleting is a tombstone (it syncs), and the job goes back to new so you can apply again.
    @Test func deletingTombstonesAndFreesTheJob() async throws {
        let db = try await migratedDatabase()
        let job = sampleJob(1)
        try await JobRepository(db).upsert([job])
        let repo = ApplicationRepository(db)
        let id = try await repo.apply(job: job.id, at: applied).id
        try await repo.delete(id)
        let gone = try await repo.application(id)
        let timeline = try await repo.events(for: id)
        #expect(gone == nil && timeline.isEmpty)
        #expect(try await JobRepository(db).job(job.id)?.state == .new)
        let rows = try await db.query("SELECT deleted FROM application WHERE id = ?", [.text(id.lowercased)])
        #expect(rows.first?.int("deleted") == 1)
        let again = try await repo.apply(job: job.id, at: applied.addingTimeInterval(day))
        #expect(again.id != id)
        try await repo.delete(UUID())  // an unknown id is fine
    }

    /// Applied's scopes and the Interviews board (ADR-016): sent and waiting, moving, or closed.
    @Test func everyStatusHasOneStage() {
        #expect(ApplicationStatus.allCases.filter { $0.stage == .waiting } == [.applied])
        #expect(ApplicationStatus.allCases.filter { $0.stage == .inProgress } == [.screen, .interview, .offer])
        #expect(ApplicationStatus.allCases.allSatisfy { ($0.stage == .closed) == $0.isClosed })
    }

    /// Silent: still Applied a month after its last change. Anything that moved isn't.
    @Test func silenceStartsAtThirtyDaysAtApplied() {
        let waiting = Application(id: UUID(), jobID: sampleJob(1).id, appliedAt: applied, statusAt: applied)
        #expect(!waiting.isSilent(at: applied.addingTimeInterval(29 * day)))
        #expect(waiting.isSilent(at: applied.addingTimeInterval(30 * day)))
        var screened = waiting
        screened.status = .screen
        #expect(!screened.isSilent(at: applied.addingTimeInterval(60 * day)))
    }

    /// Several applications move in one write, each with its own timeline line; none is fine.
    @Test func severalMoveTogether() async throws {
        let db = try await migratedDatabase()
        let repo = ApplicationRepository(db)
        let ids = [
            try await repo.apply(job: sampleJob(1).id, at: applied).id,
            try await repo.apply(job: sampleJob(2).id, at: applied).id,
        ]
        let kept = try await repo.apply(job: sampleJob(3).id, at: applied).id
        let later = applied.addingTimeInterval(31 * day)
        try await repo.setStatus(.ghosted, for: ids, at: later)
        try await repo.setStatus(.ghosted, for: [], at: later)
        for id in ids {
            let application = try #require(try await repo.application(id))
            #expect(application.status == .ghosted && application.statusAt == later)
            #expect(try await repo.events(for: id).map(\.kind) == [.status(.applied), .status(.ghosted)])
        }
        #expect(try await repo.application(kept)?.status == .applied)
    }
}
