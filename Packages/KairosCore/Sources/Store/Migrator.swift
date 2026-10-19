import Foundation

/// One numbered schema change: `Schema/NNN_name.sql`.
public struct Migration: Sendable, Equatable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }
}

/// Brings a database up to the newest schema. Migrations are append-only (SPEC §12): each runs once,
/// in order, inside its own transaction, and `PRAGMA user_version` records the last one applied.
public enum Migrator {
    /// The migrations shipped in this module's `Schema/` folder.
    public static func bundled() throws(StoreError) -> [Migration] {
        guard let folder = Bundle.module.url(forResource: "Schema", withExtension: nil) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var migrations: [Migration] = []
        for file in files where file.pathExtension == "sql" {
            guard let (version, name) = parse(fileName: file.lastPathComponent) else {
                throw .migrationOrder("migration file not named NNN_name.sql: \(file.lastPathComponent)")
            }
            guard let sql = try? String(contentsOf: file, encoding: .utf8) else {
                throw .migrationOrder("can't read \(file.lastPathComponent)")
            }
            migrations.append(Migration(version: version, name: name, sql: sql))
        }
        return migrations.sorted { $0.version < $1.version }
    }

    /// `003_jobs.sql` → (3, "jobs").
    static func parse(fileName: String) -> (Int, String)? {
        guard fileName.hasSuffix(".sql") else { return nil }
        let stem = fileName.dropLast(4)
        let parts = stem.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 3, let version = Int(parts[0]), version > 0 else { return nil }
        return (version, String(parts[1]))
    }

    /// Applies every migration newer than the database's version and returns the new version.
    @discardableResult
    public static func migrate(_ db: Database, with migrations: [Migration]) async throws(StoreError) -> Int {
        let sorted = migrations.sorted { $0.version < $1.version }
        for (index, migration) in sorted.enumerated() where migration.version != index + 1 {
            throw .migrationOrder("expected migration \(index + 1), found \(migration.version) (\(migration.name))")
        }
        let known = sorted.last?.version ?? 0
        let current = try await db.userVersion()
        guard current <= known else { throw .newerSchema(found: current, known: known) }

        for migration in sorted where migration.version > current {
            do {
                try await db.transaction { connection in
                    try connection.executeScript(migration.sql)
                    // An Int from our own list, never user input, so interpolating it is safe here.
                    try connection.executeScript("PRAGMA user_version = \(migration.version)")
                }
            } catch let error as StoreError {
                throw error
            } catch {
                throw .migrationOrder("migration \(migration.version) failed: \(error)")
            }
        }
        return max(current, known)
    }
}
