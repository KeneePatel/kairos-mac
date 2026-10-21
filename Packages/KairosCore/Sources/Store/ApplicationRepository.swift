import Foundation

/// Where an application stands (SPEC story 6). The last four close it.
public enum ApplicationStatus: String, Sendable, CaseIterable, Codable {
    case applied, screen, interview, offer
    case accepted, rejected, ghosted, withdrawn

    /// The board's columns: Applied, Screen, Interview, Offer, then Closed for the rest.
    public var isClosed: Bool { [.accepted, .rejected, .ghosted, .withdrawn].contains(self) }
}

/// A job you applied to, in `application`.
public struct Application: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let jobID: JobID
    public var buildID: UUID?
    public var appliedAt: Date
    public var channel: String?
    public var status: ApplicationStatus
    /// When it reached `status`.
    public var statusAt: Date
    /// The follow-up reminder, if you set one.
    public var nextActionAt: Date?
    public var nextAction: String?
    public var notes: String

    public init(
        id: UUID, jobID: JobID, buildID: UUID? = nil, appliedAt: Date, channel: String? = nil,
        status: ApplicationStatus = .applied, statusAt: Date, nextActionAt: Date? = nil, nextAction: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.jobID = jobID
        self.buildID = buildID
        self.appliedAt = appliedAt
        self.channel = channel
        self.status = status
        self.statusAt = statusAt
        self.nextActionAt = nextActionAt
        self.nextAction = nextAction
        self.notes = notes
    }
}

/// One line of an application's timeline, in `application_event`: a status it reached, or a note.
public struct ApplicationEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case status(ApplicationStatus)
        case note
    }

    public let id: UUID
    public let applicationID: UUID
    public let kind: Kind
    public let at: Date
    public let note: String?

    public init(id: UUID, applicationID: UUID, kind: Kind, at: Date, note: String? = nil) {
        self.id = id
        self.applicationID = applicationID
        self.kind = kind
        self.at = at
        self.note = note
    }
}

