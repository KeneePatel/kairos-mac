import Foundation
import SQL
import Testing

@Suite("SQLite database")
struct DatabaseTests {
    @Test func bindsAndReadsEveryType() async throws {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT) STRICT")
        try await db.execute(
            "INSERT INTO t VALUES (?, ?, ?, ?, ?)", [42, 2.5, "héllo", .blob(Data([1, 2, 3])), .null])
        let row = try #require(try await db.first("SELECT * FROM t"))
        #expect(row.int("i") == 42 && row.double("r") == 2.5 && row.string("s") == "héllo")
        #expect(row.data("b") == Data([1, 2, 3]) && row["n"] == .null && row.string("n") == nil)
        #expect(row.double("i") == 42 && row.string("missing") == nil)
    }

    @Test func anEmptyBlobStaysABlob() async throws {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t (b BLOB)")
        try await db.execute("INSERT INTO t VALUES (?)", [.blob(Data())])
        #expect(try await db.first("SELECT typeof(b) AS kind FROM t")?.string("kind") == "blob")
    }

    @Test func aWrongNumberOfValuesIsAnError() async throws {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t (a INTEGER)")
        await #expect(throws: SQLError.parameterCount(expected: 1, got: 2)) {
            try await db.execute("INSERT INTO t VALUES (?)", [1, 2])
        }
    }

    @Test func aReusedStatementForgetsItsLastBindings() async throws {
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t (a INTEGER, b TEXT)")
        for index in 0..<50 { try await db.execute("INSERT INTO t VALUES (?, ?)", [.integer(Int64(index)), .text("x\(index)")]) }
        #expect(try await db.first("SELECT count(*) AS n, sum(a) AS s FROM t")?.int("n") == 50)
        #expect(try await db.first("SELECT b FROM t WHERE a = ?", [7])?.string("b") == "x7")
        #expect(try await db.first("SELECT b FROM t WHERE a = ?", [8])?.string("b") == "x8")
    }

    @Test func aTransactionThatThrowsLeavesNothing() async throws {
        struct Planned: Error {}
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t (a INTEGER)")
        await #expect(throws: Planned.self) {
            try await db.transaction { connection in
                try connection.execute("INSERT INTO t VALUES (1)")
                throw Planned()
            }
        }
        #expect(try await db.first("SELECT count(*) AS n FROM t")?.int("n") == 0)
    }

    @Test func aCaughtInnerFailureUndoesOnlyTheInnerWork() async throws {
        struct Planned: Error {}
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t (a INTEGER)")
        try await db.transaction { connection in
            try connection.execute("INSERT INTO t VALUES (1)")
            _ = try? connection.transaction { inner in
                try inner.execute("INSERT INTO t VALUES (2)")
                throw Planned()
            }
            try connection.execute("INSERT INTO t VALUES (3)")
        }
        #expect(try await db.query("SELECT a FROM t ORDER BY a").compactMap { $0.int("a") } == [1, 3])
    }

    @Test func aFileDatabaseUsesWALAndCanBeOpenedReadOnly() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kairos-sql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "test.sqlite").path
        let db = try Database(path: path)
        #expect(try await db.journalMode() == "wal")
        try await db.execute("CREATE TABLE t (a INTEGER)")
        try await db.execute("INSERT INTO t VALUES (7)")

        let reader = try Database(path: path, readOnly: true)
        #expect(try await reader.first("SELECT a FROM t")?.int("a") == 7)
        await #expect(throws: SQLError.self) { try await reader.execute("INSERT INTO t VALUES (8)") }
        #expect(try await reader.columns(of: "t") == ["a"])
        #expect(try await reader.columns(of: "missing").isEmpty)
        #expect(try await reader.columns(of: "t; DROP TABLE t").isEmpty)
    }

    @Test func backsUpToAConsistentCopy() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kairos-sql-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try Database(path: folder.appending(path: "a.sqlite").path)
        try await db.execute("CREATE TABLE t (a TEXT)")
        try await db.execute("INSERT INTO t VALUES ('kept')")
        let copy = folder.appending(path: "copy.sqlite")
        try await db.backUp(to: copy)
        let reopened = try Database(path: copy.path, readOnly: true)
        #expect(try await reopened.first("SELECT a FROM t")?.string("a") == "kept")
    }

    @Test func checksTheSystemSQLite() async throws {
        #expect(try await Database.inMemory().checkCapabilities() == nil)
    }

    @Test func decodesJSONColumnsAndReportsBadOnes() async throws {
        struct Point: Codable, Equatable { let x: Int }
        let db = try Database.inMemory()
        try await db.execute("CREATE TABLE t (j TEXT)")
        try await db.execute("INSERT INTO t VALUES ('{\"x\":3}'), ('not json')")
        let rows = try await db.query("SELECT j FROM t")
        #expect(try rows[0].json("j", as: Point.self, table: "t") == Point(x: 3))
        #expect(throws: SQLError.self) { try rows[1].json("j", as: Point.self, table: "t") }
    }
}

@Suite("Migrator")
struct MigratorTests {
    static let migrations = [
        Migration(version: 1, name: "a", sql: "CREATE TABLE a (x INTEGER);"),
        Migration(version: 2, name: "b", sql: "CREATE TABLE b (y INTEGER); INSERT INTO a VALUES (1);"),
    ]

    @Test func appliesEachMigrationOnceInOrder() async throws {
        let db = try Database.inMemory()
        #expect(try await Migrator.migrate(db, with: Self.migrations) == 2)
        #expect(try await Migrator.migrate(db, with: Self.migrations) == 2)
        #expect(try await db.first("SELECT count(*) AS n FROM a")?.int("n") == 1)
        #expect(try await db.userVersion() == 2)
    }

    @Test func aFailedMigrationLeavesTheVersionAlone() async throws {
        let db = try Database.inMemory()
        let broken = Self.migrations + [Migration(version: 3, name: "c", sql: "CREATE TABLE c (z INTEGER); NONSENSE;")]
        await #expect(throws: SQLError.self) { try await Migrator.migrate(db, with: broken) }
        #expect(try await db.userVersion() == 2)
        #expect(try await db.columns(of: "c").isEmpty)
    }

    @Test func refusesGapsAndNewerDatabases() async throws {
        let db = try Database.inMemory()
        await #expect(throws: SQLError.self) {
            try await Migrator.migrate(db, with: [Migration(version: 2, name: "b", sql: "SELECT 1;")])
        }
        try await db.execute("PRAGMA user_version = 9")
        await #expect(throws: SQLError.newerSchema(found: 9, known: 2)) {
            try await Migrator.migrate(db, with: Self.migrations)
        }
    }

    @Test func readsNumberedFilesFromAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kairos-migrations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "SELECT 2;".write(to: folder.appending(path: "002_second.sql"), atomically: true, encoding: .utf8)
        try "SELECT 1;".write(to: folder.appending(path: "001_first.sql"), atomically: true, encoding: .utf8)
        try "notes".write(to: folder.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let found = try Migrator.migrations(in: folder)
        #expect(found.map(\.version) == [1, 2] && found.map(\.name) == ["first", "second"])
        try "x".write(to: folder.appending(path: "3_bad.sql"), atomically: true, encoding: .utf8)
        #expect(throws: SQLError.self) { try Migrator.migrations(in: folder) }
    }
}
