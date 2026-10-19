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

/// One result row. Columns are looked up by name; typed accessors return nil for NULL or a type mismatch.
public struct Row: Sendable, Equatable {
    public let columns: [String]
    public let values: [SQLValue]

    public subscript(_ column: String) -> SQLValue {
        guard let i = columns.firstIndex(of: column) else { return .null }
        return values[i]
    }

    public func string(_ column: String) -> String? {
        if case .text(let v) = self[column] { return v }
        return nil
    }

    public func int64(_ column: String) -> Int64? {
        if case .integer(let v) = self[column] { return v }
        return nil
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
}

/// A prepared statement. Owned by a `Connection`; never leaves its actor.
final class Statement {
    private let handle: OpaquePointer
    private let db: OpaquePointer
    let sql: String

    init(db: OpaquePointer, sql: String) throws(StoreError) {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw .sqlite(code: code, message: StoreError.message(db), sql: sql)
        }
        self.handle = statement
        self.db = db
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [SQLValue]) throws(StoreError) {
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
            guard code == SQLITE_OK else { throw .sqlite(code: code, message: StoreError.message(db), sql: sql) }
        }
    }

    /// Runs the statement to completion and returns every row.
    func rows() throws(StoreError) -> [Row] {
        let count = Int(sqlite3_column_count(handle))
        let columns = (0..<count).map { String(cString: sqlite3_column_name(handle, Int32($0))) }
        var result: [Row] = []
        while true {
            let code = sqlite3_step(handle)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw .sqlite(code: code, message: StoreError.message(db), sql: sql) }
            result.append(Row(columns: columns, values: (0..<count).map { value(at: Int32($0)) }))
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
