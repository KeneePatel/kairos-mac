import Foundation

/// Reads typed columns for a repository, throwing `corruptRow` instead of guessing when a stored
/// value doesn't fit (a missing NOT NULL value, or an enum value this version doesn't know).
public struct RowReader {
    public let row: Row
    public let table: String

    public init(row: Row, table: String) {
        self.row = row
        self.table = table
    }

    private var id: String { row.string("id") ?? "?" }

    public func corrupt(_ column: String) -> StoreError {
        .corruptRow(table: table, id: id, column: column)
    }

    public func string(_ column: String) throws(StoreError) -> String {
        guard let value = row.string(column) else { throw corrupt(column) }
        return value
    }

    public func int(_ column: String) throws(StoreError) -> Int {
        guard let value = row.int(column) else { throw corrupt(column) }
        return value
    }

    public func bool(_ column: String) throws(StoreError) -> Bool {
        guard let value = row.bool(column) else { throw corrupt(column) }
        return value
    }

    public func date(_ column: String) throws(StoreError) -> Date {
        guard let value = row.int64(column) else { throw corrupt(column) }
        return Date(milliseconds: value)
    }

    public func optionalDate(_ column: String) -> Date? {
        row.int64(column).map(Date.init(milliseconds:))
    }

    public func uuid(_ column: String) throws(StoreError) -> UUID {
        guard let text = row.string(column), let value = UUID(uuidString: text) else { throw corrupt(column) }
        return value
    }

    public func hlc(_ column: String) throws(StoreError) -> HLCTimestamp {
        guard let text = row.string(column), let value = try? HLCTimestamp(text) else { throw corrupt(column) }
        return value
    }

    public func value<E: RawRepresentable>(_ column: String, as type: E.Type) throws(StoreError) -> E
    where E.RawValue == String {
        guard let text = row.string(column), let value = E(rawValue: text) else { throw corrupt(column) }
        return value
    }

    public func optionalValue<E: RawRepresentable>(_ column: String, as type: E.Type) throws(StoreError) -> E?
    where E.RawValue == String {
        guard let text = row.string(column) else { return nil }
        guard let value = E(rawValue: text) else { throw corrupt(column) }
        return value
    }

    public func json<T: Decodable>(_ column: String, as type: T.Type) throws(StoreError) -> T? {
        guard let text = row.string(column) else { return nil }
        guard let value = try? JSONDecoder().decode(T.self, from: Data(text.utf8)) else { throw corrupt(column) }
        return value
    }
}

extension Date {
    public init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    public var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }
}

extension SQLValue {
    public init(_ date: Date?) { self = date.map { .integer($0.milliseconds) } ?? .null }

    public init<E: RawRepresentable>(_ value: E?) where E.RawValue == String { self = SQLValue(value?.rawValue) }

    public init<T: Encodable>(json value: T?) throws(StoreError) {
        guard let value else {
            self = .null
            return
        }
        guard let data = try? JSONEncoder().encode(value) else { throw .invalidValue("can't encode \(T.self) as JSON") }
        self = .text(String(decoding: data, as: UTF8.self))
    }
}
