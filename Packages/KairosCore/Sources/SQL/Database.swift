import Foundation
import SQLite3

public enum SQLError: Error, Equatable, Sendable, CustomStringConvertible {
    case open(path: String, message: String)
    case sqlite(code: Int32, message: String, sql: String)
    case parameterCount(expected: Int, got: Int)
    case newerSchema(found: Int, known: Int)
    case migration(String)
    /// A stored value this version can't read, such as an unknown enum value or broken JSON.
    case badRow(table: String, column: String, detail: String)

    public var description: String {
        switch self {
        case .open(let path, let message): "Can't open the database at \(path): \(message)"
        case .sqlite(let code, let message, _): "SQLite error \(code): \(message)"
        case .parameterCount(let expected, let got): "The statement takes \(expected) values, got \(got)"
        case .newerSchema(let found, let known):
            "The database was written by a newer Kairos (schema \(found); this version knows \(known))"
        case .migration(let detail): "A database update failed: \(detail)"
        case .badRow(let table, let column, let detail): "A row in \(table) has an unreadable \(column): \(detail)"
        }
    }

    static func message(_ db: OpaquePointer) -> String { String(cString: sqlite3_errmsg(db)) }
}

/// One SQLite connection. It only exists inside `Database`'s isolation, which serializes every use.
public final class Connection {
    let handle: OpaquePointer
    private var statements: [String: Statement] = [:]
    private var transactionDepth = 0

    init(path: String, readOnly: Bool) throws(SQLError) {
        var db: OpaquePointer?
        // NOMUTEX: the actor serializes access, so SQLite's own locking would be redundant.
        let flags =
            (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map(SQLError.message) ?? "out of memory"
            sqlite3_close_v2(db)
            throw .open(path: path, message: message)
        }
        handle = db
    }

    deinit {
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    /// Runs one statement with bound values. Statements are prepared once and reused.
    public func execute(_ sql: String, _ values: [SQLValue] = []) throws(SQLError) {
        _ = try run(sql, values)
    }

    /// Runs one query with bound values and returns its rows.
    public func query(_ sql: String, _ values: [SQLValue] = []) throws(SQLError) -> [Row] {
        try run(sql, values)
    }

    /// The first row of a query, if any.
    public func first(_ sql: String, _ values: [SQLValue] = []) throws(SQLError) -> Row? {
        try run(sql, values).first
    }

    /// Runs several statements with no parameters: migration files.
    public func executeScript(_ sql: String) throws(SQLError) {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? SQLError.message(handle)
            sqlite3_free(error)
            throw .sqlite(code: code, message: message, sql: sql)
        }
    }

    /// Rows the last statement changed.
    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Commits if `body` returns and rolls back if it throws. Nested calls use savepoints, so an
    /// inner failure the caller catches undoes only the inner work.
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

    private func run(_ sql: String, _ values: [SQLValue]) throws(SQLError) -> [Row] {
        let statement: Statement
        if let cached = statements[sql] {
            statement = cached
        } else {
            statement = try Statement(db: handle, sql: sql)
            // Ad hoc SQL built per call would grow the cache without bound; keep it to a working set.
            if statements.count > 200 { statements.removeAll() }
            statements[sql] = statement
        }
        defer { statement.reset() }
        try statement.bind(values)
        return try statement.rows()
    }
}

/// Kairos's SQLite database. An actor, so statements run one at a time on one connection, in the
/// order they were asked for. Group related statements in `transaction` both for atomicity and to
/// cross into the actor once.
public actor Database {
    public nonisolated let path: String
    public nonisolated let isReadOnly: Bool
    private let connection: Connection

    /// Opens (or creates) the database at `path`; ":memory:" for tests. A read-only database is
    /// never written, not even its journal mode.
    public init(path: String, readOnly: Bool = false) throws(SQLError) {
        self.path = path
        self.isReadOnly = readOnly
        let connection = try Connection(path: path, readOnly: readOnly)
        try connection.executeScript("PRAGMA busy_timeout = 5000;")
        if !readOnly {
            try connection.executeScript("PRAGMA foreign_keys = ON;")
            if path != ":memory:" {
                _ = try connection.query("PRAGMA journal_mode = WAL")
                try connection.executeScript("PRAGMA synchronous = NORMAL")
            }
        }
        self.connection = connection
    }

    public static func inMemory() throws(SQLError) -> Database {
        try Database(path: ":memory:")
    }

    public func execute(_ sql: String, _ values: [SQLValue] = []) throws(SQLError) {
        try connection.execute(sql, values)
    }

    public func query(_ sql: String, _ values: [SQLValue] = []) throws(SQLError) -> [Row] {
        try connection.query(sql, values)
    }

    public func first(_ sql: String, _ values: [SQLValue] = []) throws(SQLError) -> Row? {
        try connection.first(sql, values)
    }

    /// Runs `body` in one transaction: all of it commits, or none of it does.
    public func transaction<T: Sendable>(_ body: @Sendable (Connection) throws -> T) throws -> T {
        try connection.transaction(body)
    }

    /// Runs `body` with the connection and no transaction: several reads in one hop.
    public func read<T: Sendable>(_ body: @Sendable (Connection) throws -> T) throws -> T {
        try body(connection)
    }

    public func userVersion() throws(SQLError) -> Int {
        try connection.first("PRAGMA user_version")?.int("user_version") ?? 0
    }

    public func journalMode() throws(SQLError) -> String {
        try connection.first("PRAGMA journal_mode")?.string("journal_mode") ?? ""
    }

    /// The names of `table`'s columns, empty when there's no such table. The importer reads old
    /// databases whose columns depend on how far they were migrated.
    public func columns(of table: String) throws(SQLError) -> Set<String> {
        // PRAGMA arguments can't be bound; the name is checked to be a plain identifier first.
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return [] }
        return Set(try connection.query("PRAGMA table_info(\(table))").compactMap { $0.string("name") })
    }

    /// Writes a consistent copy of the database to `url` (`VACUUM INTO`), for backups.
    public func backUp(to url: URL) throws(SQLError) {
        try connection.execute("VACUUM INTO ?", [.text(url.path)])
    }

    /// Whether the system SQLite has what Kairos needs: JSON functions and STRICT tables.
    public func checkCapabilities() throws(SQLError) -> String? {
        let version = try connection.first("SELECT sqlite_version() AS v")?.string("v") ?? "?"
        let json = (try? connection.first("SELECT json_valid('{\"a\":1}') AS ok")?.bool("ok")) == true
        guard json else { return "This Mac's SQLite \(version) has no JSON functions." }
        guard !isReadOnly else { return nil }
        let strict = (try? connection.executeScript("CREATE TEMP TABLE kairos_probe (x INTEGER) STRICT")) != nil
        try? connection.executeScript("DROP TABLE IF EXISTS temp.kairos_probe")
        return strict ? nil : "This Mac's SQLite \(version) has no STRICT tables."
    }
}
