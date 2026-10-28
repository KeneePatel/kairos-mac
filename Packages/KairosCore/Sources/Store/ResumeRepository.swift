import Foundation
import KairosKit
import Resume
import SQL

/// A whole master resume as it was before something replaced it.
public struct ResumeSnapshot: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let at: Date
    public let version: Int
    /// "Before importing resume.pdf".
    public let reason: String
}

/// The master resume. Every change is one transaction that bumps its version, which builds record.
/// Entry and bullet ids never change: tailored bullets cite them.
public struct ResumeRepository: Sendable {
    let db: Database

    /// Snapshots kept; older ones go.
    public static let snapshotsKept = 20

    public func load() async throws -> MasterResume {
        try await db.read { connection in try Self.load(in: connection) }
    }

    public func version() async throws -> Int {
        try await db.first("SELECT version FROM resume_header WHERE id = 1")?.int("version") ?? 0
    }

    /// Replaces the whole master resume (an import, or a snapshot put back), keeping a snapshot of
    /// what it replaces. Returns the new version.
    @discardableResult
    public func replace(with resume: MasterResume, reason: String, at now: Date = Date()) async throws -> Int {
        try await change(at: now) { connection in
            try Self.snapshot(reason: reason, at: now, in: connection)
            try connection.execute("DELETE FROM resume_entry")
            try connection.execute("DELETE FROM resume_skill")
            try Self.write(resume.header, in: connection)
            for (index, entry) in resume.entries.enumerated() { try Self.write(entry, sort: index, in: connection) }
            for (index, skill) in resume.skills.enumerated() { try Self.write(skill, sort: index, in: connection) }
        }
    }

    @discardableResult
    public func saveHeader(_ header: ResumeHeader, at now: Date = Date()) async throws -> Int {
        try await change(at: now) { connection in try Self.write(header, in: connection) }
    }

    /// Adds or updates an entry and its bullets, in their order. A new entry goes last.
    @discardableResult
    public func saveEntry(_ entry: ResumeEntry, at now: Date = Date()) async throws -> Int {
        try await change(at: now) { connection in
            let sort =
                try connection.first("SELECT sort FROM resume_entry WHERE id = ?", [.id(entry.id)])?.int("sort")
                ?? (try connection.first("SELECT coalesce(max(sort), -1) + 1 AS next FROM resume_entry")?.int("next")
                    ?? 0)
            try Self.write(entry, sort: sort, in: connection)
        }
    }

    @discardableResult
    public func deleteEntry(_ id: UUID, at now: Date = Date()) async throws -> Int {
        try await change(at: now) { connection in
            try connection.execute("DELETE FROM resume_entry WHERE id = ?", [.id(id)])
        }
    }

    /// Puts entries in the order given (within a kind, say); entries not named keep their place.
    @discardableResult
    public func order(_ ids: [UUID], at now: Date = Date()) async throws -> Int {
        try await change(at: now) { connection in
            let sorts = try ids.compactMap { id in
                try connection.first("SELECT sort FROM resume_entry WHERE id = ?", [.id(id)])?.int("sort")
            }.sorted()
            for (id, sort) in zip(ids, sorts) {
                try connection.execute("UPDATE resume_entry SET sort = ? WHERE id = ?", [SQLValue(sort), .id(id)])
            }
        }
    }

    /// Replaces every skill, in this order.
    @discardableResult
    public func saveSkills(_ skills: [Skill], at now: Date = Date()) async throws -> Int {
        try await change(at: now) { connection in
            try connection.execute("DELETE FROM resume_skill")
            for (index, skill) in skills.enumerated() { try Self.write(skill, sort: index, in: connection) }
        }
    }

    public func snapshots() async throws -> [ResumeSnapshot] {
        try await db.query("SELECT id, at, version, reason FROM resume_snapshot ORDER BY at DESC, id DESC").compactMap {
            guard let id = $0.int64("id"), let at = $0.date("at") else { return nil }
            return ResumeSnapshot(id: id, at: at, version: $0.int("version") ?? 0, reason: $0.string("reason") ?? "")
        }
    }

    /// Puts a snapshot back, keeping a snapshot of what it replaces. Returns the new version.
    @discardableResult
    public func restore(_ snapshot: Int64, at now: Date = Date()) async throws -> Int {
        guard
            let data = try await db.first("SELECT data FROM resume_snapshot WHERE id = ?", [.integer(snapshot)])?
                .string("data")
        else { throw SQLError.badRow(table: "resume_snapshot", column: "id", detail: "no snapshot \(snapshot)") }
        let resume = try MasterResume.fromJSON(data)
        let label = try await snapshots().first { $0.id == snapshot }.map { "version \($0.version)" } ?? "a snapshot"
        return try await replace(with: resume, reason: "Before restoring \(label)", at: now)
    }

    // MARK: - Inside a transaction

    /// Runs `body` and bumps the version, in one transaction. Returns the new version.
    private func change(at now: Date, _ body: @Sendable (Connection) throws -> Void) async throws -> Int {
        try await db.transaction { connection in
            try connection.execute(
                "INSERT INTO resume_header (id, updated_at) VALUES (1, ?) ON CONFLICT (id) DO NOTHING", [SQLValue(now)])
            try body(connection)
            try connection.execute(
                "UPDATE resume_header SET version = version + 1, updated_at = ? WHERE id = 1", [SQLValue(now)])
            return try connection.first("SELECT version FROM resume_header WHERE id = 1")?.int("version") ?? 0
        }
    }

