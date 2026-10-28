import Foundation
import KairosKit
import SQL

/// Jobs you applied to, and what happened since.
public struct ApplicationRepository: Sendable {
    let db: Database

    static let table = "application"

    /// Every application, the latest first.
    public func all() async throws -> [Application] {
        try await db.query("SELECT * FROM application ORDER BY applied_at DESC, id DESC").map(Self.application)
    }

    public func application(_ id: UUID) async throws -> Application? {
        try await db.first("SELECT * FROM application WHERE id = ?", [.id(id)]).map(Self.application)
    }

    public func application(forJob jobID: String) async throws -> Application? {
        try await db.first("SELECT * FROM application WHERE job_id = ?", [.text(jobID)]).map(Self.application)
    }

    /// Records that you applied. One application per job: applying again returns the one there is.
    @discardableResult
    public func apply(_ application: Application) async throws -> Application {
        let values = Self.values(application)
        let event = ApplicationEvent(
            applicationID: application.id, kind: application.status.rawValue, at: application.appliedAt)
        return try await db.transaction { connection in
            if let existing = try connection.first(
                "SELECT * FROM application WHERE job_id = ?", [.text(application.jobID)])
            {
                return try Self.application(existing)
            }
            try connection.execute(Self.insertSQL, values)
            try Self.insert(event, in: connection)
            return application
        }
    }

    /// Writes back what you changed; a new status adds a line to its timeline.
    public func save(_ application: Application, note: String? = nil, at now: Date = Date()) async throws {
        var updated = application
        updated.updatedAt = now
        try await db.transaction { [updated] connection in
            guard
                let row = try connection.first(
                    "SELECT status, status_at FROM application WHERE id = ?", [.id(updated.id)])
            else { return }
            var saved = updated
            saved.statusAt = row.date("status_at") ?? updated.statusAt
            if row.string("status") != updated.status.rawValue {
                saved.statusAt = now
                try Self.insert(
                    ApplicationEvent(applicationID: updated.id, kind: updated.status.rawValue, at: now, note: note),
                    in: connection)
            } else if let note, !note.isEmpty {
                try Self.insert(
                    ApplicationEvent(applicationID: updated.id, kind: "note", at: now, note: note), in: connection)
            }
            try connection.execute(
                """
                UPDATE application SET build_id = ?, applied_at = ?, channel = ?, status = ?, status_at = ?,
                    follow_up_at = ?, next_step = ?, notes = ?, updated_at = ?
                WHERE id = ?
                """,
                [
                    .id(saved.buildID), SQLValue(saved.appliedAt), SQLValue(saved.channel),
                    .text(saved.status.rawValue),
                    SQLValue(saved.statusAt), SQLValue(saved.followUpAt), SQLValue(saved.nextStep), .text(saved.notes),
                    SQLValue(saved.updatedAt), .id(saved.id),
                ])
        }
    }

    public func events(of id: UUID) async throws -> [ApplicationEvent] {
        try await db.query("SELECT * FROM application_event WHERE application_id = ? ORDER BY at, id", [.id(id)])
            .compactMap { row in
                guard let eventID = row.string("id").flatMap(UUID.init(uuidString:)), let kind = row.string("kind"),
                    let at = row.date("at")
                else { return nil }
                return ApplicationEvent(id: eventID, applicationID: id, kind: kind, at: at, note: row.string("note"))
            }
    }

    /// Forgets an application ("I didn't apply"), with its timeline.
    public func delete(_ id: UUID) async throws {
        try await db.execute("DELETE FROM application WHERE id = ?", [.id(id)])
    }

    // MARK: - Rows

    static let insertSQL = """
        INSERT INTO application (id, job_id, build_id, applied_at, channel, status, status_at, follow_up_at, next_step,
            notes, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    static func values(_ application: Application) -> [SQLValue] {
        [
            .id(application.id), .text(application.jobID), .id(application.buildID), SQLValue(application.appliedAt),
            SQLValue(application.channel), .text(application.status.rawValue), SQLValue(application.statusAt),
            SQLValue(application.followUpAt), SQLValue(application.nextStep), .text(application.notes),
            SQLValue(application.updatedAt),
        ]
    }

    static func insert(_ event: ApplicationEvent, in connection: Connection) throws {
        try connection.execute(
            "INSERT INTO application_event (id, application_id, kind, at, note) VALUES (?, ?, ?, ?, ?)",
            [.id(event.id), .id(event.applicationID), .text(event.kind), SQLValue(event.at), SQLValue(event.note)])
    }

    static func application(_ row: Row) throws(SQLError) -> Application {
        let appliedAt = try row.requiredDate("applied_at", table: table)
        return Application(
            id: try row.uuid("id", table: table), jobID: try row.required("job_id", table: table),
            buildID: row.string("build_id").flatMap(UUID.init(uuidString:)), appliedAt: appliedAt,
            channel: row.string("channel"), status: try row.value("status", as: Application.Status.self, table: table),
            statusAt: row.date("status_at") ?? appliedAt, followUpAt: row.date("follow_up_at"),
            nextStep: row.string("next_step"), notes: row.string("notes") ?? "", updatedAt: row.date("updated_at"))
    }
}
