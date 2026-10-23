import Foundation

/// A company's Recruitee careers site, through its public Careers Site API
/// (`{company}.recruitee.com/api/offers/`, no key; job collection v2, J2). Every published job,
/// with its text and requirements, in one answer.
public struct RecruiteeSource: JobSource {
    public let id: SourceID
    let company: String
    let http: any HTTPClient

    public init(id: SourceID, company: String, http: any HTTPClient) {
        self.id = id
        self.company = company
        self.http = http
    }

    public var listsEverything: Bool { true }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard BoardSlug.isValid(company), let url = URL(string: "https://\(company).recruitee.com/api/offers/") else {
            throw SourceError.invalidConfiguration("Recruitee company: \(company)")
        }
        let board = try await http.getJSON(url, as: RecruiteeBoard.self)
        return board.offers.compactMap { offer in
            guard let link = URL(string: offer.careersUrl) else { return nil }
            let others = (offer.locations ?? []).dropFirst().map { location in
                [location.city, location.state, location.country].compactMap { $0 }.joined(separator: ", ")
            }
            return Posting(
                sourceID: id, url: link, company: query.companyName ?? offer.companyName ?? company, title: offer.title,
                location: offer.location ?? [offer.city, offer.country].compactMap { $0 }.joined(separator: ", "),
                postedAt: SourceDates.parse(offer.publishedAt ?? offer.createdAt),
                // What it asks for is a section of its own on Recruitee.
                descriptionHTML: (offer.description ?? "")
                    + (offer.requirements.map { $0.isEmpty ? "" : "<h3>Requirements</h3>" + $0 } ?? ""),
                otherLocations: Array(others), countryHint: offer.countryCode ?? offer.country,
                workplace: offer.remote == true
                    ? .remote : offer.hybrid == true ? .hybrid : offer.onSite == true ? .onsite : nil)
        }
    }
}

struct RecruiteeBoard: Decodable {
    struct Offer: Decodable {
        struct Location: Decodable {
            let city: String?
            let state: String?
            let country: String?
        }
        let title: String
        let careersUrl: String
        let companyName: String?
        let location: String?
        let city: String?
        let country: String?
        let countryCode: String?
        let locations: [Location]?
        let remote: Bool?
        let hybrid: Bool?
        let onSite: Bool?
        let publishedAt: String?
        let createdAt: String?
        let description: String?
        let requirements: String?
    }
    let offers: [Offer]
}
