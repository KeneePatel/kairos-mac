import AI
import Foundation
import Jobs
import KairosKit
import Resume
import SQL
import Screening
import Tailoring

/// Brings the first Kairos's data into this one: sources, jobs with their listings, history,
/// analyses and screening, the master resume, builds with their PDFs, applications, settings, and
/// what search budgets and key quotas need to remember. The old database is opened read-only and
/// copied to Backups first; its files are never changed. Everything is written in one transaction,
/// so an import either happens whole or not at all, and runs once.
public struct LegacyImport: Sendable {
    /// What was brought over.
    public struct Report: Codable, Sendable, Equatable {
        public var schemaVersion = 0
        public var sources = 0
        public var jobs = 0
        /// Imported archived: out of the lists, kept so the same postings aren't new again.
        public var archived = 0
        /// Left behind: jobs you cleared, and search snippets that were never whole postings.
        public var leftBehind = 0
        public var listings = 0
        /// Listings whose address this version writes differently, stored under the new form.
        public var readdressed = 0
        public var events = 0
        public var analyses = 0
        public var screened = 0
        public var builds = 0
        public var files = 0
        public var missingFiles = 0
        public var applications = 0
        public var resumeEntries = 0
        public var resumeBullets = 0
        public var skills = 0
        public var settings = 0
        public var leads = 0
        public var notes: [String] = []
        public var backup: String?

        public init() {}
    }

    public enum ImportError: Error, Equatable, Sendable {
        case noLegacyDatabase
        case alreadyImported
        case tooOld(Int)

        public var message: String {
            switch self {
            case .noLegacyDatabase: "There's no database from the first Kairos to import."
            case .alreadyImported: "The first Kairos's data was imported already."
            case .tooOld(let version):
                "The first Kairos's database is at schema \(version); open that version once so it updates, then import."
            }
        }
    }

    /// The setting that records an import, so it runs once.
    public static let markerKey = "legacy_import"
    /// The oldest schema the importer reads: listings arrived in 011.
    static let oldestVersion = 11

    let store: KairosStore
    let folder: DataFolder

    public init(store: KairosStore, folder: DataFolder) {
        self.store = store
        self.folder = folder
    }

    /// Whether there's an old database this install hasn't imported.
    public func isPending() async throws -> Bool {
        guard FileManager.default.fileExists(atPath: folder.legacyDatabase.path) else { return false }
        return try await store.settings.value(Self.markerKey, as: Report.self) == nil
    }

    @discardableResult
    public func run(at now: Date = Date()) async throws -> Report {
        guard FileManager.default.fileExists(atPath: folder.legacyDatabase.path) else {
            throw ImportError.noLegacyDatabase
        }
        guard try await store.settings.value(Self.markerKey, as: Report.self) == nil else {
            throw ImportError.alreadyImported
        }
        let legacy = try Database(path: folder.legacyDatabase.path, readOnly: true)
        let version = try await legacy.userVersion()
        guard version >= Self.oldestVersion else { throw ImportError.tooOld(version) }

        try FileManager.default.createDirectory(at: folder.backups, withIntermediateDirectories: true)
        let backup = folder.backup("kairos-v1", at: now)
        if !FileManager.default.fileExists(atPath: backup.path) { try await legacy.backUp(to: backup) }

        let old = try await legacy.read { connection in try OldRows(connection) }
        var plan = Plan(now: now, old: old)
        plan.sources()
        plan.jobs()
        plan.screening()
        plan.resume()
        plan.builds(copying: { try self.copy($0, build: $1, kind: $2) })
        plan.applications()
        plan.settings()
        plan.activity()
        var report = plan.report
        report.schemaVersion = version
        report.backup = folder.relative(backup)

        let writes = plan.writes
        let marker = try SQLValue.json(report)
        try await store.db.transaction { connection in
            // Foreign keys are checked when the import commits, so rows may arrive in any order.
            try connection.executeScript("PRAGMA defer_foreign_keys = ON")
            for write in writes { try connection.execute(write.sql, write.values) }
            try connection.execute(
                """
                INSERT INTO setting (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """, [.text(Self.markerKey), marker, SQLValue(now)])
        }
        return report
    }

