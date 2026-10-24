import Foundation
import JobSources
import Store

/// Where jobs come from and how complete they are (job collection v2, J8): the answer to "is
/// Kairos finding everything, and from where?". Read-only; `Kairos --coverage-report` prints it.
public struct CoverageReport: Sendable, Equatable {
    /// One kind of source, with how it was added.
    public struct Line: Sendable, Equatable {
        public let kind: SourceKind
        public var sources = 0
        public var paused = 0
        public var gone = 0
        /// Open jobs it lists.
        public var open = 0
        /// Requests in the last 7 days, and how they went.
        public var requests = 0
        public var unchanged = 0
        public var failed = 0
    }

    public var lines: [Line]
    /// Sources by how they came: you, Kairos's catalog, a search's company.
    public var byOrigin: [String: Int]
    /// Open jobs by how much of the posting Kairos holds.
    public var openJobs: [DescriptionKind: Int]
    public var closedThisWeek: Int
    public var newThisWeek: Int
    /// Snippets filled in by a full posting, all time.
    public var upgraded: Int
    /// The most common failures this week, with their counts.
    public var failures: [(message: String, count: Int)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.lines == rhs.lines && lhs.byOrigin == rhs.byOrigin && lhs.openJobs == rhs.openJobs
            && lhs.closedThisWeek == rhs.closedThisWeek && lhs.newThisWeek == rhs.newThisWeek
            && lhs.upgraded == rhs.upgraded && lhs.failures.map(\.message) == rhs.failures.map(\.message)
    }

    public static func load(from db: Database, now: Date = Date()) async throws -> CoverageReport {
        let week = SQLValue(now.addingTimeInterval(-7 * 86_400))
        let sources = try await SourceRepository(db).sources()
        let open = try await ListingRepository(db).openCounts()
        var lines: [SourceKind: Line] = [:]
        var byOrigin: [String: Int] = [:]
        var kindOf: [UUID: SourceKind] = [:]
        for source in sources {
            kindOf[source.id] = source.kind
            var line = lines[source.kind] ?? Line(kind: source.kind)
            line.sources += 1
            if !source.enabled { line.paused += 1 }
            if source.health == .gone { line.gone += 1 }
            line.open += open[source.id] ?? 0
            lines[source.kind] = line
            let origin = BoardConfig.decode(source.config)?.origin ?? (source.kind.isSearch ? "search engine" : "you")
            byOrigin[origin, default: 0] += 1
        }
        for row in try await db.query(
            """
            SELECT source_id, SUM(requests) AS requests, SUM(outcome = 'unchanged') AS unchanged,
                SUM(outcome = 'failed') AS failed
            FROM fetch_log WHERE at >= ? GROUP BY source_id
            """, [week])
        {
            guard let id = row.string("source_id").flatMap(UUID.init(uuidString:)), let kind = kindOf[id] else {
                continue
            }
            lines[kind]?.requests += row.int("requests") ?? 0
            lines[kind]?.unchanged += row.int("unchanged") ?? 0
            lines[kind]?.failed += row.int("failed") ?? 0
        }
        var openJobs: [DescriptionKind: Int] = [:]
        for row in try await db.query(
            "SELECT description_kind, COUNT(*) AS n FROM job WHERE deleted = 0 AND closed_at IS NULL GROUP BY description_kind"
        ) {
            if let kind = row.string("description_kind").flatMap(DescriptionKind.init) { openJobs[kind] = row.int("n") }
        }
        func count(_ sql: String, _ values: [SQLValue] = []) async throws -> Int {
            try await db.query(sql, values).first?.int("n") ?? 0
        }
        let failures = try await db.query(
            """
            SELECT error, COUNT(*) AS n FROM fetch_log WHERE outcome = 'failed' AND at >= ? AND error IS NOT NULL
            GROUP BY error ORDER BY n DESC, error LIMIT 5
            """, [week]
        ).map { (message: $0.string("error") ?? "", count: $0.int("n") ?? 0) }
        return CoverageReport(
            lines: lines.values.sorted { ($0.open, $0.kind.rawValue) > ($1.open, $1.kind.rawValue) },
            byOrigin: byOrigin, openJobs: openJobs,
            closedThisWeek: try await count(
                "SELECT COUNT(*) AS n FROM job_event WHERE kind = 'closed' AND deleted = 0 AND at >= ?", [week]),
            newThisWeek: try await count(
                "SELECT COUNT(*) AS n FROM job_event WHERE kind = 'found' AND deleted = 0 AND at >= ?", [week]),
            upgraded: try await count("SELECT COUNT(*) AS n FROM job_event WHERE kind = 'upgraded' AND deleted = 0"),
            failures: failures)
    }

    /// The report as plain text, one fact a line.
    public var text: String {
        let total = openJobs.values.reduce(0, +)
        let full = openJobs[.full] ?? 0
        var out = [
            "Open jobs: \(total) (\(full) with the full posting, \(openJobs[.snippet] ?? 0) snippets, \(openJobs[.none] ?? 0) without text)",
            "This week: \(newThisWeek) new, \(closedThisWeek) closed; snippets filled in, all time: \(upgraded)",
            "Sources by origin: "
                + byOrigin.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "),
            "",
            "By kind (sources, open jobs, requests this week: unchanged, failed):",
        ]
        for line in lines {
            var notes: [String] = []
            if line.paused > 0 { notes.append("\(line.paused) paused") }
            if line.gone > 0 { notes.append("\(line.gone) gone") }
            out.append(
                "  \(line.kind.rawValue): \(line.sources) sources, \(line.open) open, \(line.requests) requests "
                    + "(\(line.unchanged) unchanged, \(line.failed) failed)"
                    + (notes.isEmpty ? "" : " · " + notes.joined(separator: ", ")))
        }
        if !failures.isEmpty {
            out.append("")
            out.append("Most common failures this week:")
            out += failures.map { "  \($0.count) × \($0.message)" }
        }
        return out.joined(separator: "\n")
    }
}
