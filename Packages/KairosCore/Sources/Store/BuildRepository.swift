import Foundation
import KairosKit
import SQL
import Tailoring

/// Tailored resumes and letters, and the PDFs they made.
public struct BuildRepository: Sendable {
    let db: Database

    static let table = "build"

    public func build(_ id: UUID) async throws -> BuildRecord? {
        try await db.read { connection in
            try connection.first("SELECT * FROM build WHERE id = ?", [.id(id)]).map {
                try Self.build($0, in: connection)
            }
        }
    }

    /// Every build, newest first.
    public func all() async throws -> [BuildRecord] {
        try await builds(where: "1 = 1", [])
    }

    /// A job's builds, newest first.
    public func builds(for jobID: String) async throws -> [BuildRecord] {
        try await builds(where: "job_id = ?", [.text(jobID)])
    }

    /// The oldest build waiting to run.
    public func nextQueued() async throws -> BuildRecord? {
        try await db.read { connection in
            try connection.first("SELECT * FROM build WHERE status = 'queued' ORDER BY created_at, id LIMIT 1").map {
                try Self.build($0, in: connection)
            }
        }
    }

    /// Adds a build or writes it back whole, with its files.
    public func save(_ build: BuildRecord) async throws {
        let values: [SQLValue] = [
            .id(build.id), .text(build.jobID), .text(build.mode.rawValue), SQLValue(build.resumeVersion),
            .text(build.status.rawValue), SQLValue(build.wantsLetter), try .json(build.resume), try .json(build.letter),
            SQLValue(build.letterError), try .json(build.report), SQLValue(build.score), SQLValue(build.error),
            SQLValue(build.createdAt), SQLValue(build.startedAt), SQLValue(build.finishedAt),
        ]
        let files = build.files
        try await db.transaction { connection in
            try connection.execute(
                """
                INSERT INTO build (id, job_id, mode, resume_version, status, wants_letter, content, letter, letter_error,
                    report, score, error, created_at, started_at, finished_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET mode = excluded.mode, resume_version = excluded.resume_version,
                    status = excluded.status, wants_letter = excluded.wants_letter, content = excluded.content,
                    letter = excluded.letter, letter_error = excluded.letter_error, report = excluded.report,
                    score = excluded.score, error = excluded.error, started_at = excluded.started_at,
                    finished_at = excluded.finished_at
                """, values)
            try connection.execute("DELETE FROM build_file WHERE build_id = ?", [.id(build.id)])
            for file in files {
                try connection.execute(
                    "INSERT INTO build_file (build_id, kind, path, sha256) VALUES (?, ?, ?, ?)",
                    [.id(build.id), .text(file.kind.rawValue), .text(file.path), .text(file.sha256)])
            }
        }
    }

    /// Queued to running, unless it was stopped meanwhile. Returns whether it starts.
    public func start(_ id: UUID, at now: Date) async throws -> Bool {
        try await db.transaction { connection in
            try connection.execute(
                "UPDATE build SET status = 'running', started_at = ? WHERE id = ? AND status = 'queued'",
                [SQLValue(now), .id(id)])
            return connection.changes > 0
        }
    }

    /// Stops a queued or running build. Returns whether it was stopped.
    @discardableResult
    public func stop(_ id: UUID, at now: Date) async throws -> Bool {
        try await db.transaction { connection in
            try connection.execute(
                "UPDATE build SET status = 'stopped', finished_at = ? WHERE id = ? AND status IN ('queued', 'running')",
                [SQLValue(now), .id(id)])
            return connection.changes > 0
        }
    }

    /// Builds that were running when Kairos quit go back in the queue. Returns how many.
    @discardableResult
    public func requeueInterrupted() async throws -> Int {
        try await db.transaction { connection in
            try connection.execute("UPDATE build SET status = 'queued', started_at = NULL WHERE status = 'running'")
            return connection.changes
        }
    }

    /// Deletes a build. Returns its files, for the caller to remove from disk; an application that
    /// cited it keeps its record without the link.
    @discardableResult
    public func delete(_ id: UUID) async throws -> [BuildRecord.File] {
        try await db.transaction { connection in
            let files = try Self.files(of: id.lowercased, in: connection)
            try connection.execute("UPDATE application SET build_id = NULL WHERE build_id = ?", [.id(id)])
            try connection.execute("DELETE FROM build WHERE id = ?", [.id(id)])
            return files
        }
    }

    /// Every file path the builds name, for finding PDFs nothing points to.
    public func filePaths() async throws -> Set<String> {
        Set(try await db.query("SELECT path FROM build_file").compactMap { $0.string("path") })
    }

    // MARK: - Rows

    private func builds(where condition: String, _ values: [SQLValue]) async throws -> [BuildRecord] {
        try await db.read { connection in
            try connection.query("SELECT * FROM build WHERE \(condition) ORDER BY created_at DESC, id DESC", values).map
            {
                try Self.build($0, in: connection)
            }
        }
    }

    static func build(_ row: Row, in connection: Connection) throws -> BuildRecord {
        let id = try row.required("id", table: table)
        return BuildRecord(
            id: try row.uuid("id", table: table), jobID: try row.required("job_id", table: table),
            mode: try row.value("mode", as: BuildMode.self, table: table),
            resumeVersion: row.int("resume_version") ?? 0,
            status: try row.value("status", as: BuildRecord.Status.self, table: table),
            wantsLetter: row.bool("wants_letter") ?? false,
            resume: try row.json("content", as: TailoredResume.self, table: table),
            letter: try row.json("letter", as: CoverLetter.self, table: table), letterError: row.string("letter_error"),
            report: try row.json("report", as: BuildNotes.self, table: table), score: row.double("score"),
            error: row.string("error"), createdAt: try row.requiredDate("created_at", table: table),
            startedAt: row.date("started_at"), finishedAt: row.date("finished_at"),
            files: try files(of: id, in: connection))
    }

    static func files(of id: String, in connection: Connection) throws -> [BuildRecord.File] {
        try connection.query("SELECT * FROM build_file WHERE build_id = ? ORDER BY kind", [.text(id)]).compactMap {
            row in
            guard let kind = row.optionalValue("kind", as: BuildRecord.File.Kind.self), let path = row.string("path")
            else { return nil }
            return BuildRecord.File(kind: kind, path: path, sha256: row.string("sha256") ?? "")
        }
    }
}