    /// Copies an old PDF into the build's folder; nil when it's missing.
    private func copy(_ path: String, build: String, kind: BuildRecord.File.Kind) throws -> (
        path: String, sha256: String
    )? {
        let source = URL(filePath: path)
        guard let data = try? Data(contentsOf: source) else { return nil }
        let directory = folder.builds.appending(path: build, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: kind == .resume ? "Resume.pdf" : "Cover Letter.pdf")
        try data.write(to: target, options: .atomic)
        return (folder.relative(target), StableID.sha256(data))
    }
}

// MARK: - The old rows

/// Every old table the import reads, as rows. A table an older schema lacks reads as empty.
struct OldRows: Sendable {
    var sources: [Row] = []
    var fetchState: [Row] = []
    var jobs: [Row] = []
    var listings: [Row] = []
    var events: [Row] = []
    var analyses: [Row] = []
    var screenings: [Row] = []
    var contact: [Row] = []
    var entries: [Row] = []
    var bullets: [Row] = []
    var skills: [Row] = []
    var settings: [Row] = []
    var privateSettings: [Row] = []
    var builds: [Row] = []
    var artifacts: [Row] = []
    var applications: [Row] = []
    var applicationEvents: [Row] = []
    var keyCalls: [Row] = []
    var fetchLog: [Row] = []
    var leads: [Row] = []
    var lookups: [Row] = []
    var turns: [Row] = []

    init(_ connection: Connection) throws {
        let tables = Set(
            try connection.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") }
        )
        func all(_ table: String, _ order: String = "rowid") throws -> [Row] {
            guard tables.contains(table) else { return [] }
            return try connection.query("SELECT * FROM \(table) ORDER BY \(order)")
        }
        sources = try all("source")
        fetchState = try all("source_fetch_state")
        jobs = try all("job", "first_seen_at, id")
        listings = try all("listing", "first_seen_at, id")
        events = try all("job_event", "at, id")
        analyses = try all("job_analysis")
        screenings = try all("screening", "at, id")
        contact = try all("resume_contact")
        entries = try all("resume_entry", "kind, sort, id")
        bullets = try all("resume_bullet", "entry_id, sort, id")
        skills = try all("skill", "sort, id")
        settings = try all("setting")
        privateSettings = try all("private_setting")
        builds = try all("build", "created_at, id")
        artifacts = try all("artifact")
        applications = try all("application")
        applicationEvents = try all("application_event", "at, id")
        keyCalls = try all("llm_key_call", "at, id")
        fetchLog = try all("fetch_log", "at, id")
        leads = try all("lead")
        lookups = try all("company_lookup")
        turns = try all("search_turn")
    }
}

// MARK: - The plan

/// The old rows turned into the new schema's inserts, before any is written.
private struct Plan {
    struct Write: Sendable {
        let sql: String
        let values: [SQLValue]
    }

    let now: Date
    let old: OldRows
    var writes: [Write] = []
    var report = LegacyImport.Report()

    /// Old source id → its kind, for jobs, listings and events.
    var sourceKinds: [String: SourceKind] = [:]
    /// Jobs imported, and listing ids moved to the address this version writes.
    var jobIDs: Set<String> = []
    var listingIDs: [String: String] = [:]
    var buildIDs: Set<String> = []
    var applicationIDs: Set<String> = []
    var broughtBack: Set<String> = []

    init(now: Date, old: OldRows) {
        self.now = now
        self.old = old
        for row in old.settings where !(row.bool("deleted") ?? false) && row.string("key") == "screening.broughtBack" {
            broughtBack = Set((try? row.json("value", as: [String].self, table: "setting")) ?? [])
        }
    }

    mutating func write(_ sql: String, _ values: [SQLValue]) {
        writes.append(Write(sql: sql, values: values))
    }

