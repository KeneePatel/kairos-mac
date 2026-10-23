import Foundation

/// A company's Teamtailor careers site, through its public RSS feed (`{company}.teamtailor.com/
/// jobs.rss`, no key; job collection v2, J2). Every published job, its text and places, in one
/// answer, with an ETag. Companies on their own domain aren't covered yet.
public struct TeamtailorSource: JobSource {
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
        guard case .postings(let postings, _) = try await fetch(query, since: nil) else { return [] }
        return postings
    }

    public func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        guard BoardSlug.isValid(company), let url = URL(string: "https://\(company).teamtailor.com/jobs.rss") else {
            throw SourceError.invalidConfiguration("Teamtailor company: \(company)")
        }
        var request = URLRequest(url: url)
        if let etag = memo?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await http.data(for: request)
        if response.statusCode == 304 { return .unchanged }
        try HTTPClientChecks.check(response)
        let channel = try XMLElement.parse(data).child("channel")
        let postings = (channel?.all("item") ?? []).compactMap { item -> Posting? in
            guard let title = item.value("title"), let link = item.value("link").flatMap(URL.init(string:)) else {
                return nil
            }
            let places =
                item.child("tt:locations")?.all("tt:location").map { location in
                    [location.value("tt:city") ?? location.value("tt:name"), location.value("tt:country")]
                        .compactMap { $0 }.joined(separator: ", ")
                } ?? []
            let remote = item.value("remoteStatus")?.lowercased()
            return Posting(
                sourceID: id, url: link, company: query.companyName ?? channel?.value("title") ?? company, title: title,
                location: places.first ?? "", postedAt: SourceDates.parse(item.value("pubDate")),
                // RSS escapes the HTML once; the XML reader has already undone that.
                descriptionHTML: item.value("description") ?? "", otherLocations: Array(places.dropFirst()),
                countryHint: item.child("tt:locations")?.child("tt:location")?.value("tt:country"),
                workplace: remote == "fully" || remote == "remote" ? .remote : remote == "hybrid" ? .hybrid : nil)
        }
        return .postings(postings, memo: FetchMemo(etag: response.value(forHTTPHeaderField: "ETag")))
    }
}
