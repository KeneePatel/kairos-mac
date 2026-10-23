import Foundation

/// Old jobs leave on their own (SPEC §6.5, T46). A job you never saved, applied to or built a
/// resume for is archived 60 days after Kairos first saw it, and tombstoned at 120 with its
/// analysis and screening trail, so the database and the synced quota don't fill with rejections.
/// A tombstone stays known, so a posting still up after 120 days isn't added back as new.
public struct Retention: Sendable {
    public static let archiveAfterDays = 60
    public static let removeAfterDays = 120

    public struct Outcome: Sendable, Equatable {
        public var archived: Int
        public var removed: Int

        public init(archived: Int = 0, removed: Int = 0) {
            self.archived = archived
            self.removed = removed
        }
    }

    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// Jobs you haven't engaged with: new, skipped or already archived, with no build or application.
    private static let untouched = """
        deleted = 0 AND state IN ('new', 'skipped', 'archived')
        AND id NOT IN (SELECT job_id FROM build WHERE deleted = 0)
        AND id NOT IN (SELECT job_id FROM application WHERE deleted = 0)
        """

    @discardableResult
    public func apply(now: Date) async throws -> Outcome {
        let day: Int64 = 86_400_000
        let removeBefore = now.milliseconds - Int64(Self.removeAfterDays) * day
        let archiveBefore = now.milliseconds - Int64(Self.archiveAfterDays) * day
        return try await db.write { connection, stamp in
            let hlc = SQLValue.text(stamp.hlc.description)
            let leaving = try connection.query(
                "SELECT id FROM job WHERE \(Self.untouched) AND first_seen_at < ?", [.integer(removeBefore)]
            ).compactMap { $0.string("id") }
            for start in stride(from: 0, to: leaving.count, by: 500) {
                let batch = leaving[start..<min(start + 500, leaving.count)].map { SQLValue.text($0) }
                let marks = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                for (table, key) in [
                    ("job", "id"), ("job_analysis", "job_id"), ("screening", "job_id"), ("listing", "job_id"),
                    ("job_event", "job_id"),
                ] {
                    try connection.execute(
                        "UPDATE \(table) SET deleted = 1, updated_hlc = ? WHERE deleted = 0 AND \(key) IN (\(marks))",
                        [hlc] + batch)
                }
            }
            try connection.execute(
                "UPDATE job SET state = 'archived', updated_hlc = ? WHERE \(Self.untouched) AND state != 'archived' AND first_seen_at < ?",
                [hlc, .integer(archiveBefore)])
            return Outcome(archived: connection.changes, removed: leaving.count)
        }
    }
}

/// Integrity checks for the tables that sync, which have no FOREIGN KEY because rows can arrive
/// out of order (SPEC §6.1): rows that point at a job, build, application or entry that's gone,
/// and build files missing from disk. It reports and changes nothing. `kairos doctor` prints it
/// once the CLI exists (R3); until then the app's debug report does.
public struct Doctor: Sendable {
    public struct Finding: Sendable, Equatable {
        /// What's wrong, in words.
        public let problem: String
        public let count: Int
    }

    public struct Report: Sendable, Equatable {
        public let findings: [Finding]
        /// The database file's size, for the quota warning that comes with sync.
        public let databaseBytes: Int64

        public var isClean: Bool { findings.isEmpty }
    }

    /// Child table, its reference column, the parent table, and how a finding reads.
    static let references: [(child: String, column: String, parent: String, problem: String)] = [
        ("job_analysis", "job_id", "job", "Analyses of jobs that are gone"),
        ("screening", "job_id", "job", "Screening records of jobs that are gone"),
        ("build", "job_id", "job", "Builds of jobs that are gone"),
        ("artifact", "build_id", "build", "Build files whose build is gone"),
        ("application", "job_id", "job", "Applications to jobs that are gone"),
        ("application_event", "application_id", "application", "Timeline lines of applications that are gone"),
        ("resume_bullet", "entry_id", "resume_entry", "Resume bullets whose entry is gone"),
    ]

    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public func run(fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        async throws -> Report
    {
        var findings: [Finding] = []
        // A database from before a migration lacks its tables; those checks wait until it has them.
        let tables = Set(
            try await db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") })
        for reference in Self.references where tables.contains(reference.child) && tables.contains(reference.parent) {
            let rows = try await db.query(
                """
                SELECT COUNT(*) AS n FROM \(reference.child) c WHERE c.deleted = 0 AND NOT EXISTS
                    (SELECT 1 FROM \(reference.parent) p WHERE p.id = c.\(reference.column) AND p.deleted = 0)
                """)
            let count = rows.first?.int("n") ?? 0
            if count > 0 { findings.append(Finding(problem: reference.problem, count: count)) }
        }
        let paths = try await db.query("SELECT local_path FROM artifact WHERE deleted = 0 AND local_path IS NOT NULL")
            .compactMap { $0.string("local_path") }
        let missing = paths.filter { !fileExists($0) }.count
        if missing > 0 { findings.append(Finding(problem: "Build files missing from disk", count: missing)) }
        let size = try await db.query(
            "SELECT page_count * page_size AS bytes FROM pragma_page_count(), pragma_page_size()")
        return Report(findings: findings, databaseBytes: size.first?.int64("bytes") ?? 0)
    }
}
