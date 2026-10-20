import Foundation

/// Reads and writes `private_setting` rows: settings that stay on this Mac, such as work
/// authorization (SPEC §5.9). Unlike `SettingsRepository`, nothing is stamped and a delete is final.
public struct PrivateSettingsRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// The document stored under `key`, or nil if there's none (or it no longer decodes).
    public func value<T: Decodable>(_ key: String, as type: T.Type) async throws -> T? {
        let rows = try await db.query("SELECT value FROM private_setting WHERE key = ?", [.text(key)])
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
            throw StoreError.invalidValue("can't encode private setting \(key)")
        }
        let json = String(decoding: data, as: UTF8.self)
        try await db.write { connection, _ in
            try connection.execute(
                "INSERT INTO private_setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(json)])
        }
    }

    public func delete(_ key: String) async throws {
        try await db.write { connection, _ in
            try connection.execute("DELETE FROM private_setting WHERE key = ?", [.text(key)])
        }
    }
}
