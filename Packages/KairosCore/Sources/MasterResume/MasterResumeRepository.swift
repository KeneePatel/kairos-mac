import Foundation
import Store

public enum MasterResumeError: Error, Equatable, Sendable {
    /// A reorder named an entry or skill that isn't stored (or was deleted).
    case unknownIDs([UUID])
    case encoding(String)
}

/// Reads and edits the master resume. Every change is one small operation in one transaction that
/// also adds 1 to `master_version` (SPEC §5.10). There's no "save the whole document": that would
/// delete rows another device added since the editor loaded, once sync exists.
public struct MasterResumeRepository: Sendable {
    public let db: Database
    static let contactID = "contact"

    public init(_ db: Database) {
        self.db = db
    }

    public func load() async throws -> MasterResume {
        let contact = try await db.query(
            "SELECT * FROM resume_contact WHERE id = ? AND deleted = 0", [.text(Self.contactID)])
        let entryRows = try await db.query("SELECT * FROM resume_entry WHERE deleted = 0 ORDER BY kind, sort, id")
        let bulletRows = try await db.query("SELECT * FROM resume_bullet WHERE deleted = 0 ORDER BY entry_id, sort, id")
        let skillRows = try await db.query("SELECT * FROM skill WHERE deleted = 0 ORDER BY sort, id")

        var bullets: [UUID: [ResumeBullet]] = [:]
        for row in bulletRows {
            let r = RowReader(row: row, table: "resume_bullet")
            bullets[try r.uuid("entry_id"), default: []].append(
                ResumeBullet(
                    id: try r.uuid("id"), text: try r.string("text"),
                    metrics: try r.json("metrics", as: [String].self) ?? [],
                    skills: try r.json("skills", as: [String].self) ?? []))
        }
        let entries = try entryRows.map { row throws in
            let r = RowReader(row: row, table: "resume_entry")
            let kind = try r.value("kind", as: EntryKind.self)
            guard let fields = try? EntryFields.decode(kind: kind, from: Data(try r.string("fields").utf8)) else {
                throw r.corrupt("fields")
            }
            let id = try r.uuid("id")
            return ResumeEntry(
                id: id, fields: fields, start: row.string("start_month").flatMap(YearMonth.init),
                end: row.string("end_month").flatMap(YearMonth.init), isCurrent: try r.bool("is_current"),
                bullets: bullets[id] ?? [])
        }
        let skills = try skillRows.map { row throws in
            let r = RowReader(row: row, table: "skill")
            return Skill(
                id: try r.uuid("id"), name: try r.string("name"), category: try r.string("category"),
                level: try r.value("level", as: SkillLevel.self))
        }
        guard let row = contact.first else { return MasterResume(entries: entries, skills: skills) }
        return MasterResume(
            header: Self.header(row), entries: entries, skills: skills, version: row.int("master_version") ?? 0)
    }

    // MARK: - Header

    @discardableResult
    public func saveHeader(_ header: ResumeHeader) async throws -> Int {
        let values: [SQLValue] = [
            .text(header.fullName), .text(header.email), .text(header.phone), .text(header.linkedInURL),
            SQLValue(header.gitHubURL), SQLValue(header.portfolioURL), SQLValue(header.city), SQLValue(header.region),
            SQLValue(header.country), .text(header.headline), .text(header.highlights), SQLValue(header.totalYears),
        ]
        return try await db.write { connection, stamp in
            try connection.execute(
                """
                INSERT INTO resume_contact (id, full_name, email, phone_e164, linkedin_url, github_url, portfolio_url,
                    city, region, country, headline, highlights, total_years, updated_hlc)
                VALUES ('contact', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (id) DO UPDATE SET full_name = excluded.full_name, email = excluded.email,
                    phone_e164 = excluded.phone_e164, linkedin_url = excluded.linkedin_url,
                    github_url = excluded.github_url, portfolio_url = excluded.portfolio_url, city = excluded.city,
                    region = excluded.region, country = excluded.country, headline = excluded.headline,
                    highlights = excluded.highlights, total_years = excluded.total_years, deleted = 0
                """, values + [.text(stamp.hlc.description)])
            return try Self.bumpVersion(connection, stamp)
        }
    }

    // MARK: - Entries

    /// Inserts or updates each entry with its bullets, in their given order. A new entry goes to the
    /// end of its kind; an existing one keeps its place. Bullets dropped from an entry are tombstoned.
    @discardableResult
    public func save(_ entries: [ResumeEntry]) async throws -> Int {
        let encoded = try entries.map { entry in
            do {
                return (entry, String(decoding: try entry.fields.encoded(), as: UTF8.self))
            } catch {
                throw MasterResumeError.encoding("entry \(entry.id): \(error)")
            }
        }
        return try await db.write { connection, stamp in
            let hlc = SQLValue.text(stamp.hlc.description)
            for (entry, fields) in encoded {
                let id = SQLValue.text(entry.id.lowercased)
                try connection.execute(
                    """
                    INSERT INTO resume_entry (id, kind, fields, start_month, end_month, is_current, sort, updated_hlc)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6,
                        (SELECT coalesce(max(sort), -1) + 1 FROM resume_entry WHERE kind = ?2 AND deleted = 0), ?7)
                    ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, fields = excluded.fields,
                        start_month = excluded.start_month, end_month = excluded.end_month,
                        is_current = excluded.is_current, updated_hlc = excluded.updated_hlc, deleted = 0
                    """,
                    [
                        id, .text(entry.kind.rawValue), .text(fields), SQLValue(entry.start?.description),
                        SQLValue(entry.isCurrent ? nil : entry.end?.description), SQLValue(entry.isCurrent), hlc,
                    ])
                for (index, bullet) in entry.bullets.enumerated() {
                    try connection.execute(
                        """
                        INSERT INTO resume_bullet (id, entry_id, text, metrics, skills, sort, updated_hlc)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT (id) DO UPDATE SET entry_id = excluded.entry_id, text = excluded.text,
                            metrics = excluded.metrics, skills = excluded.skills, sort = excluded.sort,
                            updated_hlc = excluded.updated_hlc, deleted = 0
                        """,
                        [
                            .text(bullet.id.lowercased), id, .text(bullet.text), try SQLValue(json: bullet.metrics),
                            try SQLValue(json: bullet.skills), SQLValue(index), hlc,
                        ])
                }
                let kept = entry.bullets.map { SQLValue.text($0.id.lowercased) }
                let marks = Array(repeating: "?", count: kept.count).joined(separator: ", ")
                try connection.execute(
                    "UPDATE resume_bullet SET deleted = 1, updated_hlc = ? WHERE entry_id = ? AND deleted = 0"
                        + (kept.isEmpty ? "" : " AND id NOT IN (\(marks))"),
                    [hlc, id] + kept)
            }
            return try Self.bumpVersion(connection, stamp)
        }
    }

