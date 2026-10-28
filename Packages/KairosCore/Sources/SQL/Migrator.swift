import Foundation

/// One numbered schema change: `NNN_name.sql`.
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

/// Brings a database up to the newest schema. Migrations are append-only: each runs once, in
/// order, inside its own transaction, and `PRAGMA user_version` records the last one applied.
public enum Migrator {
    /// The `NNN_name.sql` files in `folder`, in order.
    public static func migrations(in folder: URL) throws(SQLError) -> [Migration] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var migrations: [Migration] = []
        for file in files where file.pathExtension == "sql" {
            guard let (version, name) = parse(fileName: file.lastPathComponent) else {
                throw .migration("a migration file isn't named NNN_name.sql: \(file.lastPathComponent)")
            }
            guard let sql = try? String(contentsOf: file, encoding: .utf8) else {
                throw .migration("can't read \(file.lastPathComponent)")
            }
            migrations.append(Migration(version: version, name: name, sql: sql))
        }
        return migrations.sorted { $0.version < $1.version }
    }

    /// "003_jobs.sql" → (3, "jobs").
    static func parse(fileName: String) -> (Int, String)? {
        guard fileName.hasSuffix(".sql") else { return nil }
        let parts = fileName.dropLast(4).split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 3, let version = Int(parts[0]), version > 0 else { return nil }
        return (version, String(parts[1]))
    }

    /// Applies every migration newer than the database's version and returns the new version.
    @discardableResult
    public static func migrate(_ db: Database, with migrations: [Migration]) async throws(SQLError) -> Int {
        let sorted = migrations.sorted { $0.version < $1.version }
        for (index, migration) in sorted.enumerated() where migration.version != index + 1 {
            throw .migration("expected migration \(index + 1), found \(migration.version) (\(migration.name))")
        }
        let known = sorted.last?.version ?? 0
        let current = try await db.userVersion()
        guard current <= known else { throw .newerSchema(found: current, known: known) }

        for migration in sorted where migration.version > current {
            do {
                try await db.transaction { connection in
                    try connection.executeScript(migration.sql)
                    // An Int from our own list, never input, so interpolating it is safe.
                    try connection.executeScript("PRAGMA user_version = \(migration.version)")
                }
            } catch let error as SQLError {
                throw .migration("\(migration.version)_\(migration.name): \(error)")
            } catch {
                throw .migration("\(migration.version)_\(migration.name): \(error)")
            }
        }
        return max(current, known)
    }
}
