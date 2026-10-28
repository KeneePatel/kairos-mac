import AI
import Foundation
import SQL
import Screening
import Tailoring

/// Settings: JSON documents by key.
public struct SettingsRepository: Sendable {
    let db: Database

    public func value<T: Decodable>(_ key: String, as type: T.Type) async throws -> T? {
        guard let text = try await db.first("SELECT value FROM setting WHERE key = ?", [.text(key)])?.string("value")
        else {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    public func set<T: Encodable>(_ key: String, to value: T, at now: Date = Date()) async throws {
        try await db.execute(
            """
            INSERT INTO setting (key, value, updated_at) VALUES (?, ?, ?)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, [.text(key), try .json(value), SQLValue(now)])
    }

    public func remove(_ key: String) async throws {
        try await db.execute("DELETE FROM setting WHERE key = ?", [.text(key)])
    }

    /// Every setting as stored, for the importer and exports.
    public func all() async throws -> [String: String] {
        var result: [String: String] = [:]
        for row in try await db.query("SELECT key, value FROM setting") {
            if let key = row.string("key"), let value = row.string("value") { result[key] = value }
        }
        return result
    }

    // The settings every part of Kairos reads, each with its default.

    public func preferences() async throws -> SearchPreferences {
        try await value(SearchPreferences.storageKey, as: SearchPreferences.self) ?? SearchPreferences()
    }

    public func workProfile() async throws -> WorkProfile {
        try await value(WorkProfile.storageKey, as: WorkProfile.self) ?? WorkProfile()
    }

    /// Your AI setup, with routes for tasks added since it was saved.
    public func aiSettings() async throws -> AISettings {
        var settings = try await value(AISettings.storageKey, as: AISettings.self) ?? AISettings.defaults()
        settings.addMissingRoutes()
        return settings
    }

    public func stretch() async throws -> StretchSettings {
        try await value(StretchSettings.storageKey, as: StretchSettings.self) ?? StretchSettings()
    }

    public func pages() async throws -> PageSettings {
        try await value(PageSettings.storageKey, as: PageSettings.self) ?? PageSettings()
    }
}
