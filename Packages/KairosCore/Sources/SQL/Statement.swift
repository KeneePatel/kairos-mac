import Foundation
import SQLite3

/// A value bound to, or read from, SQLite. Values always travel as bound parameters, never as SQL text.
public enum SQLValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: String?) { self = value.map(SQLValue.text) ?? .null }
    public init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    public init(_ value: Int64?) { self = value.map(SQLValue.integer) ?? .null }
    public init(_ value: Double?) { self = value.map(SQLValue.real) ?? .null }
    public init(_ value: Bool?) { self = value.map { .integer($0 ? 1 : 0) } ?? .null }
    public init(_ value: Data?) { self = value.map(SQLValue.blob) ?? .null }
    /// Milliseconds since 1970, the form every time column stores.
    public init(_ value: Date?) {
        self = value.map { .integer(Int64(($0.timeIntervalSince1970 * 1000).rounded(.down))) } ?? .null
    }
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByNilLiteral, ExpressibleByBooleanLiteral
{
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .integer(value ? 1 : 0) }
}

/// The column names of one result set, shared by its rows.
public final class ColumnIndex: Sendable {
    public let names: [String]
    let positions: [String: Int]

    init(_ names: [String]) {
        self.names = names
        positions = Dictionary(names.enumerated().map { ($1, $0) }) { first, _ in first }
    }
}

/// One result row. Columns are looked up by name; typed accessors return nil for NULL or a type mismatch.
public struct Row: Sendable, Equatable {
    public let columns: ColumnIndex
    public let values: [SQLValue]

    public static func == (lhs: Row, rhs: Row) -> Bool {
        lhs.columns.names == rhs.columns.names && lhs.values == rhs.values
    }

    public subscript(_ column: String) -> SQLValue {
        guard let i = columns.positions[column] else { return .null }
        return values[i]
    }

    public func string(_ column: String) -> String? {
        if case .text(let v) = self[column] { return v }
        return nil
    }

    public func int64(_ column: String) -> Int64? {
        switch self[column] {
        case .integer(let v): v
        case .real(let v): Int64(exactly: v.rounded(.down))
        default: nil
        }
    }

    public func int(_ column: String) -> Int? { int64(column).map { Int($0) } }

    public func double(_ column: String) -> Double? {
        switch self[column] {
        case .real(let v): v
        case .integer(let v): Double(v)
        default: nil
        }
    }

    public func bool(_ column: String) -> Bool? { int64(column).map { $0 != 0 } }

    public func data(_ column: String) -> Data? {
        if case .blob(let v) = self[column] { return v }
        return nil
    }

    /// A time column (milliseconds since 1970) as a date.
    public func date(_ column: String) -> Date? {
        int64(column).map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// A JSON column decoded, nil when NULL; a value that doesn't decode is a bad row.
    public func json<T: Decodable>(_ column: String, as type: T.Type, table: String) throws(SQLError) -> T? {
        guard let text = string(column) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw .badRow(table: table, column: column, detail: String(describing: error))
        }
    }
}

/// A prepared statement, owned by a `Connection` and never leaving its actor.
final class Statement {
    private let handle: OpaquePointer
    private let db: OpaquePointer
    let sql: String
    private var columns: ColumnIndex?

    init(db: OpaquePointer, sql: String) throws(SQLError) {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw .sqlite(code: code, message: SQLError.message(db), sql: sql)
        }
        self.handle = statement
        self.db = db
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func bind(_ values: [SQLValue]) throws(SQLError) {
        let expected = Int(sqlite3_bind_parameter_count(handle))
        guard expected == values.count else { throw .parameterCount(expected: expected, got: values.count) }
        // SQLITE_TRANSIENT: SQLite copies the bytes before the call returns.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(handle, i)
            case .integer(let v):
                code = sqlite3_bind_int64(handle, i, v)
            case .real(let v):
                code = sqlite3_bind_double(handle, i, v)
            case .text(let v):
                code = sqlite3_bind_text(handle, i, v, -1, transient)
            case .blob(let v) where v.isEmpty:
                // A nil pointer would bind NULL; an empty blob is still a blob.
                code = sqlite3_bind_zeroblob(handle, i, 0)
            case .blob(let v):
                code = v.withUnsafeBytes { sqlite3_bind_blob(handle, i, $0.baseAddress, Int32($0.count), transient) }
            }
            guard code == SQLITE_OK else { throw .sqlite(code: code, message: SQLError.message(db), sql: sql) }
        }
    }

    /// Runs the statement to completion and returns every row.
    func rows() throws(SQLError) -> [Row] {
        let count = Int(sqlite3_column_count(handle))
        let index: ColumnIndex
        if let columns, columns.names.count == count {
            index = columns
        } else {
            index = ColumnIndex((0..<count).map { String(cString: sqlite3_column_name(handle, Int32($0))) })
            columns = index
        }
        var result: [Row] = []
        while true {
            let code = sqlite3_step(handle)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw .sqlite(code: code, message: SQLError.message(db), sql: sql) }
            result.append(Row(columns: index, values: (0..<count).map { value(at: Int32($0)) }))
        }
    }

    private func value(at i: Int32) -> SQLValue {
        switch sqlite3_column_type(handle, i) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(handle, i))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(handle, i))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(handle, i) else { return .text("") }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let bytes = Int(sqlite3_column_bytes(handle, i))
            guard bytes > 0, let pointer = sqlite3_column_blob(handle, i) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: bytes))
        default:
            return .null
        }
    }
}
