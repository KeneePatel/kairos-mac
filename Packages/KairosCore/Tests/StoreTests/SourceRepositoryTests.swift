import Foundation
import Testing

@testable import Store

@Suite("Source repository")
struct SourceRepositoryTests {
    @Test func addingASourceGivesItAUUIDv7AndHealthyDefaults() async throws {
        let repo = SourceRepository(try await migratedDatabase())
        let source = try await repo.add(kind: .greenhouse, config: #"{"token":"acme"}"#)
        #expect(source.id.uuid.6 >> 4 == 7)
        #expect(source.enabled && source.health == .ok && source.emptyRuns == 0 && source.lastRunAt == nil)
        #expect(source.updatedHLC != nil)
        #expect(try await repo.source(source.id) == source)
    }

    @Test func savingReplacesAndListingKeepsTheOrderAdded() async throws {
        let repo = SourceRepository(try await migratedDatabase())
        let greenhouse = try await repo.add(kind: .greenhouse)
        var adzuna = try await repo.add(kind: .adzuna, config: #"{"countries":["ca","us"]}"#)
        let indeed = try await repo.add(kind: .indeedCanada, enabled: false)
        adzuna.enabled = false
        try await repo.save(adzuna)
        #expect(try await repo.sources().map(\.id) == [greenhouse.id, adzuna.id, indeed.id])
        #expect(try await repo.sources(enabledOnly: true).map(\.id) == [greenhouse.id])
    }

    @Test func threeEmptyRunsInARowMarkASourceDegradedAndAResultHealsIt() async throws {
        let repo = SourceRepository(try await migratedDatabase())
        let id = try await repo.add(kind: .lever).id
        let day = Date(milliseconds: 1_760_000_000_000)
        try await repo.recordRun(of: id, found: 0, at: day)
        let second = try await repo.recordRun(of: id, found: 0, at: day)
        #expect(second?.health == .ok && second?.emptyRuns == 2)
        let third = try await repo.recordRun(of: id, found: 0, at: day)
        #expect(third?.health == .degraded)
        let healed = try await repo.recordRun(of: id, found: 4, at: day.addingTimeInterval(3_600))
        #expect(healed?.health == .ok && healed?.emptyRuns == 0)
        #expect(try await repo.source(id)?.lastRunAt == day.addingTimeInterval(3_600))
    }

    @Test func recordingARunForAMissingSourceDoesNothing() async throws {
        let repo = SourceRepository(try await migratedDatabase())
        #expect(try await repo.recordRun(of: UUID(), found: 1, at: Date()) == nil)
        #expect(try await repo.sources().isEmpty)
    }

    @Test func configMustBeJSON() async throws {
        let repo = SourceRepository(try await migratedDatabase())
        await #expect(throws: StoreError.self) { try await repo.add(kind: .ashby, config: "org=acme") }
    }

    @Test func aTombstoneHidesTheSourceAndSavingBringsItBack() async throws {
        let repo = SourceRepository(try await migratedDatabase())
        let source = try await repo.add(kind: .wellfound, enabled: false)
        let hlc = try await repo.tombstone(source.id)
        #expect(hlc > (source.updatedHLC ?? hlc))
        #expect(try await repo.source(source.id) == nil)
        #expect(try await repo.sources().isEmpty)
        try await repo.save(source)
        #expect(try await repo.source(source.id)?.kind == .wellfound)
    }

    @Test func anUnknownKindIsReportedNotGuessed() async throws {
        let db = try await migratedDatabase()
        let repo = SourceRepository(db)
        let source = try await repo.add(kind: .glassdoor)
        try await db.execute("UPDATE source SET kind = 'monster'")
        await #expect(throws: StoreError.corruptRow(table: "source", id: source.id.lowercased, column: "kind")) {
            try await repo.sources()
        }
    }
}
