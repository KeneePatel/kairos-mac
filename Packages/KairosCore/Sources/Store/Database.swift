import Foundation
import SQLite3

public enum StoreError: Error, Equatable, Sendable {
    case open(path: String, message: String)
    case sqlite(code: Int32, message: String, sql: String)
    case parameterCount(expected: Int, got: Int)
    case newerSchema(found: Int, known: Int)
    case migrationOrder(String)
    case invalidAccount(String)
    case directory(String)
    case invalidDevice(String)
    /// A value that can't be stored, such as a pay range of infinity.
    case invalidValue(String)
    /// A stored value this version can't read, such as an unknown enum value.
    case corruptRow(table: String, id: String, column: String)

    static func message(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }
}

/// What the system SQLite library supports. JSON1 and STRICT tables are required (SPEC §7); without
/// FTS5, search falls back to LIKE.
public struct SQLiteCapabilities: Sendable, Equatable {
    public let version: String
    public let json1: Bool
    public let fts5: Bool
    public let strictTables: Bool
}

/// One SQLite connection. It only exists inside `Database`'s isolation, which serializes every use.
public final class Connection {
    let handle: OpaquePointer
    private var transactionDepth = 0

    init(path: String) throws(StoreError) {
        var db: OpaquePointer?
        // NOMUTEX: the actor already serializes access, so SQLite's own locking would be redundant.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map(StoreError.message) ?? "out of memory"
            sqlite3_close_v2(db)
            throw .open(path: path, message: message)
        }
        handle = db
    }

    deinit { sqlite3_close_v2(handle) }

    /// Runs one statement with bound values.
    public func execute(_ sql: String, _ values: [SQLValue] = []) throws(StoreError) {
        let statement = try Statement(db: handle, sql: sql)
        try statement.bind(values)
        _ = try statement.rows()
    }

    /// Runs one query with bound values and returns its rows.
    public func query(_ sql: String, _ values: [SQLValue] = []) throws(StoreError) -> [Row] {
        let statement = try Statement(db: handle, sql: sql)
        try statement.bind(values)
        return try statement.rows()
    }

    /// Runs several statements with no parameters, for migration files.
    public func executeScript(_ sql: String) throws(StoreError) {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? StoreError.message(handle)
            sqlite3_free(error)
            throw .sqlite(code: code, message: message, sql: sql)
        }
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Commits if `body` returns, rolls back if it throws. Nested calls use savepoints, so an inner
    /// failure that the caller catches undoes only the inner work.
    public func transaction<T>(_ body: (Connection) throws -> T) throws -> T {
        let depth = transactionDepth
        let savepoint = "kairos_sp_\(depth)"
        try executeScript(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body(self)
            try executeScript(depth == 0 ? "COMMIT" : "RELEASE \(savepoint)")
            return result
        } catch {
            try? executeScript(depth == 0 ? "ROLLBACK" : "ROLLBACK TO \(savepoint); RELEASE \(savepoint)")
            throw error
        }
    }
}

/// One clock reading for a write. Every synced row the write touches gets `hlc` (SPEC §6.4).
public struct WriteStamp: Sendable, Equatable {
    public let hlc: HLCTimestamp
    public let milliseconds: Int64
}

/// The app's SQLite database. An actor, so every statement runs one at a time on one connection.
/// It also owns the device's hybrid logical clock, so stamps are taken in commit order.
public actor Database {
    public let path: String
    private let connection: Connection
    private var clock: HybridLogicalClock
    private var ids = UUIDv7Generator()
    private let now: @Sendable () -> Int64

    /// Opens (or creates) the database at `path`. Use ":memory:" for tests.
    /// `device` is the 8-hex-digit id in this device's HLC stamps; random when nil. The sync task
    /// stores a stable one in `sync_state` and passes it here. `now` is the wall clock in milliseconds.
    public init(
        path: String, device: String? = nil, now: @escaping @Sendable () -> Int64 = Database.wallClockMilliseconds
    ) throws(StoreError) {
        let device = device ?? String(format: "%08x", UInt32.random(in: .min ... .max))
        guard let clock = try? HybridLogicalClock(device: device) else { throw .invalidDevice(device) }
        self.clock = clock
        self.now = now
        self.path = path
        let connection = try Connection(path: path)
        try connection.executeScript("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;")
        if path != ":memory:" {
            _ = try connection.query("PRAGMA journal_mode = WAL")
            try connection.executeScript("PRAGMA synchronous = NORMAL")
        }
        self.connection = connection
    }

    public func execute(_ sql: String, _ values: [SQLValue] = []) throws(StoreError) {
        try connection.execute(sql, values)
    }

    public func query(_ sql: String, _ values: [SQLValue] = []) throws(StoreError) -> [Row] {
        try connection.query(sql, values)
    }

    /// Runs `body` in one transaction: all of it commits, or none of it does.
    public func transaction<T: Sendable>(_ body: @Sendable (Connection) throws -> T) throws -> T {
        try connection.transaction(body)
    }

    /// Like `transaction`, and hands `body` a fresh stamp for the synced rows it writes.
    public func write<T: Sendable>(_ body: @Sendable (Connection, WriteStamp) throws -> T) throws -> T {
        let milliseconds = now()
        let stamp = WriteStamp(hlc: clock.tick(now: milliseconds), milliseconds: milliseconds)
        return try connection.transaction { try body($0, stamp) }
    }

    /// A new UUIDv7 for a row that isn't a job (SPEC §6.1).
    public func newID() -> UUID {
        ids.next(now: UInt64(clamping: now()))
    }

    public static let wallClockMilliseconds: @Sendable () -> Int64 = {
        Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
    }

    public func journalMode() throws(StoreError) -> String {
        try connection.query("PRAGMA journal_mode").first?.string("journal_mode") ?? ""
    }

    public func userVersion() throws(StoreError) -> Int {
        try connection.query("PRAGMA user_version").first?.int("user_version") ?? 0
    }

    /// Checks the system SQLite at startup (SPEC §7).
    public func capabilities() throws(StoreError) -> SQLiteCapabilities {
        let version = try connection.query("SELECT sqlite_version() AS v").first?.string("v") ?? "?"
        let json1 = (try? connection.query("SELECT json_valid('{\"a\":1}') AS ok").first?.bool("ok")) == true
        let strict = (try? connection.executeScript("CREATE TEMP TABLE kairos_probe_strict (x INTEGER) STRICT")) != nil
        let fts5 = (try? connection.executeScript("CREATE VIRTUAL TABLE temp.kairos_probe_fts USING fts5(x)")) != nil
        try? connection.executeScript(
            "DROP TABLE IF EXISTS temp.kairos_probe_strict; DROP TABLE IF EXISTS temp.kairos_probe_fts;")
        return SQLiteCapabilities(version: version, json1: json1, fts5: fts5, strictTables: strict)
    }
}
