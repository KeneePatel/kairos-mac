import Foundation
import JobSources
import Store

/// Watching Kairos's board catalog (job collection v2, J5; the owner's decision of 2026-10-23):
/// every board in the catalog with jobs in your countries is a source, added before a fetch. A
/// board you removed is never added back; one you paused stays paused.
public struct CatalogWatch: Sendable {
    public let catalog: BoardCatalog
    public let countries: [Country]

    public init(catalog: BoardCatalog, countries: [Country]) {
        self.catalog = catalog
        self.countries = countries
    }

    /// Adds the catalog's boards in your countries that aren't sources yet. Returns how many.
    @discardableResult
    public func sync(_ db: Database) async throws -> Int {
        let repository = SourceRepository(db)
        let known = Set(
            try await repository.everySource().compactMap { source -> String? in
                guard SourceKind.boards.contains(source.kind), let config = BoardConfig.decode(source.config) else {
                    return nil
                }
                return BoardConfig.key(kind: source.kind, slug: config.slug)
            })
        var seen = known
        let missing = catalog.boards(in: countries).compactMap { board -> (kind: SourceKind, config: String)? in
            guard let kind = board.sourceKind, seen.insert(BoardConfig.key(kind: kind, slug: board.slug)).inserted
            else { return nil }
            return (kind, board.config.json)
        }
        return missing.isEmpty ? 0 : try await repository.add(missing)
    }
}
