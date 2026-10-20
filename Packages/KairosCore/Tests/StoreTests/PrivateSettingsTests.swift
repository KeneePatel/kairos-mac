import Foundation
import Testing

@testable import Store

private struct Sample: Codable, Equatable {
    var status: String
}

@Suite("Private settings")
struct PrivateSettingsTests {
    /// Work authorization and clearance stay on this Mac (SPEC §6.2): no sync columns, so the outbox
    /// has nothing to pick up.
    @Test func theTableIsStrictAndCannotSync() async throws {
        let db = try await migratedDatabase()
        let strict = try await db.query("SELECT strict FROM pragma_table_list WHERE name = 'private_setting'")
        #expect(strict.first?.int("strict") == 1)
        let columns = try await db.query("SELECT name FROM pragma_table_info('private_setting')")
            .compactMap { $0.string("name") }
        #expect(Set(columns) == ["key", "value"])
    }

    @Test func valuesRoundTripAndDeleteForGood() async throws {
        let db = try await migratedDatabase()
        let repo = PrivateSettingsRepository(db)
        #expect(try await repo.value("work_profile", as: Sample.self) == nil)
        try await repo.save(Sample(status: "citizen"), for: "work_profile")
        try await repo.save(Sample(status: "work_permit"), for: "work_profile")
        #expect(try await repo.value("work_profile", as: Sample.self) == Sample(status: "work_permit"))
        try await repo.delete("work_profile")
        #expect(try await repo.value("work_profile", as: Sample.self) == nil)
        #expect(try await db.query("SELECT key FROM private_setting").isEmpty)  // gone, not a tombstone
    }

    @Test func onlyJSONIsStored() async throws {
        let db = try await migratedDatabase()
        await #expect(throws: (any Error).self) {
            try await db.write { connection, _ in
                try connection.execute("INSERT INTO private_setting (key, value) VALUES ('x', 'not json')")
            }
        }
    }
}
