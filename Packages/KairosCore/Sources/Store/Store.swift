import Foundation
import SQL

/// Kairos's database and its repositories. The schema lives only here; every other module sees
/// typed records.
public struct KairosStore: Sendable {
    public let db: Database

    public init(db: Database) {
        self.db = db
    }

    /// Opens (or creates) the database at `url` and brings it to the newest schema.
    public static func open(at url: URL) async throws -> KairosStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try Database(path: url.path)
        if let missing = try await db.checkCapabilities() { throw SQLError.open(path: url.path, message: missing) }
        try await Migrator.migrate(db, with: try Self.migrations())
        return KairosStore(db: db)
    }

    /// An empty database in memory, at the newest schema: for tests and previews.
    public static func inMemory() async throws -> KairosStore {
        let db = try Database.inMemory()
        try await Migrator.migrate(db, with: try Self.migrations())
        return KairosStore(db: db)
    }

    public static func migrations() throws(SQLError) -> [Migration] {
        guard let folder = Bundle.module.url(forResource: "Schema", withExtension: nil) else {
            throw .migration("the schema is missing from the bundle")
        }
        return try Migrator.migrations(in: folder)
    }

    public var settings: SettingsRepository { SettingsRepository(db: db) }
    public var sources: SourceRepository { SourceRepository(db: db) }
    public var jobs: JobRepository { JobRepository(db: db) }
    public var ledger: ListingLedger { ListingLedger(db: db) }
    public var screening: ScreeningRepository { ScreeningRepository(db: db) }
    public var resume: ResumeRepository { ResumeRepository(db: db) }
    public var builds: BuildRepository { BuildRepository(db: db) }
    public var applications: ApplicationRepository { ApplicationRepository(db: db) }
    public var ai: AIRepository { AIRepository(db: db) }
    public var activity: ActivityRepository { ActivityRepository(db: db) }
}

/// Where a Kairos install keeps its files: the database, the PDFs, the backups and the key file.
public struct DataFolder: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Application Support/Kairos: inside the sandbox container in the app.
    public static func applicationSupport() -> DataFolder {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return DataFolder(root: support.appending(path: "Kairos", directoryHint: .isDirectory))
    }

    /// The database of this Kairos.
    public var database: URL { root.appending(path: "Library/kairos.sqlite") }
    /// The first Kairos's database, imported once and never written.
    public var legacyDatabase: URL { root.appending(path: "local/kairos.sqlite") }
    /// The first Kairos's PDFs.
    public var legacyBuilds: URL { root.appending(path: "local/Builds", directoryHint: .isDirectory) }
    /// API keys, in the format both versions share.
    public var keyFile: URL { root.appending(path: "api-keys.json") }
    public var builds: URL { root.appending(path: "Library/Builds", directoryHint: .isDirectory) }
    public var backups: URL { root.appending(path: "Backups", directoryHint: .isDirectory) }

    /// A stored relative path as a file URL.
    public func file(_ relative: String) -> URL { root.appending(path: relative) }

    /// A file URL inside the folder as the relative path the database keeps.
    public func relative(_ url: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return path }
        return String(path.dropFirst(base.count + 1))
    }
}

extension Row {
    func required(_ column: String, table: String) throws(SQLError) -> String {
        guard let value = string(column) else { throw .badRow(table: table, column: column, detail: "missing") }
        return value
    }

    func uuid(_ column: String, table: String) throws(SQLError) -> UUID {
        guard let value = string(column).flatMap(UUID.init(uuidString:)) else {
            throw .badRow(table: table, column: column, detail: "not a UUID")
        }
        return value
    }

    func value<T: RawRepresentable>(_ column: String, as type: T.Type, table: String) throws(SQLError) -> T
    where T.RawValue == String {
        guard let text = string(column), let value = T(rawValue: text) else {
            throw .badRow(table: table, column: column, detail: "unknown value \(string(column) ?? "NULL")")
        }
        return value
    }

    func optionalValue<T: RawRepresentable>(_ column: String, as type: T.Type) -> T? where T.RawValue == String {
        string(column).flatMap(T.init(rawValue:))
    }

    func requiredDate(_ column: String, table: String) throws(SQLError) -> Date {
        guard let value = date(column) else { throw .badRow(table: table, column: column, detail: "missing") }
        return value
    }
}

extension SQLValue {
    /// JSON text of an encodable value, NULL for nil.
    static func json(_ value: (some Encodable)?) throws -> SQLValue {
        guard let value else { return .null }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .text(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func id(_ uuid: UUID) -> SQLValue { .text(uuid.uuidString.lowercased()) }
    static func id(_ uuid: UUID?) -> SQLValue { uuid.map { .text($0.uuidString.lowercased()) } ?? .null }
}
