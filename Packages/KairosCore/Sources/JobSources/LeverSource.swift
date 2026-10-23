import Foundation

/// A company's Lever job site, through the public postings API (no key). Companies hosted in the
/// EU are on Lever's EU instance (`jobs.eu.lever.co`, `api.eu.lever.co`).
public struct LeverSource: JobSource {
    public let id: SourceID
    let slug: String
    /// "eu" for Lever's EU instance; nil for the global one.
    let region: String?
    let http: any HTTPClient

    public init(id: SourceID, slug: String, region: String? = nil, http: any HTTPClient) {
        self.id = id
        self.slug = slug
        self.region = region
        self.http = http
    }

    public var listsEverything: Bool { true }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard case .postings(let postings, _) = try await fetch(query, since: nil) else { return [] }
        return postings
    }

    public func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        let host = region == "eu" ? "api.eu.lever.co" : "api.lever.co"
        guard BoardSlug.isValid(slug), let url = URL(string: "https://\(host)/v0/postings/\(slug)?mode=json")
        else {
            throw SourceError.invalidConfiguration("Lever company slug: \(slug)")
        }
        let (answer, etag) = try await http.getJSON(url, as: [LeverPosting].self, ifNoneMatch: memo?.etag)
        guard let postings = answer else { return .unchanged }
        return .postings(self.postings(postings, query), memo: FetchMemo(etag: etag))
    }

    private func postings(_ postings: [LeverPosting], _ query: SourceQuery) -> [Posting] {
        postings.map { posting in
            let location = posting.categories.location ?? ""
            return Posting(
                sourceID: id,
                url: posting.hostedUrl,
                company: query.companyName ?? slug,
                title: posting.text,
                location: location,
                postedAt: posting.createdAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                descriptionHTML: posting.fullDescriptionHTML,
                otherLocations: (posting.categories.allLocations ?? []).filter { $0 != location },
                countryHint: posting.country,
                workplace: posting.workplace
            )
        }
    }
}

struct LeverPosting: Decodable {
    struct Categories: Decodable {
        let location: String?
        let allLocations: [String]?
    }
    /// A titled section, usually requirements or responsibilities; `content` is `<li>` items.
    struct Section: Decodable {
        let text: String
        let content: String
    }
    let text: String
    let hostedUrl: URL
    /// Milliseconds since 1970, unlike the ISO dates other boards send.
    let createdAt: Int64?
    let categories: Categories
    let country: String?
    /// "onsite", "hybrid", "remote" or "unspecified".
    let workplaceType: String?
    let description: String?
    let lists: [Section]?
    let additional: String?

    /// Lever writes "on-site" (its docs, 2026-10-23); "onsite" is taken too.
    var workplace: Workplace? {
        switch workplaceType?.lowercased() {
        case "on-site", "onsite": .onsite
        case "hybrid": .hybrid
        case "remote": .remote
        default: nil
        }
    }

    /// Lever splits a posting into an intro, titled lists and a closing note. Screening needs the
    /// lists most (they hold the requirements), so all three are joined in page order.
    var fullDescriptionHTML: String {
        var html = description ?? ""
        for section in lists ?? [] {
            // The title is plain text; the content is already HTML.
            let title = section.text.replacing("&", with: "&amp;").replacing("<", with: "&lt;")
                .replacing(">", with: "&gt;")
            html += "<h3>\(title)</h3><ul>\(section.content)</ul>"
        }
        return html + (additional ?? "")
    }
}
