import Foundation

/// A company's Personio job page, through its public XML feed (`{company}.jobs.personio.de/xml`,
/// no key; job collection v2, J2). Every published job, with its text sections, in one answer,
/// and an ETag. A name that isn't a Personio customer redirects to personio.com: that's "not
/// found", never an empty board.
public struct PersonioSource: JobSource {
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
        let host = "\(company).jobs.personio.de"
        guard BoardSlug.isValid(company), let url = URL(string: "https://\(host)/xml?language=en") else {
            throw SourceError.invalidConfiguration("Personio company: \(company)")
        }
        var request = URLRequest(url: url)
        if let etag = memo?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await http.data(for: request)
        if response.statusCode == 304 { return .unchanged }
        // URLSession follows the redirect to personio.com; a client that doesn't sees the 3xx.
        guard response.url?.host() == host, !(300..<400).contains(response.statusCode) else {
            throw SourceError.notFound(endpoint: SourceError.endpoint(of: url))
        }
        try HTTPClientChecks.check(response)
        let root = try XMLElement.parse(data)
        let postings = root.all("position").compactMap { position -> Posting? in
            guard let id = position.value("id"), let title = position.value("name"),
                let link = URL(string: "https://\(host)/job/\(id)")
            else { return nil }
            let text = position.child("jobDescriptions")?.all("jobDescription").map { section in
                (section.value("name").map { "<h3>\(HTMLEntities.escape($0))</h3>" } ?? "")
                    + (section.value("value") ?? "")
            }.joined()
            let offices =
                [position.value("office")]
                + (position.child("additionalOffices")?.all("office").map {
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                } ?? [])
            let places = offices.compactMap { $0 }.filter { !$0.isEmpty }
            return Posting(
                sourceID: self.id, url: link, company: query.companyName ?? position.value("subcompany") ?? company,
                title: title, location: places.first ?? "", postedAt: SourceDates.parse(position.value("createdAt")),
                descriptionHTML: text ?? "", otherLocations: Array(places.dropFirst()))
        }
        return .postings(postings, memo: FetchMemo(etag: response.value(forHTTPHeaderField: "ETag")))
    }
}

/// `HTTPClient`'s status rules, for sources that read the response themselves.
enum HTTPClientChecks {
    static func check(_ response: HTTPURLResponse) throws(SourceError) {
        try URLSessionHTTPClient.check(response)
    }
}