    /// A row's id as this version stores it: a lowercase UUID, or nil when it isn't one.
    static func uuid(_ row: Row, _ column: String = "id") -> String? {
        row.string(column).flatMap(UUID.init(uuidString:))?.lowercased
    }

    // MARK: Sources

    mutating func sources() {
        var state: [String: Row] = [:]
        for row in old.fetchState { if let id = row.string("source_id") { state[id.lowercased()] = row } }
        var boards: Set<String> = []
        // Watched sources first, so a board listed twice keeps the copy you use.
        let ordered = old.sources.sorted {
            ($0.bool("deleted") ?? false ? 1 : 0) < ($1.bool("deleted") ?? false ? 1 : 0)
        }
        for row in ordered {
            guard let id = Self.uuid(row), let kind = row.string("kind").flatMap(SourceKind.init) else { continue }
            sourceKinds[id] = kind
            let config = (try? JSONValue(parsing: row.string("config") ?? "{}")) ?? .object([:])
            let deleted = row.bool("deleted") ?? false
            let enabled = row.bool("enabled") ?? true
            var slug = ""
            var name = config["company"]?.stringValue ?? ""
            var origin = Source.Origin.search
            var status = Source.Status.watching
            if kind.isBoard {
                guard let given = config["slug"]?.stringValue, !given.isEmpty else { continue }
                slug = kind == .smartRecruiters ? given : given.lowercased()
                guard boards.insert("\(kind.rawValue)|\(slug)").inserted else { continue }
                if name.isEmpty { name = given }
                origin =
                    switch config["origin"]?.stringValue {
                    case "catalog"?: .catalog
                    case "search"?: .lead
                    case let value? where SourceKind(rawValue: value) != nil: .link
                    default: .you
                    }
                status = deleted ? .removed : row.string("health") == "gone" ? .gone : enabled ? .watching : .muted
            } else {
                guard boards.insert(kind.rawValue).inserted else { continue }
                name = kind.displayName
                status = !deleted && enabled ? .watching : .muted
            }
            let fetch = state[id]
            write(
                """
                INSERT INTO source (id, kind, slug, name, region, origin, status, added_at, checked_at, ok_at,
                    fail_streak)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(kind.rawValue), .text(slug), .text(name), SQLValue(config["region"]?.stringValue),
                    .text(origin.rawValue), .text(status.rawValue),
                    SQLValue(UUID(uuidString: id).map(Self.time) ?? now),
                    row["last_run_at"], fetch?["last_ok_at"] ?? .null, SQLValue(fetch?.int("fail_runs") ?? 0),
                ])
            report.sources += 1
        }
    }

    /// When a UUIDv7 was made.
    static func time(_ id: UUID) -> Date {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let milliseconds = bytes.prefix(6).reduce(Int64(0)) { $0 << 8 | Int64($1) }
        return Date(milliseconds: milliseconds)
    }

    // MARK: Jobs

    mutating func jobs() {
        var listingsByJob: [String: [Row]] = [:]
        for row in old.listings { if let job = row.string("job_id") { listingsByJob[job, default: []].append(row) } }
        let applied = Set(
            old.applications.filter { !($0.bool("deleted") ?? false) }.compactMap { $0.string("job_id") })
        let built = Set(old.builds.filter { !($0.bool("deleted") ?? false) }.compactMap { $0.string("job_id") })

        for row in old.jobs {
            guard let id = row.string("id") else { continue }
            let state = row.string("state") ?? "new"
            let engaged = applied.contains(id) || built.contains(id) || state == "shortlisted" || state == "applied"
            let deleted = row.bool("deleted") ?? false
            // A job you cleared comes back as new when it's still posted; one retention removed
            // stays known, archived.
            if deleted && (row.bool("cleared") ?? false) && !engaged {
                report.leftBehind += 1
                continue
            }
            let whole = (listingsByJob[id] ?? []).filter { $0.string("description_kind") != "snippet" }
            // Search snippets were never whole postings: Adzuna's adverts are leads now.
            if whole.isEmpty && row.string("description_kind") == "snippet" && !engaged {
                report.leftBehind += 1
                continue
            }
            let archived = deleted || state == "archived"
            let decision: Job.Decision? =
                switch state {
                case "shortlisted": .saved
                case "skipped": .skipped
                default: nil
                }
            let jobWrite = writes.count
            let primary = takeListings(of: row, whole.isEmpty ? (listingsByJob[id] ?? []) : whole)
            let listingWrites = writes[jobWrite...]
            writes.removeSubrange(jobWrite...)
            let sourceKind = row.string("source_id").flatMap { sourceKinds[$0.lowercased()] }
            let salary = Self.salary(row)
            write(
                """
                INSERT INTO job (id, company, title, location, city, region, country, remote_scope, salary, posted_at,
                    description, url, apply_url, via, source_kind, primary_listing_id, dedup_key, first_seen_at,
                    last_seen_at, closed_at, decision, decided_at, archived_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(row.string("company") ?? ""), .text(row.string("title") ?? ""),
                    .text(row.string("location") ?? ""), row["city"], row["region"],
                    SQLValue(row.string("country").flatMap(Country.init)?.rawValue),
                    .text(
                        row.string("remote_scope").flatMap(RemoteScope.init)?.rawValue ?? RemoteScope.unknown.rawValue),
                    (try? SQLValue.json(salary)) ?? .null, row["posted_at"], .text(row.string("description") ?? ""),
                    .text(row.string("url") ?? ""), row["apply_url"], row["via"], SQLValue(sourceKind?.rawValue),
                    .text(primary ?? id), .text(row.string("dedup_key") ?? ""), row["first_seen_at"],
                    row["last_seen_at"] == .null ? row["first_seen_at"] : row["last_seen_at"], row["closed_at"],
                    SQLValue(decision?.rawValue), .null, archived ? SQLValue(now) : .null, SQLValue(now),
                ])
            writes += listingWrites
            jobIDs.insert(id)
            report.jobs += 1
            if archived { report.archived += 1 }
        }
        for row in old.events where !(row.bool("deleted") ?? false) {
            guard let job = row.string("job_id"), jobIDs.contains(job),
                let kind = row.string("kind").flatMap(JobEvent.Kind.init)
            else { continue }
            write(
                "INSERT INTO job_event (job_id, at, kind, source_kind, detail) VALUES (?, ?, ?, ?, ?)",
                [
                    .text(job), row["at"], .text(kind.rawValue),
                    SQLValue(row.string("source_id").flatMap { sourceKinds[$0.lowercased()] }?.rawValue), row["detail"],
                ])
            report.events += 1
        }
    }

