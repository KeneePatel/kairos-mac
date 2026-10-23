import Foundation

/// A company's Ashby job board, through the public posting API (no key).
public struct AshbySource: JobSource {
    public let id: SourceID
    let organization: String
    let http: any HTTPClient

    public init(id: SourceID, organization: String, http: any HTTPClient) {
        self.id = id
        self.organization = organization
        self.http = http
    }

    public var listsEverything: Bool { true }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard case .postings(let postings, _) = try await fetch(query, since: nil) else { return [] }
        return postings
    }

    public func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        guard BoardSlug.isValid(organization),
            let url = URL(string: "https://api.ashbyhq.com/posting-api/job-board/\(organization)")
        else {
            throw SourceError.invalidConfiguration("Ashby organization: \(organization)")
        }
        let (answer, etag) = try await http.getJSON(url, as: AshbyBoard.self, ifNoneMatch: memo?.etag)
        guard let board = answer else { return .unchanged }
        return .postings(postings(board, query), memo: FetchMemo(etag: etag))
    }

    private func postings(_ board: AshbyBoard, _ query: SourceQuery) -> [Posting] {
        // Unlisted jobs are reachable by link only; the company doesn't advertise them.
        board.jobs.filter { $0.isListed ?? true }.map { job in
            Posting(
                sourceID: id,
                url: job.jobUrl,
                company: query.companyName ?? organization,
                title: job.title,
                location: job.location ?? "",
                postedAt: job.publishedAt,
                descriptionHTML: job.descriptionHtml ?? "",
                otherLocations: (job.secondaryLocations ?? []).compactMap(\.location),
                countryHint: job.address?.postalAddress?.addressCountry,
                workplace: job.workplace
            )
        }
    }
}

struct AshbyBoard: Decodable {
    struct Address: Decodable {
        struct PostalAddress: Decodable { let addressCountry: String? }
        let postalAddress: PostalAddress?
    }
    struct SecondaryLocation: Decodable { let location: String? }
    struct Job: Decodable {
        let title: String
        let jobUrl: URL
        let location: String?
        let secondaryLocations: [SecondaryLocation]?
        let address: Address?
        let publishedAt: Date?
        let isListed: Bool?
        let isRemote: Bool?
        /// "OnSite", "Hybrid" or "Remote".
        let workplaceType: String?
        let descriptionHtml: String?

        var workplace: Workplace? {
            switch workplaceType?.lowercased() {
            case "onsite": .onsite
            case "hybrid": .hybrid
            case "remote": .remote
            default: isRemote == true ? .remote : nil
            }
        }
    }
    let jobs: [Job]
}
