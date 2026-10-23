import Foundation

/// A company's BambooHR careers page, through its public JSON (`{company}.bamboohr.com/careers/
/// list`, no key; job collection v2, J2). The list has titles and places but no text, so each
/// job's text is one more request: asked only for jobs at your roles that Kairos doesn't already
/// have. A name that isn't a BambooHR customer redirects to bamboohr.com: "not found".
public struct BambooHRSource: JobSource {
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
        let host = "\(company).bamboohr.com"
        guard BoardSlug.isValid(company), let url = URL(string: "https://\(host)/careers/list") else {
            throw SourceError.invalidConfiguration("BambooHR company: \(company)")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        // URLSession follows the redirect to bamboohr.com; a client that doesn't sees the 3xx.
        guard response.url?.host() == host, !(300..<400).contains(response.statusCode) else {
            throw SourceError.notFound(endpoint: SourceError.endpoint(of: url))
        }
        try HTTPClientChecks.check(response)
        let list: BambooHRList
        do {
            list = try JSONDecoder.sources.decode(BambooHRList.self, from: data)
        } catch {
            throw SourceError.decoding("BambooHR list")
        }
        var postings: [Posting] = []
        for item in list.result {
            guard let link = URL(string: "https://\(host)/careers/\(item.id)") else { continue }
            let place = item.atsLocation
            var posting = Posting(
                sourceID: id, url: link, company: query.companyName ?? company, title: item.jobOpeningName,
                location: [
                    place?.city ?? item.location?.city, place?.state ?? place?.province ?? item.location?.state,
                    place?.country,
                ]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                postedAt: nil, descriptionHTML: "", countryHint: place?.country,
                workplace: item.isRemote == true || item.locationType == "1" ? .remote : nil, textOmitted: true)
            let known = query.knownURLs.contains(URLCanonicalizer.canonical(link))
            let wanted = query.roles.map { $0.matches(item.jobOpeningName) } ?? true
            if !known, wanted, let detail = URL(string: "https://\(host)/careers/\(item.id)/detail"),
                let opening = try? await http.getJSON(detail, as: BambooHRDetail.self).result.jobOpening
            {
                posting.descriptionHTML = opening.description ?? ""
                posting.postedAt = SourceDates.parse(opening.datePosted)
                posting.textOmitted = false
            }
            postings.append(posting)
        }
        return postings
    }
}

struct BambooHRList: Decodable {
    struct Item: Decodable {
        struct Place: Decodable {
            let city: String?
            let state: String?
        }
        struct ATSPlace: Decodable {
            let country: String?
            let state: String?
            let province: String?
            let city: String?
        }
        let id: String
        let jobOpeningName: String
        let location: Place?
        let atsLocation: ATSPlace?
        let isRemote: Bool?
        /// "1" is remote, as its careers page shows it.
        let locationType: String?
    }
    let result: [Item]
}

struct BambooHRDetail: Decodable {
    struct Result: Decodable {
        struct Opening: Decodable {
            let description: String?
            let datePosted: String?
        }
        let jobOpening: Opening
    }
    let result: Result
}