    /// Writes a job's listings under the address this version writes, and returns its primary
    /// listing's id.
    mutating func takeListings(of job: Row, _ rows: [Row]) -> String? {
        guard let jobID = job.string("id") else { return nil }
        let oldPrimary = job.string("primary_listing_id") ?? jobID
        var primary: String?
        for row in rows {
            guard let oldID = row.string("id"), let url = row.string("url") else { continue }
            let canonical = URLCanonicalizer.canonical(row.string("canonical_url") ?? url)
            let id = StableID.of(canonical)
            guard listingIDs[id] == nil else { continue }
            listingIDs[id] = jobID
            if id != oldID { report.readdressed += 1 }
            if oldID == oldPrimary || primary == nil { primary = id }
            let deleted = row.bool("deleted") ?? false
            // An empty hash marks an imported listing: its first sighting refreshes its text without
            // counting as an edit, since this version writes postings' Markdown its own way.
            write(
                """
                INSERT INTO listing (id, job_id, source_id, canonical_url, url, apply_url, title, company, location,
                    posted_at, content_hash, first_seen_at, last_seen_at, missing_streak, closed_at)
                VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, '', ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(jobID), .text((row.string("source_id") ?? "").lowercased()), .text(canonical),
                    .text(url), .text(row.string("title") ?? ""), .text(row.string("company") ?? ""),
                    .text(row.string("location") ?? ""), row["posted_at"], row["first_seen_at"], row["last_seen_at"],
                    SQLValue(row.int("missing_runs") ?? 0),
                    deleted && row["closed_at"] == .null ? SQLValue(now) : row["closed_at"],
                ])
            report.listings += 1
        }
        return primary
    }

    /// The old salary JSON, with the currency the job kept beside it.
    static func salary(_ row: Row) -> Salary? {
        guard let text = row.string("salary"), var salary = try? Salary.fromJSON(text) else { return nil }
        if salary.currency == nil { salary.currency = row.string("currency") }
        return salary.min == nil && salary.max == nil && salary.text == nil ? nil : salary
    }

    // MARK: Analyses and screening

    mutating func screening() {
        var analyzed: Set<String> = []
        for row in old.analyses where !(row.bool("deleted") ?? false) {
            guard let job = row.string("job_id"), jobIDs.contains(job),
                let requirements = try? row.json(
                    "requirements", as: [JobAnalysis.Requirement].self, table: "job_analysis"),
                let flags = try? row.json("flags", as: JobAnalysis.Flags.self, table: "job_analysis")
            else { continue }
            write(
                """
                INSERT INTO analysis (job_id, requirements, flags, domains, years_required, seniority, model,
                    prompt_version, analyzed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(job), (try? SQLValue.json(requirements)) ?? "[]", (try? SQLValue.json(flags)) ?? "{}",
                    row["domains"] == .null ? "[]" : row["domains"], row["years_required"],
                    SQLValue(row.string("seniority").flatMap(Seniority.init)?.rawValue),
                    .text(row.string("model") ?? "imported"), SQLValue(row.int("prompt_version") ?? 1),
                    row["analyzed_at"],
                ])
            analyzed.insert(job)
            report.analyses += 1
        }

        var latest: [String: (analysis: Row?, prefilter: Row?)] = [:]
        for row in old.screenings where !(row.bool("deleted") ?? false) {
            guard let job = row.string("job_id") else { continue }
            switch row.string("stage") {
            case "analysis": latest[job, default: (nil, nil)].analysis = row
            case "prefilter": latest[job, default: (nil, nil)].prefilter = row
            default: break
            }
        }
        for job in old.jobs {
            guard let id = job.string("id"), jobIDs.contains(id) else { continue }
            let verdict = job.string("verdict").flatMap(Verdict.init)
            let rows = latest[id]
            let back = broughtBack.contains(id)
            var state: ScreeningState?
            switch job.string("verdict_source") {
            case "prefilter" where !back:
                state = ScreeningState(
                    stage: .filtered, rule: rows?.prefilter?.string("rule_id"), reasons: Self.reasons(rows?.prefilter),
                    screenedAt: rows?.prefilter?.date("at") ?? now)
            case "analysis":
                state = judged(rows?.analysis, verdict: verdict, rank: job.double("rank"))
            case "user":
                state =
                    rows?.analysis.flatMap {
                        judged($0, verdict: $0.string("verdict").flatMap(Verdict.init), rank: job.double("rank"))
                    }
                    ?? ScreeningState(stage: .waiting, screenedAt: now)
                state?.yourVerdict = verdict
            default:
                if back { state = ScreeningState(stage: .waiting, screenedAt: now) }
            }
            guard var state else { continue }
            state.broughtBack = back
            write(
                """
                INSERT INTO screening (job_id, stage, verdict, rule, reasons, coverage, match, rank, your_verdict,
                    brought_back, screened_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(state.stage.rawValue), SQLValue(state.verdict?.rawValue), SQLValue(state.rule),
                    (try? SQLValue.json(state.reasons)) ?? "[]", (try? SQLValue.json(state.coverage)) ?? .null,
                    SQLValue(state.match), SQLValue(state.rank), SQLValue(state.yourVerdict?.rawValue),
                    SQLValue(state.broughtBack), SQLValue(state.screenedAt),
                ])
            report.screened += 1
        }
    }

    func judged(_ row: Row?, verdict: Verdict?, rank: Double?) -> ScreeningState? {
        guard let verdict else { return nil }
        var coverage: Coverage?
        if let row, let stored = try? row.json("coverage", as: Coverage.self, table: "screening") { coverage = stored }
        return ScreeningState(
            stage: .judged, verdict: verdict, rule: row?.string("rule_id"), reasons: Self.reasons(row),
            coverage: coverage, match: coverage?.match, rank: rank, screenedAt: row?.date("at") ?? now)
    }

    static func reasons(_ row: Row?) -> [String] {
        (try? row?.json("reasons", as: [String].self, table: "screening")) ?? []
    }

    // MARK: Master resume

    mutating func resume() {
        let contact = old.contact.first { !($0.bool("deleted") ?? false) }
        write(
            """
            INSERT INTO resume_header (id, full_name, email, phone, linkedin_url, github_url, portfolio_url, city, region,
                country, headline, highlights, total_years, version, updated_at)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (id) DO UPDATE SET full_name = excluded.full_name, email = excluded.email,
                phone = excluded.phone, linkedin_url = excluded.linkedin_url, github_url = excluded.github_url,
                portfolio_url = excluded.portfolio_url, city = excluded.city, region = excluded.region,
                country = excluded.country, headline = excluded.headline, highlights = excluded.highlights,
                total_years = excluded.total_years, version = excluded.version, updated_at = excluded.updated_at
            """,
            [
                .text(contact?.string("full_name") ?? ""), .text(contact?.string("email") ?? ""),
                .text(contact?.string("phone_e164") ?? ""), .text(contact?.string("linkedin_url") ?? ""),
                contact?["github_url"] ?? .null, contact?["portfolio_url"] ?? .null, contact?["city"] ?? .null,
                contact?["region"] ?? .null, contact?["country"] ?? .null, .text(contact?.string("headline") ?? ""),
                .text(contact?.string("highlights") ?? ""), contact?["total_years"] ?? .null,
                SQLValue(contact?.int("master_version") ?? 0), SQLValue(now),
            ])
        var entries: Set<String> = []
        for (index, row) in old.entries.enumerated() where !(row.bool("deleted") ?? false) {
            guard let id = Self.uuid(row), let kind = row.string("kind").flatMap(EntryKind.init),
                let fields = row.string("fields"), (try? EntryFields.decode(kind: kind, json: fields)) != nil
            else {
                report.notes.append("A resume entry couldn't be read and was left behind.")
                continue
            }
            write(
                "INSERT INTO resume_entry (id, kind, fields, start_month, end_month, is_current, sort) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [
                    .text(id), .text(kind.rawValue), .text(fields), row["start_month"], row["end_month"],
                    SQLValue(row.bool("is_current") ?? false), SQLValue(index),
                ])
            entries.insert(id)
            report.resumeEntries += 1
        }
        for row in old.bullets where !(row.bool("deleted") ?? false) {
            guard let id = Self.uuid(row), let entry = Self.uuid(row, "entry_id"), entries.contains(entry)
            else { continue }
            write(
                "INSERT INTO resume_bullet (id, entry_id, text, metrics, skills, sort) VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .text(id), .text(entry), .text(row.string("text") ?? ""),
                    row["metrics"] == .null ? "[]" : row["metrics"],
                    row["skills"] == .null ? "[]" : row["skills"], SQLValue(row.int("sort") ?? 0),
                ])
            report.resumeBullets += 1
        }
        for row in old.skills where !(row.bool("deleted") ?? false) {
            guard let id = Self.uuid(row), let name = row.string("name") else { continue }
            write(
                "INSERT INTO resume_skill (id, name, category, level, sort) VALUES (?, ?, ?, ?, ?)",
                [
                    .text(id), .text(name), .text(row.string("category") ?? ""),
                    .text(row.string("level").flatMap(SkillLevel.init)?.rawValue ?? SkillLevel.proven.rawValue),
                    SQLValue(row.int("sort") ?? 0),
                ])
            report.skills += 1
        }
    }

    // MARK: Builds and applications

    mutating func builds(
        copying copy: (String, String, BuildRecord.File.Kind) throws -> (path: String, sha256: String)?
    ) {
        var files: [String: [Row]] = [:]
        for row in old.artifacts where !(row.bool("deleted") ?? false) {
            if let build = Self.uuid(row, "build_id") { files[build, default: []].append(row) }
        }
        for row in old.builds where !(row.bool("deleted") ?? false) {
            guard let id = Self.uuid(row), let job = row.string("job_id"), jobIDs.contains(job),
                let mode = row.string("mode").flatMap(BuildMode.init)
            else { continue }
            let record = try? row.json("cover_letter", as: OldLetter.self, table: "build")
            let content = row.string("content").flatMap { try? TailoredResume.fromJSON($0) }
            let score = try? row.json("breakdown", as: MatchScore.self, table: "build")
            var status = row.string("status").flatMap(BuildRecord.Status.init) ?? .failed
            var error = row.string("error")
            if !status.isFinished {
                status = .failed
                error = "This build was left unfinished when Kairos was rebuilt. Build again."
            }
            let notes = BuildNotes(score: score)
            write(
                """
                INSERT INTO build (id, job_id, mode, resume_version, status, wants_letter, content, letter, letter_error,
                    report, score, error, created_at, started_at, finished_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
                """,
                [
                    .text(id), .text(job), .text(mode.rawValue), SQLValue(row.int("master_version") ?? 0),
                    .text(status.rawValue), SQLValue(record != nil), (try? SQLValue.json(content)) ?? .null,
                    (try? SQLValue.json(record?.letter)) ?? .null, SQLValue(record?.error),
                    (try? SQLValue.json(notes)) ?? .null,
                    row["match_score"], SQLValue(error), row["created_at"], row["finished_at"],
                ])
            buildIDs.insert(id)
            report.builds += 1
            var kinds: Set<BuildRecord.File.Kind> = []
            for file in files[id] ?? [] {
                let kind: BuildRecord.File.Kind = file.string("kind") == "cover_letter" ? .letter : .resume
                guard let path = file.string("local_path"), kinds.insert(kind).inserted else { continue }
                guard let copied = try? copy(path, id, kind) else {
                    report.missingFiles += 1
                    continue
                }
                write(
                    "INSERT INTO build_file (build_id, kind, path, sha256) VALUES (?, ?, ?, ?)",
                    [.text(id), .text(kind.rawValue), .text(copied.path), .text(copied.sha256)])
                report.files += 1
            }
        }
    }

    /// The old `build.cover_letter`: the letter, or why there isn't one.
    struct OldLetter: Decodable {
        var letter: CoverLetter?
        var error: String?
    }

    mutating func applications() {
        for row in old.applications where !(row.bool("deleted") ?? false) {
            guard let id = Self.uuid(row), let job = row.string("job_id"), jobIDs.contains(job),
                let status = row.string("status").flatMap(Application.Status.init)
            else { continue }
            let build = Self.uuid(row, "build_id")
            write(
                """
                INSERT INTO application (id, job_id, build_id, applied_at, channel, status, status_at, follow_up_at,
                    next_step, notes, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(id), .text(job), SQLValue(build.flatMap { buildIDs.contains($0) ? $0 : nil }),
                    row["applied_at"],
                    row["channel"], .text(status.rawValue), row["status_at"], row["next_action_at"], row["next_action"],
                    .text(row.string("notes") ?? ""), row["status_at"],
                ])
            applicationIDs.insert(id)
            report.applications += 1
        }
        for row in old.applicationEvents where !(row.bool("deleted") ?? false) {
            guard let application = Self.uuid(row, "application_id"), applicationIDs.contains(application) else {
                continue
            }
            let id = Self.uuid(row) ?? UUID.v7().lowercased
            write(
                "INSERT INTO application_event (id, application_id, kind, at, note) VALUES (?, ?, ?, ?, ?)",
                [.text(id), .text(application), .text(row.string("kind") ?? "note"), row["at"], row["note"]])
        }
    }

    // MARK: Settings and activity

    mutating func settings() {
        let rows = old.settings.filter { !($0.bool("deleted") ?? false) } + old.privateSettings
        func take<T: Codable>(_ key: String, as type: T.Type) {
            guard let text = rows.last(where: { $0.string("key") == key })?.string("value") else { return }
            guard let value = try? T.fromJSON(text), let json = try? value.jsonText() else {
                report.notes.append("The \(key) setting couldn't be read and was left at its default.")
                return
            }
            write(
                "INSERT INTO setting (key, value, updated_at) VALUES (?, ?, ?)",
                [.text(key), .text(json), SQLValue(now)])
            report.settings += 1
        }
        take(SearchPreferences.storageKey, as: SearchPreferences.self)
        take(WorkProfile.storageKey, as: WorkProfile.self)
        take(AISettings.storageKey, as: AISettings.self)
        take(StretchSettings.storageKey, as: StretchSettings.self)
        take(PageSettings.storageKey, as: PageSettings.self)
    }

    /// What budgets and quotas remember: the searches' requests since the start of last month,
    /// keys' calls in the last two days, leads, company lookups and Google Jobs turns.
    mutating func activity() {
        let since = now.addingTimeInterval(-.days(35))
        for row in old.fetchLog where (row.date("at") ?? .distantPast) >= since {
            guard let source = row.string("source_id")?.lowercased(), sourceKinds[source] != nil else { continue }
            let outcome = row.string("outcome").flatMap(FetchLogEntry.Outcome.init) ?? .ok
            write(
                """
                INSERT INTO fetch_log (source_id, at, outcome, http_status, error, requests, items, added, changed,
                    closed, ms)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(source), row["at"], .text(outcome.rawValue), row["http_status"], row["error"],
                    SQLValue(row.int("requests") ?? 1), SQLValue(row.int("items") ?? 0),
                    SQLValue(row.int("added") ?? 0),
                    SQLValue(row.int("changed") ?? 0), SQLValue(row.int("closed") ?? 0), SQLValue(row.int("ms") ?? 0),
                ])
        }
        let recent = now.addingTimeInterval(-.days(2))
        for row in old.keyCalls where (row.date("at") ?? .distantPast) >= recent {
            let outcome: AICall.Outcome =
                switch row.string("outcome") {
                case "answered": .ok
                case "used_up": .usedUp
                default: .failed
                }
            write(
                """
                INSERT INTO ai_call (at, task, provider, key_name, model, prompt_version, outcome, input_tokens,
                    output_tokens, ms, daily_limit, back_at)
                VALUES (?, 'imported', ?, ?, ?, 0, ?, ?, ?, 0, ?, ?)
                """,
                [
                    row["at"], .text(row.string("provider") ?? ""), row["key_name"], .text(row.string("model") ?? ""),
                    .text(outcome.rawValue), row["input_tokens"], row["output_tokens"], row["daily_limit"],
                    row["back_at"],
                ])
        }
        for row in old.leads {
            guard let id = row.string("id"), let company = row.string("company") else { continue }
            write(
                """
                INSERT INTO lead (id, company, title, location, posted_at, first_seen_at, last_seen_at)
                VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (id) DO NOTHING
                """,
                [
                    .text(id), .text(company), .text(row.string("title") ?? ""), .text(row.string("location") ?? ""),
                    row["posted_at"], row["first_seen_at"], row["last_seen_at"],
                ])
            report.leads += 1
        }
        for row in old.lookups {
            guard let key = row.string("name_key") else { continue }
            write(
                "INSERT INTO company_lookup (name_key, kind, slug, checked_at) VALUES (?, ?, ?, ?) ON CONFLICT (name_key) DO NOTHING",
                [.text(key), row["kind"], row["slug"], row["checked_at"]])
        }
        var turns: [String: Int64] = [:]
        for row in old.turns {
            guard let key = row.string("key"), let at = row.int64("last_at") else { continue }
            turns[key] = max(turns[key] ?? 0, at)
        }
        for (key, at) in turns {
            write("INSERT INTO search_turn (key, last_at) VALUES (?, ?)", [.text(key), .integer(at)])
        }
    }
}