    /// Tombstones the entry and its bullets.
    @discardableResult
    public func deleteEntry(_ id: UUID) async throws -> Int {
        try await db.write { connection, stamp in
            let values: [SQLValue] = [.text(stamp.hlc.description), .text(id.lowercased)]
            try connection.execute(
                "UPDATE resume_entry SET deleted = 1, updated_hlc = ? WHERE id = ? AND deleted = 0", values)
            try connection.execute(
                "UPDATE resume_bullet SET deleted = 1, updated_hlc = ? WHERE entry_id = ? AND deleted = 0", values)
            return try Self.bumpVersion(connection, stamp)
        }
    }

    /// Puts these entries (all of one kind, or any mix) in this order: each gets its index as `sort`.
    @discardableResult
    public func reorderEntries(_ ids: [UUID]) async throws -> Int {
        try await reorder("resume_entry", ids)
    }

    // MARK: - Skills

    /// Inserts or updates each skill. A new skill goes to the end; an existing one keeps its place.
    @discardableResult
    public func save(_ skills: [Skill]) async throws -> Int {
        try await db.write { connection, stamp in
            for skill in skills {
                try connection.execute(
                    """
                    INSERT INTO skill (id, name, category, level, sort, updated_hlc)
                    VALUES (?, ?, ?, ?, (SELECT coalesce(max(sort), -1) + 1 FROM skill WHERE deleted = 0), ?)
                    ON CONFLICT (id) DO UPDATE SET name = excluded.name, category = excluded.category,
                        level = excluded.level, updated_hlc = excluded.updated_hlc, deleted = 0
                    """,
                    [
                        .text(skill.id.lowercased), .text(skill.name), .text(skill.category),
                        SQLValue(skill.level), .text(stamp.hlc.description),
                    ])
            }
            return try Self.bumpVersion(connection, stamp)
        }
    }

    @discardableResult
    public func deleteSkill(_ id: UUID) async throws -> Int {
        try await db.write { connection, stamp in
            try connection.execute(
                "UPDATE skill SET deleted = 1, updated_hlc = ? WHERE id = ? AND deleted = 0",
                [.text(stamp.hlc.description), .text(id.lowercased)])
            return try Self.bumpVersion(connection, stamp)
        }
    }

    @discardableResult
    public func reorderSkills(_ ids: [UUID]) async throws -> Int {
        try await reorder("skill", ids)
    }

    // MARK: - Shared

    private func reorder(_ table: String, _ ids: [UUID]) async throws -> Int {
        try await db.write { connection, stamp in
            var unknown: [UUID] = []
            for (index, id) in ids.enumerated() {
                try connection.execute(
                    "UPDATE \(table) SET sort = ?, updated_hlc = ? WHERE id = ? AND deleted = 0",
                    [SQLValue(index), .text(stamp.hlc.description), .text(id.lowercased)])
                if connection.changes == 0 { unknown.append(id) }
            }
            // Throwing rolls the whole reorder back, version included.
            guard unknown.isEmpty else { throw MasterResumeError.unknownIDs(unknown) }
            return try Self.bumpVersion(connection, stamp)
        }
    }

    /// +1 on the contact row, created empty if this is the first save. Runs inside the caller's transaction.
    private static func bumpVersion(_ connection: Connection, _ stamp: WriteStamp) throws -> Int {
        let rows = try connection.query(
            """
            INSERT INTO resume_contact (id, master_version, updated_hlc) VALUES ('contact', 1, ?)
            ON CONFLICT (id) DO UPDATE SET master_version = master_version + 1, updated_hlc = excluded.updated_hlc
            RETURNING master_version
            """, [.text(stamp.hlc.description)])
        return rows.first?.int("master_version") ?? 0
    }

    private static func header(_ row: Row) -> ResumeHeader {
        var header = ResumeHeader()
        header.fullName = row.string("full_name") ?? ""
        header.email = row.string("email") ?? ""
        header.phone = row.string("phone_e164") ?? ""
        header.linkedInURL = row.string("linkedin_url") ?? ""
        header.gitHubURL = row.string("github_url")
        header.portfolioURL = row.string("portfolio_url")
        header.city = row.string("city")
        header.region = row.string("region")
        header.country = row.string("country")
        header.headline = row.string("headline") ?? ""
        header.highlights = row.string("highlights") ?? ""
        header.totalYears = row.double("total_years")
        return header
    }
}
