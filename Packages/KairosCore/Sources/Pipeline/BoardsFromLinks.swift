import Foundation
import JobSources
import Store

/// Companies found behind a search's links (job collection v3, C1): a Google Jobs result or a
/// Himalayas job that links to a board Kairos reads names a company whose every posting it can
/// then read in full. A board found becomes a source (origin: the search's kind) and is read in
/// the same fetch. A board you removed is never added back; aggregators and agencies never count.
public enum BoardsFromLinks {
    public struct Found: Hashable, Sendable {
        public let kind: SourceKind
        public let slug: String
        public let company: String
        public let region: String?

        public var key: String { BoardConfig.key(kind: kind, slug: slug) }
    }

    /// The boards the postings' links point at, each once, in the order found.
    public static func boards(in postings: [Posting]) -> [Found] {
        var found: [Found] = []
        var keys: Set<String> = []
        for posting in postings where !BoardCatalog.isAggregator(posting.company) {
            for link in [posting.url] + (posting.applyURL.map { [$0] } ?? []) + posting.links {
                guard case .detected(let kind, let slug) = ATSDetector.detect(link.absoluteString) else { continue }
                let board = Found(
                    kind: kind, slug: slug, company: posting.company,
                    region: ATSDetector.leverRegion(link.absoluteString))
                if keys.insert(board.key).inserted { found.append(board) }
            }
        }
        return found
    }

    /// Adds the boards that aren't sources yet (a removed one stays removed) and returns them.
    public static func add(_ boards: [Found], via kind: SourceKind, to db: Database) async throws -> [Source] {
        let repository = SourceRepository(db)
        var known = Set(
            try await repository.everySource().compactMap { source -> String? in
                guard SourceKind.boards.contains(source.kind), let config = BoardConfig.decode(source.config) else {
                    return nil
                }
                return BoardConfig.key(kind: source.kind, slug: config.slug)
            })
        var added: [Source] = []
        for board in boards where known.insert(board.key).inserted {
            let config = BoardConfig(
                slug: board.slug, company: board.company, region: board.region, origin: kind.rawValue)
            added.append(try await repository.add(kind: board.kind, config: config.json))
        }
        return added
    }
}
