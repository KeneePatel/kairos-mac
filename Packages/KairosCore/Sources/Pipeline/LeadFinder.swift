import Foundation
import JobSources
import Store

/// Finds companies' boards behind a search's leads (job collection v3, C2; v2's snippet finder
/// before). Adzuna names the companies posting at your roles but sends only a snippet of each
/// posting, which Kairos no longer keeps; the same postings are often on the company's public
/// board, in full. For the companies behind the newest leads it looks for a board: in Kairos's
/// catalog, among your sources, then by trying the name's slugs. A board found is added as a
/// source (origin "search") for the fetch to read now. Each company is looked up once, and again
/// a month later when nothing was found.
public struct LeadFinder: Sendable {
    /// Companies looked up per fetch: at most a few hundred requests, spread over the fetches.
    public static let perRun = 60
    /// A company with no board found is looked up again after this long.
    public static let recheckAfter: TimeInterval = 30 * 86_400
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

    /// Looks up the companies behind the leads that weren't looked up lately, newest first, and
    /// returns the boards it added as sources.
    public func findBoards() async -> [Source] {
        let sources = SourceRepository(db)
        guard let companies = try? await LeadRepository(db).companies(), let every = try? await sources.everySource()
        else { return [] }
        let rows = companies.map(\.company).filter { $0 != "Company not listed" }
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
        for name in rows {
            guard looked < Self.perRun else { break }
            let key = Self.key(name)
            guard !key.isEmpty, byCompany[key] == nil, !BoardCatalog.isAggregator(name) else { continue }
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
