import Foundation

/// A company's Lever job site, through the public postings API (no key).
public struct LeverSource: JobSource {
    public let id: SourceID
    let slug: String
    let http: any HTTPClient

    public init(id: SourceID, slug: String, http: any HTTPClient) {
        self.id = id
        self.slug = slug
        self.http = http
    }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard BoardSlug.isValid(slug), let url = URL(string: "https://api.lever.co/v0/postings/\(slug)?mode=json")
        else {
            throw SourceError.invalidConfiguration("Lever company slug: \(slug)")
        }
        let postings = try await http.getJSON(url, as: [LeverPosting].self)
        return postings.map { posting in
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
                workplace: posting.workplaceType.flatMap(Workplace.init(rawValue:))
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
