import Foundation
import JobSources
import Store

/// Fills in search snippets from companies' own boards (job collection v2, J6). Adzuna sends 500
/// characters of a posting and Kairos never opens its paid advert link; but the same posting is
/// often on the company's public board, in full (2026-10-23: about a quarter of Adzuna's
/// companies). For the companies behind open snippet jobs, newest first, it looks for a board:
/// in Kairos's catalog, among your sources, then by trying the name's slugs. A board found is
/// added as a source (origin "search") for the fetch to read now; the ledger then attaches each
/// copy to its job, and the full posting replaces the snippet.
public struct SnippetFinder: Sendable {
    /// Companies looked up per fetch: a few dozen requests at most.
    public static let perRun = 20
    /// A company with no board found is looked up again after this long.
    public static let recheckAfter: TimeInterval = 30 * 86_400
    /// Job sites and staffing marketplaces that appear as the "company" in search results: their
    /// boards repost other companies' jobs, so they aren't looked up (2026-10-23: one added 207).
    static let aggregators: Set<String> = [
        "jobgether", "jooble", "talent", "lensa", "dice", "ziprecruiter", "indeed", "linkedin", "glassdoor",
        "monster", "careerbuilder", "remote rocketship", "jobot", "turing", "crossover", "toptal", "hired",
        "recruit net", "jobs for humanity", "clickjobs", "adzuna", "workopolis", "eluta",
    ]

    let db: Database
    let probe: BoardProbe
    let catalog: BoardCatalog
    let now: @Sendable () -> Date

    public init(
        db: Database, probe: BoardProbe, catalog: BoardCatalog, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = db
        self.probe = probe
        self.catalog = catalog
        self.now = now
    }

    /// A company name folded for comparing: "Syndio Inc." and "syndio" are one company.
    public static func key(_ name: String) -> String {
        String(DedupKey.company(of: DedupKey.make(company: name, title: "", city: nil)))
    }

    /// Looks up the companies of open snippet jobs that weren't looked up lately, and returns the
    /// boards it added as sources.
    public func findBoards() async -> [Source] {
        let sources = SourceRepository(db)
        guard
            let rows = try? await db.query(
                """
                SELECT company, MAX(first_seen_at) AS newest FROM job
                WHERE deleted = 0 AND closed_at IS NULL AND description_kind = 'snippet' AND company != 'Company not listed'
                GROUP BY company ORDER BY newest DESC
                """),
            let every = try? await sources.everySource()
        else { return [] }
        var boards: [String: Source] = [:]
        var byCompany: [String: (SourceKind, String)] = [:]
        for source in every where SourceKind.boards.contains(source.kind) {
            guard let config = BoardConfig.decode(source.config) else { continue }
            boards[BoardConfig.key(kind: source.kind, slug: config.slug)] = source
            if let company = config.company { byCompany[Self.key(company)] = (source.kind, config.slug) }
        }
        let fromCatalog = Dictionary(
            catalog.boards.compactMap { board in board.sourceKind.map { (Self.key(board.name), ($0, board.slug)) } },
            uniquingKeysWith: { first, _ in first })

        var added: [Source] = []
        var looked = 0
        for row in rows {
            guard looked < Self.perRun, let name = row.string("company") else { break }
            let key = Self.key(name)
            guard !key.isEmpty, byCompany[key] == nil, !Self.aggregators.contains(key) else { continue }
            if let lookup = try? await db.query("SELECT * FROM company_lookup WHERE name_key = ?", [.text(key)]).first {
                let checked = lookup.int64("checked_at").map(Date.init(milliseconds:)) ?? .distantPast
                if lookup.string("kind") != nil || now().timeIntervalSince(checked) < Self.recheckAfter { continue }
            }
            looked += 1
            let found: (SourceKind, String)? =
                if let known = fromCatalog[key] { known } else { await probe.find(name).map { ($0.kind, $0.slug) } }
            try? await db.execute(
                """
                INSERT INTO company_lookup (name_key, kind, slug, checked_at) VALUES (?, ?, ?, ?)
                ON CONFLICT (name_key) DO UPDATE SET kind = excluded.kind, slug = excluded.slug,
                    checked_at = excluded.checked_at
                """, [.text(key), SQLValue(found?.0.rawValue), SQLValue(found?.1), SQLValue(now())])
            guard let (kind, slug) = found else { continue }
            byCompany[key] = (kind, slug)
            // A board you removed stays removed; one already watched is read anyway.
            guard boards[BoardConfig.key(kind: kind, slug: slug)] == nil else { continue }
            let config = BoardConfig(slug: slug, company: name, origin: "search").json
            if let source = try? await sources.add(kind: kind, config: config) {
                boards[BoardConfig.key(kind: kind, slug: slug)] = source
                added.append(source)
            }
        }
        return added
    }
}
