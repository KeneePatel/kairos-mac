import Foundation
import Store

/// Companies' public job boards with jobs in Canada or the US (job collection v2, J5): found by
/// `scripts/discover-boards.py` from Common Crawl's URL index, each checked against its ATS, and
/// bundled with the app. The app never crawls; a release refreshes the catalog.
public struct BoardCatalog: Sendable, Equatable {
    public struct Board: Sendable, Equatable, Codable {
        /// A `SourceKind` raw value.
        public let kind: String
        public let slug: String
        public let name: String
        /// Jobs it listed in Canada and in the US when checked.
        public let ca: Int
        public let us: Int
        public let jobs: Int
        /// "eu" for Lever's EU instance.
        public let region: String?

        public init(kind: String, slug: String, name: String, ca: Int, us: Int, jobs: Int, region: String? = nil) {
            self.kind = kind
            self.slug = slug
            self.name = name
            self.ca = ca
            self.us = us
            self.jobs = jobs
            self.region = region
        }

        public var sourceKind: SourceKind? {
            SourceKind(rawValue: kind).flatMap { SourceKind.boards.contains($0) ? $0 : nil }
        }

        public func lists(in countries: [Country]) -> Bool {
            (countries.contains(.canada) && ca > 0) || (countries.contains(.unitedStates) && us > 0)
        }

        /// What a source for it stores.
        public var config: BoardConfig { BoardConfig(slug: slug, company: name, region: region, origin: "catalog") }
    }

    /// The day the boards were checked.
    public let checked: String
    public let boards: [Board]

    public init(checked: String, boards: [Board]) {
        self.checked = checked
        self.boards = boards
    }

    /// The catalog that ships with Kairos.
    public static let bundled: BoardCatalog = {
        guard let url = Bundle.module.url(forResource: "boards", withExtension: "json", subdirectory: "Catalog"),
            let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(File.self, from: data)
        else { return BoardCatalog(checked: "", boards: []) }
        return BoardCatalog(checked: catalog.checked, boards: catalog.boards)
    }()

    private struct File: Decodable {
        let checked: String
        let boards: [Board]
    }

    /// The boards with jobs in any of `countries`, of the kinds Kairos reads.
    public func boards(in countries: [Country]) -> [Board] {
        boards.filter { $0.sourceKind != nil && $0.lists(in: countries) }
    }
}