/// Applications and their timelines. Every status change appends an event, and events are never
/// edited (SPEC §6.4, 6), so the timeline is the history as it happened.
public struct ApplicationRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// Records that you applied to `job`, with its first timeline line, and marks the job applied.
    /// Applying again to the same job returns the application already there.
    @discardableResult
    public func apply(job: JobID, build: UUID? = nil, channel: String? = nil, at date: Date) async throws
        -> Application
    {
        if let existing = try await application(for: job) { return existing }
        let application = Application(
            id: UUID.v7(), jobID: job, buildID: build, appliedAt: date, channel: channel, statusAt: date)
        try await db.write { connection, stamp in
            try connection.execute(
                """
                INSERT INTO application (id, job_id, build_id, applied_at, channel, status, status_at, updated_hlc)
                VALUES (?, ?, ?, ?, ?, 'applied', ?, ?)
                """,
                [
                    .text(application.id.lowercased), .text(job.rawValue), SQLValue(build?.lowercased),
                    SQLValue(date), SQLValue(channel), SQLValue(date), .text(stamp.hlc.description),
                ])
            try Self.append(.status(.applied), to: application.id, at: date, note: nil, in: connection, stamp: stamp)
            try connection.execute(
                "UPDATE job SET state = 'applied', updated_hlc = ? WHERE id = ?",
                [.text(stamp.hlc.description), .text(job.rawValue)])
        }
        return application
    }

    /// Every application, the one that moved most recently first.
    public func applications() async throws -> [Application] {
        try await db.query("SELECT * FROM application WHERE deleted = 0 ORDER BY status_at DESC, rowid DESC")
            .map(Self.application)
    }

    public func application(for job: JobID) async throws -> Application? {
        try await db.query("SELECT * FROM application WHERE job_id = ? AND deleted = 0", [.text(job.rawValue)])
            .first.map(Self.application)
    }

    public func application(_ id: UUID) async throws -> Application? {
        try await db.query("SELECT * FROM application WHERE id = ? AND deleted = 0", [.text(id.lowercased)])
            .first.map(Self.application)
    }

    /// Moves the application on (or back), appending a timeline line with your note.
    public func setStatus(_ status: ApplicationStatus, for id: UUID, at date: Date, note: String? = nil)
        async throws
    {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE application SET status = ?, status_at = ?, updated_hlc = ? WHERE id = ?",
                [.text(status.rawValue), SQLValue(date), .text(stamp.hlc.description), .text(id.lowercased)])
            try Self.append(.status(status), to: id, at: date, note: Self.trimmed(note), in: connection, stamp: stamp)
        }
    }

    /// Adds a line to the timeline without changing the status: "30 min call with the recruiter".
    public func addNote(_ note: String, to id: UUID, at date: Date) async throws {
        guard let note = Self.trimmed(note) else { return }
        try await db.write { connection, stamp in
            try Self.append(.note, to: id, at: date, note: note, in: connection, stamp: stamp)
        }
    }

    /// Sets the follow-up reminder, or clears it with nil.
    public func setFollowUp(_ date: Date?, _ text: String?, for id: UUID) async throws {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE application SET next_action_at = ?, next_action = ?, updated_hlc = ? WHERE id = ?",
                [
                    SQLValue(date), SQLValue(date == nil ? nil : Self.trimmed(text)), .text(stamp.hlc.description),
                    .text(id.lowercased),
                ])
        }
    }

    public func setNotes(_ notes: String, for id: UUID) async throws {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE application SET notes = ?, updated_hlc = ? WHERE id = ?",
                [.text(notes), .text(stamp.hlc.description), .text(id.lowercased)])
        }
    }

    /// The timeline, oldest first.
    public func events(for id: UUID) async throws -> [ApplicationEvent] {
        try await db.query(
            "SELECT * FROM application_event WHERE application_id = ? AND deleted = 0 ORDER BY at, rowid",
            [.text(id.lowercased)]
        ).map { row in
            let reader = RowReader(row: row, table: "application_event")
            let kind = try reader.string("kind")
            return ApplicationEvent(
                id: try reader.uuid("id"), applicationID: try reader.uuid("application_id"),
                kind: kind == "note" ? .note : .status(try reader.value("kind", as: ApplicationStatus.self)),
                at: try reader.date("at"), note: row.string("note"))
        }
    }

    /// Forgets an application (a tombstone, so the deletion syncs); the job goes back to new.
    public func delete(_ id: UUID) async throws {
        guard let application = try await application(id) else { return }
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE application SET deleted = 1, updated_hlc = ? WHERE id = ?",
                [.text(stamp.hlc.description), .text(id.lowercased)])
            try connection.execute(
                "UPDATE application_event SET deleted = 1, updated_hlc = ? WHERE application_id = ?",
                [.text(stamp.hlc.description), .text(id.lowercased)])
            try connection.execute(
                "UPDATE job SET state = 'new', updated_hlc = ? WHERE id = ? AND state = 'applied'",
                [.text(stamp.hlc.description), .text(application.jobID.rawValue)])
        }
    }

    private static func append(
        _ kind: ApplicationEvent.Kind, to id: UUID, at date: Date, note: String?, in connection: Connection,
        stamp: WriteStamp
    ) throws {
        let name: String
        switch kind {
        case .status(let status): name = status.rawValue
        case .note: name = "note"
        }
        try connection.execute(
            "INSERT INTO application_event (id, application_id, kind, at, note, updated_hlc) VALUES (?, ?, ?, ?, ?, ?)",
            [
                .text(UUID.v7().lowercased), .text(id.lowercased), .text(name), SQLValue(date), SQLValue(note),
                .text(stamp.hlc.description),
            ])
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func application(_ row: Row) throws -> Application {
        let reader = RowReader(row: row, table: "application")
        return Application(
            id: try reader.uuid("id"), jobID: JobID(rawValue: try reader.string("job_id")),
            buildID: row.string("build_id").flatMap(UUID.init(uuidString:)), appliedAt: try reader.date("applied_at"),
            channel: row.string("channel"), status: try reader.value("status", as: ApplicationStatus.self),
            statusAt: try reader.date("status_at"), nextActionAt: reader.optionalDate("next_action_at"),
            nextAction: row.string("next_action"), notes: row.string("notes") ?? "")
    }
}
