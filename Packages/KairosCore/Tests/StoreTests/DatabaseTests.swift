import Foundation
import Testing

@testable import Store

@Suite("Database")
struct DatabaseTests {
    func memory() throws -> Database { try Database(path: ":memory:") }

    @Test func everyValueTypeRoundTripsThroughBoundParameters() async throws {
        let db = try memory()
        try await db.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT) STRICT")
        let hostile = "O'Brien'); DROP TABLE t; --"
        try await db.execute(
            "INSERT INTO t VALUES (?, ?, ?, ?, ?)",
            [.integer(.max), .real(3.25), .text(hostile), .blob(Data([0, 1, 255])), .null])
        let row = try #require(try await db.query("SELECT * FROM t").first)
        #expect(row.int64("i") == .max)
        #expect(row.double("r") == 3.25)
        #expect(row.string("s") == hostile)  // stored as data, never run as SQL
        #expect(row.data("b") == Data([0, 1, 255]))
        #expect(row["n"] == .null)
        #expect(try await db.query("SELECT count(*) AS c FROM t").first?.int("c") == 1)
    }

    @Test func anEmptyBlobStaysABlob() async throws {
        let db = try memory()
        try await db.execute("CREATE TABLE t (b BLOB)")
        try await db.execute("INSERT INTO t VALUES (?)", [.blob(Data())])
        #expect(try await db.query("SELECT b FROM t").first?["b"] == .blob(Data()))
    }

    @Test func missingOptionalsBindAsNullAndLiteralsKeepTheirType() async throws {
        let db = try memory()
        try await db.execute("CREATE TABLE t (s, i, w, d, b, x)")
        let absent: [SQLValue] = [
            SQLValue(String?.none), SQLValue(Int?.none), SQLValue(Int64?.none),
            SQLValue(Double?.none), SQLValue(Bool?.none), SQLValue(Data?.none),
        ]
        try await db.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?)", absent)
        let present: [SQLValue] = [
            SQLValue("a"), SQLValue(7), SQLValue(Int64(8)), SQLValue(0.5), SQLValue(true), SQLValue(Data([9])),
        ]
        try await db.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?)", present)
        try await db.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?)", ["a", 7, 8, 0.5, true, nil])
        let rows = try await db.query("SELECT * FROM t ORDER BY rowid")
        #expect(rows[0].values == Array(repeating: .null, count: 6))
        #expect(rows[1].values == [.text("a"), .integer(7), .integer(8), .real(0.5), .integer(1), .blob(Data([9]))])
        #expect(rows[2].values == [.text("a"), .integer(7), .integer(8), .real(0.5), .integer(1), .null])
        #expect(rows[1].bool("b") == true)
    }

    @Test func typedAccessorsReturnNilRatherThanConverting() {
        let row = Row(columns: ["s", "i"], values: [.text("12"), .integer(3)])
        #expect(row.int("s") == nil)  // text "12" is not silently turned into a number
        #expect(row.string("i") == nil)
        #expect(row.data("s") == nil)
        #expect(row.double("s") == nil)
        #expect(row.double("i") == 3)  // an integer column read as a double is exact
        #expect(row["missing"] == .null)
    }

    @Test func aConnectionReportsChangedRowsAndTheNewRowID() async throws {
        let db = try memory()
        try await db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, x INTEGER)")
        let (changed, id) = try await db.transaction { connection in
            try connection.execute("INSERT INTO t (x) VALUES (1), (2), (3)")
            try connection.execute("UPDATE t SET x = x + 1 WHERE x >= 2")
            return (connection.changes, connection.lastInsertRowID)
        }
        #expect(changed == 2)
        #expect(id == 3)
    }

    @Test func openingAPathThatCantExistFails() {
        #expect {
            _ = try Database(path: "/nonexistent-\(UUID().uuidString)/kairos.sqlite")
        } throws: { error in
            guard case StoreError.open = error else { return false }
            return true
        }
    }

    @Test func aWrongParameterCountIsRejected() async throws {
        let db = try memory()
        try await db.execute("CREATE TABLE t (a, b)")
        await #expect(throws: StoreError.parameterCount(expected: 2, got: 1)) {
            try await db.execute("INSERT INTO t VALUES (?, ?)", ["only one"])
        }
    }

    @Test func sqlErrorsCarrySQLitesMessage() async throws {
        let db = try memory()
        await #expect {
            try await db.execute("SELEC nonsense")
        } throws: { error in
            guard case StoreError.sqlite(_, let message, let sql) = error else { return false }
            return message.contains("syntax error") && sql == "SELEC nonsense"
        }
    }

    @Test func aTransactionCommitsWhenItsBodyReturns() async throws {
        let db = try memory()
        try await db.execute("CREATE TABLE t (x INTEGER)")
        try await db.transaction { connection in
            try connection.execute("INSERT INTO t VALUES (1)")
            try connection.execute("INSERT INTO t VALUES (2)")
        }
        #expect(try await db.query("SELECT count(*) AS c FROM t").first?.int("c") == 2)
    }

    @Test func aTransactionRollsBackWhenItsBodyThrows() async throws {
        let db = try memory()
        try await db.execute("CREATE TABLE t (x INTEGER)")
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await db.transaction { connection in
                try connection.execute("INSERT INTO t VALUES (1)")
                throw Boom()
            }
        }
        #expect(try await db.query("SELECT count(*) AS c FROM t").first?.int("c") == 0)
    }

    @Test func aCaughtInnerFailureUndoesOnlyTheInnerWork() async throws {
        let db = try memory()
        try await db.execute("CREATE TABLE t (x INTEGER)")
        struct Boom: Error {}
        try await db.transaction { connection in
            try connection.execute("INSERT INTO t VALUES (1)")
            _ = try? connection.transaction { inner in
                try inner.execute("INSERT INTO t VALUES (2)")
                throw Boom()
            }
            try connection.execute("INSERT INTO t VALUES (3)")
        }
        let values = try await db.query("SELECT x FROM t ORDER BY x").compactMap { $0.int("x") }
        #expect(values == [1, 3])
    }

    @Test func aFileDatabaseUsesWriteAheadLogging() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kairos-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try Database(path: folder.appendingPathComponent("test.sqlite").path)
        #expect(try await db.journalMode() == "wal")
    }

    @Test func theSystemSQLiteHasWhatTheSpecNeeds() async throws {
        let caps = try await memory().capabilities()
        #expect(caps.json1)
        #expect(caps.strictTables)
        // FTS5 is optional: search falls back to LIKE without it. Recorded, not required.
        print("SQLite \(caps.version): JSON1 \(caps.json1), STRICT \(caps.strictTables), FTS5 \(caps.fts5)")
    }
}
