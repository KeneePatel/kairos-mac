import Foundation
import Testing

@testable import Store

@Suite("Migrator")
struct MigratorTests {
    let first = Migration(version: 1, name: "a", sql: "CREATE TABLE a (x INTEGER);")
    let second = Migration(version: 2, name: "b", sql: "CREATE TABLE b (y TEXT); INSERT INTO b VALUES ('seed');")

    @Test func appliesMigrationsInOrderAndRecordsTheVersion() async throws {
        let db = try Database(path: ":memory:")
        let version = try await Migrator.migrate(db, with: [second, first])  // order given doesn't matter
        #expect(version == 2)
        #expect(try await db.userVersion() == 2)
        #expect(try await db.query("SELECT y FROM b").first?.string("y") == "seed")
    }

    @Test func runningAgainChangesNothing() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: [first, second])
        try await Migrator.migrate(db, with: [first, second])
        #expect(try await db.query("SELECT count(*) AS c FROM b").first?.int("c") == 1)  // seed not repeated
    }

    @Test func onlyNewMigrationsRun() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: [first])
        #expect(try await db.userVersion() == 1)
        try await Migrator.migrate(db, with: [first, second])
        #expect(try await db.userVersion() == 2)
    }

    @Test func aDatabaseFromANewerAppIsRefused() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: [first, second])
        await #expect(throws: StoreError.newerSchema(found: 2, known: 1)) {
            try await Migrator.migrate(db, with: [first])
        }
    }

    @Test func aFailingMigrationLeavesTheDatabaseAsItWas() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: [first])
        let broken = Migration(
            version: 2, name: "broken", sql: "CREATE TABLE c (z INTEGER); INSERT INTO nowhere VALUES (1);")
        await #expect(throws: StoreError.self) { try await Migrator.migrate(db, with: [first, broken]) }
        #expect(try await db.userVersion() == 1)
        let tables = try await db.query("SELECT name FROM sqlite_master WHERE name = 'c'")
        #expect(tables.isEmpty)  // the half-applied table was rolled back
    }

    @Test func gapsAndDuplicatesAreRejected() async throws {
        let db = try Database(path: ":memory:")
        let third = Migration(version: 3, name: "c", sql: "SELECT 1;")
        await #expect(throws: StoreError.self) { try await Migrator.migrate(db, with: [first, third]) }
        await #expect(throws: StoreError.self) { try await Migrator.migrate(db, with: [first, first]) }
        #expect(try await db.userVersion() == 0)
    }

    @Test(arguments: [
        ("001_sources_jobs.sql", 1, "sources_jobs"), ("012_x.sql", 12, "x"),
    ])
    func parsesMigrationFileNames(file: String, version: Int, name: String) throws {
        let parsed = try #require(Migrator.parse(fileName: file))
        #expect(parsed.0 == version && parsed.1 == name)
    }

    @Test(arguments: ["1_a.sql", "001.sql", "000_zero.sql", "abc_x.sql", "001_a.txt"])
    func rejectsBadMigrationFileNames(_ file: String) {
        #expect(Migrator.parse(fileName: file) == nil)
    }

    @Test func theBundledMigrationsAreNumberedFromOne() throws {
        let bundled = try Migrator.bundled()
        #expect(bundled.map(\.version) == Array(1..<(bundled.count + 1)))
    }
}
