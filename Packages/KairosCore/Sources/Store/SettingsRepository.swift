import Foundation

/// Reads and writes `setting` rows: one JSON document per key, stamped on every write.
public struct SettingsRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// The document stored under `key`, or nil if there's none (or it no longer decodes).
    public func value<T: Decodable>(_ key: String, as type: T.Type) async throws -> T? {
        let rows = try await db.query("SELECT value FROM setting WHERE key = ? AND deleted = 0", [.text(key)])
        guard let text = rows.first?.string("value") else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    public func save<T: Encodable>(_ value: T, for key: String) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw StoreError.invalidValue("can't encode setting \(key)")
        }
        let json = String(decoding: data, as: UTF8.self)
        try await db.write { connection, stamp in
            try connection.execute(
                """
                INSERT INTO setting (key, value, updated_hlc) VALUES (?, ?, ?)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_hlc = excluded.updated_hlc, deleted = 0
                """, [.text(key), .text(json), .text(stamp.hlc.description)])
        }
    }

    public func delete(_ key: String) async throws {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE setting SET deleted = 1, updated_hlc = ? WHERE key = ? AND deleted = 0",
                [.text(stamp.hlc.description), .text(key)])
        }
    }
}
