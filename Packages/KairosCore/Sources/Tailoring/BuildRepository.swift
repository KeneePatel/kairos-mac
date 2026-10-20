import Foundation
import Store

public enum BuildStatus: String, Codable, Sendable, CaseIterable {
    case queued, running, done, failed
}

/// A build as stored in `build`.
public struct BuildRecord: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let jobID: String
    public let mode: BuildMode
    public let masterVersion: Int
    public let status: BuildStatus
    public let content: TailoredResume?
    public let score: MatchScore?
    public let iterations: Int
    public let error: String?
    public let createdAt: Date
    public let finishedAt: Date?

    public init(
        id: UUID, jobID: String, mode: BuildMode, masterVersion: Int, status: BuildStatus, content: TailoredResume?,
        score: MatchScore?, iterations: Int, error: String?, createdAt: Date, finishedAt: Date?
    ) {
        self.id = id
        self.jobID = jobID
        self.mode = mode
        self.masterVersion = masterVersion
        self.status = status
        self.content = content
        self.score = score
        self.iterations = iterations
        self.error = error
        self.createdAt = createdAt
        self.finishedAt = finishedAt
    }
}

/// A file a build produced, in `artifact`.
public struct ArtifactRecord: Sendable, Equatable {
    public let id: UUID
    public let buildID: UUID
    public let kind: String
    public let sha256: String
    public let localPath: String?
}

/// Reads and writes builds and their files. Each build records the master-resume version and mode
/// it was made with (SPEC §5.10).
public struct BuildRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public func create(job: JobID, mode: BuildMode, masterVersion: Int) async throws -> UUID {
        let id = UUID.v7()
        try await db.write { connection, stamp in
            try connection.execute(
                """
                INSERT INTO build (id, job_id, mode, master_version, status, created_at, updated_hlc)
                VALUES (?, ?, ?, ?, 'queued', ?, ?)
                """,
                [
                    .text(id.lowercased), .text(job.rawValue), .text(mode.rawValue), SQLValue(masterVersion),
                    .integer(stamp.milliseconds), .text(stamp.hlc.description),
                ])
        }
        return id
    }

    public func start(_ id: UUID) async throws {
        try await set(id, "status = 'running', error = NULL")
    }

    public func finish(_ id: UUID, content: TailoredResume, score: MatchScore, iterations: Int) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let content = String(decoding: try encoder.encode(content), as: UTF8.self)
        let breakdown = String(decoding: try encoder.encode(score), as: UTF8.self)
        try await db.write { connection, stamp in
            try connection.execute(
                """
                UPDATE build SET status = 'done', content = ?, match_score = ?, breakdown = ?, iterations = ?,
                    error = NULL, finished_at = ?, updated_hlc = ?
                WHERE id = ?
                """,
                [
                    .text(content), .real(score.total), .text(breakdown), SQLValue(iterations),
                    .integer(stamp.milliseconds), .text(stamp.hlc.description), .text(id.lowercased),
                ])
        }
    }

    public func fail(_ id: UUID, error: String) async throws {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE build SET status = 'failed', error = ?, finished_at = ?, updated_hlc = ? WHERE id = ?",
                [.text(error), .integer(stamp.milliseconds), .text(stamp.hlc.description), .text(id.lowercased)])
        }
    }

    public func build(_ id: UUID) async throws -> BuildRecord? {
        try await db.query("SELECT * FROM build WHERE id = ? AND deleted = 0", [.text(id.lowercased)]).first.map(record)
    }

    /// Newest first.
    public func builds(for job: JobID) async throws -> [BuildRecord] {
        try await db.query(
            "SELECT * FROM build WHERE job_id = ? AND deleted = 0 ORDER BY created_at DESC, rowid DESC",
            [.text(job.rawValue)]
        ).map(record)
    }

    /// Every job's builds, newest first, for the Build screen.
    public func recent(limit: Int = 50) async throws -> [BuildRecord] {
        try await db.query(
            "SELECT * FROM build WHERE deleted = 0 ORDER BY created_at DESC, rowid DESC LIMIT ?", [SQLValue(limit)]
        ).map(record)
    }

    /// Oldest first, for the queue.
    public func builds(status: Set<BuildStatus>) async throws -> [BuildRecord] {
        let placeholders = Array(repeating: "?", count: status.count).joined(separator: ", ")
        return try await db.query(
            "SELECT * FROM build WHERE status IN (\(placeholders)) AND deleted = 0 ORDER BY created_at, rowid",
            status.map { .text($0.rawValue) }
        ).map(record)
    }

    public func addArtifact(build: UUID, kind: String, sha256: String, localPath: String) async throws -> UUID {
        let id = UUID.v7()
        try await db.write { connection, stamp in
            try connection.execute(
                "INSERT INTO artifact (id, build_id, kind, sha256, local_path, updated_hlc) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .text(id.lowercased), .text(build.lowercased), .text(kind), .text(sha256), .text(localPath),
                    .text(stamp.hlc.description),
                ])
        }
        return id
    }

    public func artifacts(for build: UUID) async throws -> [ArtifactRecord] {
        try await db.query(
            "SELECT * FROM artifact WHERE build_id = ? AND deleted = 0 ORDER BY rowid", [.text(build.lowercased)]
        ).map { row in
            let reader = RowReader(row: row, table: "artifact")
            return ArtifactRecord(
                id: try reader.uuid("id"), buildID: try reader.uuid("build_id"), kind: try reader.string("kind"),
                sha256: try reader.string("sha256"), localPath: row.string("local_path"))
        }
    }

    private func set(_ id: UUID, _ assignments: String) async throws {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE build SET \(assignments), updated_hlc = ? WHERE id = ?",
                [.text(stamp.hlc.description), .text(id.lowercased)])
        }
    }

    private func record(_ row: Row) throws -> BuildRecord {
        let reader = RowReader(row: row, table: "build")
        return BuildRecord(
            id: try reader.uuid("id"), jobID: try reader.string("job_id"),
            mode: try reader.value("mode", as: BuildMode.self), masterVersion: try reader.int("master_version"),
            status: try reader.value("status", as: BuildStatus.self),
            content: try reader.json("content", as: TailoredResume.self),
            score: try reader.json("breakdown", as: MatchScore.self), iterations: try reader.int("iterations"),
            error: row.string("error"), createdAt: try reader.date("created_at"),
            finishedAt: reader.optionalDate("finished_at"))
    }
}
