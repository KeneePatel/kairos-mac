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

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard BoardSlug.isValid(organization),
            let url = URL(string: "https://api.ashbyhq.com/posting-api/job-board/\(organization)")
        else {
            throw SourceError.invalidConfiguration("Ashby organization: \(organization)")
        }
        let board = try await http.getJSON(url, as: AshbyBoard.self)
        // Unlisted jobs are reachable by link only; the company doesn't advertise them.
        return board.jobs.filter { $0.isListed ?? true }.map { job in
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