    static func load(in connection: Connection) throws -> MasterResume {
        var resume = MasterResume()
        if let row = try connection.first("SELECT * FROM resume_header WHERE id = 1") {
            var header = ResumeHeader()
            header.fullName = row.string("full_name") ?? ""
            header.email = row.string("email") ?? ""
            header.phone = row.string("phone") ?? ""
            header.linkedInURL = row.string("linkedin_url") ?? ""
            header.gitHubURL = row.string("github_url")
            header.portfolioURL = row.string("portfolio_url")
            header.city = row.string("city")
            header.region = row.string("region")
            header.country = row.string("country")
            header.headline = row.string("headline") ?? ""
            header.highlights = row.string("highlights") ?? ""
            header.totalYears = row.double("total_years")
            resume.header = header
            resume.version = row.int("version") ?? 0
        }
        var bullets: [String: [ResumeBullet]] = [:]
        for row in try connection.query("SELECT * FROM resume_bullet ORDER BY sort, id") {
            guard let entry = row.string("entry_id") else { continue }
            bullets[entry, default: []].append(
                ResumeBullet(
                    id: try row.uuid("id", table: "resume_bullet"), text: row.string("text") ?? "",
                    metrics: try row.json("metrics", as: [String].self, table: "resume_bullet") ?? [],
                    skills: try row.json("skills", as: [String].self, table: "resume_bullet") ?? []))
        }
        resume.entries = try connection.query("SELECT * FROM resume_entry ORDER BY sort, id").map { row in
            let table = "resume_entry"
            let id = try row.required("id", table: table)
            let kind = try row.value("kind", as: EntryKind.self, table: table)
            let fields: EntryFields
            do {
                fields = try EntryFields.decode(kind: kind, json: try row.required("fields", table: table))
            } catch {
                throw SQLError.badRow(table: table, column: "fields", detail: String(describing: error))
            }
            return ResumeEntry(
                id: try row.uuid("id", table: table), fields: fields,
                start: row.string("start_month").flatMap(YearMonth.init),
                end: row.string("end_month").flatMap(YearMonth.init), isCurrent: row.bool("is_current") ?? false,
                bullets: bullets[id] ?? [])
        }
        resume.skills = try connection.query("SELECT * FROM resume_skill ORDER BY sort, id").map { row in
            Skill(
                id: try row.uuid("id", table: "resume_skill"), name: row.string("name") ?? "",
                category: row.string("category") ?? "",
                level: row.optionalValue("level", as: SkillLevel.self) ?? .proven)
        }
        return resume
    }

    static func write(_ header: ResumeHeader, in connection: Connection) throws {
        try connection.execute(
            """
            UPDATE resume_header SET full_name = ?, email = ?, phone = ?, linkedin_url = ?, github_url = ?,
                portfolio_url = ?, city = ?, region = ?, country = ?, headline = ?, highlights = ?, total_years = ?
            WHERE id = 1
            """,
            [
                .text(header.fullName), .text(header.email), .text(header.phone), .text(header.linkedInURL),
                SQLValue(header.gitHubURL), SQLValue(header.portfolioURL), SQLValue(header.city),
                SQLValue(header.region),
                SQLValue(header.country), .text(header.headline), .text(header.highlights), SQLValue(header.totalYears),
            ])
    }

    static func write(_ entry: ResumeEntry, sort: Int, in connection: Connection) throws {
        try connection.execute(
            """
            INSERT INTO resume_entry (id, kind, fields, start_month, end_month, is_current, sort) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, fields = excluded.fields,
                start_month = excluded.start_month, end_month = excluded.end_month, is_current = excluded.is_current,
                sort = excluded.sort
            """,
            [
                .id(entry.id), .text(entry.kind.rawValue), .text(try entry.fields.json()),
                SQLValue(entry.start?.description), SQLValue(entry.isCurrent ? nil : entry.end?.description),
                SQLValue(entry.isCurrent), SQLValue(sort),
            ])
        try connection.execute(
            "DELETE FROM resume_bullet WHERE entry_id = ? AND id NOT IN (SELECT value FROM json_each(?))",
            [.id(entry.id), try .json(entry.bullets.map(\.id.lowercased))])
        for (index, bullet) in entry.bullets.enumerated() {
            try connection.execute(
                """
                INSERT INTO resume_bullet (id, entry_id, text, metrics, skills, sort) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET entry_id = excluded.entry_id, text = excluded.text,
                    metrics = excluded.metrics, skills = excluded.skills, sort = excluded.sort
                """,
                [
                    .id(bullet.id), .id(entry.id), .text(bullet.text), try .json(bullet.metrics),
                    try .json(bullet.skills), SQLValue(index),
                ])
        }
    }

    static func write(_ skill: Skill, sort: Int, in connection: Connection) throws {
        try connection.execute(
            """
            INSERT INTO resume_skill (id, name, category, level, sort) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET name = excluded.name, category = excluded.category, level = excluded.level,
                sort = excluded.sort
            """,
            [.id(skill.id), .text(skill.name), .text(skill.category), .text(skill.level.rawValue), SQLValue(sort)])
    }

    /// Keeps the resume as it is now, unless it's empty, and trims old snapshots.
    static func snapshot(reason: String, at now: Date, in connection: Connection) throws {
        let current = try load(in: connection)
        guard !current.entries.isEmpty || !current.skills.isEmpty || !current.header.fullName.isEmpty else { return }
        try connection.execute(
            "INSERT INTO resume_snapshot (at, version, reason, data) VALUES (?, ?, ?, ?)",
            [SQLValue(now), SQLValue(current.version), .text(reason), .text(try current.jsonText())])
        try connection.execute(
            "DELETE FROM resume_snapshot WHERE id NOT IN (SELECT id FROM resume_snapshot ORDER BY at DESC, id DESC LIMIT ?)",
            [SQLValue(ResumeRepository.snapshotsKept)])
    }
}
