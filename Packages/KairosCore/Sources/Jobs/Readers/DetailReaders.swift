import Foundation
import KairosKit

/// A company's SmartRecruiters board, through its public postings API (no key). The list has
/// titles and places but no text, so each job's text is one more request: asked only for new jobs
/// at your roles. Kairos covers Canada and the US, so the list is asked per country, 100 a page.
public struct SmartRecruitersReader: JobReader {
    let board: Board
    let http: any HTTPClient

    static let pageSize = 100
    /// A board this large is unusual; the cap keeps one company from taking over a fetch.
    static let maxPages = 20

    public init(board: Board, http: any HTTPClient) {
        self.board = board
        self.http = http
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        let company = board.slug
        guard BoardSlug.isValid(company) else { throw .invalidConfiguration("SmartRecruiters company: \(company)") }
        var items: [SmartRecruitersPage.Item] = []
        var requests = 0
        for country in request.countries.map({ $0.rawValue.lowercased() }) {
            var offset = 0
            for _ in 0..<Self.maxPages {
                guard
                    let url = URL(
                        string:
                            "https://api.smartrecruiters.com/v1/companies/\(company)/postings?limit=\(Self.pageSize)&offset=\(offset)&country=\(country)"
                    )
                else { break }
                requests += 1
                let page: SmartRecruitersPage = try await http.getJSON(url, as: SmartRecruitersPage.self)
                items += page.content
                offset += page.content.count
                if page.content.isEmpty || offset >= page.totalFound { break }
            }
        }
        let listed = items.compactMap { item -> (SmartRecruitersPage.Item, Posting)? in
            // The id alone opens the posting, and stays the same when its title changes.
            guard let url = URL(string: "https://jobs.smartrecruiters.com/\(company)/\(item.id)") else { return nil }
            let location =
                item.location.fullLocation
                ?? [item.location.city, item.location.region].compactMap { $0 }.joined(separator: ", ")
            let posting = Posting(
                url: url, company: board.name.isEmpty ? (item.company?.name ?? company) : board.name, title: item.name,
                location: location, postedAt: item.releasedDate, countryHint: item.location.country?.uppercased(),
                workplace: item.location.remote == true ? .remote : item.location.hybrid == true ? .hybrid : nil,
                textOmitted: true)
            return (item, posting)
        }
        let http = http
        let postings = await concurrentMap(listed, limit: 4) { item, posting -> Posting in
            let known = request.knownURLs.contains(URLCanonicalizer.canonical(posting.url))
            guard !known, request.roles.matches(item.name),
                let detail = URL(string: "https://api.smartrecruiters.com/v1/companies/\(company)/postings/\(item.id)"),
                let full = try? await http.getJSON(detail, as: SmartRecruitersPosting.self)
            else { return posting }
            var withText = posting
            withText.descriptionHTML = full.jobAd.sections.html
            withText.textOmitted = false
            return withText
        }
        let detailed = postings.filter { !$0.textOmitted }.count
        return ReadResult(postings: postings, requests: requests + detailed, complete: true)
    }
}

struct SmartRecruitersPage: Decodable {
    struct Item: Decodable, Sendable {
        struct Company: Decodable, Sendable { let name: String? }
        struct Location: Decodable, Sendable {
            let city: String?
            let region: String?
            let country: String?
            let remote: Bool?
            let hybrid: Bool?
            let fullLocation: String?
        }
        let id: String
        let name: String
        let company: Company?
        let releasedDate: Date?
        let location: Location
    }
    let totalFound: Int
    let content: [Item]
}

struct SmartRecruitersPosting: Decodable {
    struct JobAd: Decodable {
        struct Section: Decodable {
            let title: String?
            let text: String?
        }
        struct Sections: Decodable {
            let companyDescription: Section?
            let jobDescription: Section?
            let qualifications: Section?
            let additionalInformation: Section?

            /// The job, then what it asks for, then the rest, then the company: requirements
            /// matter most to screening.
            var html: String {
                [jobDescription, qualifications, additionalInformation, companyDescription].compactMap { section in
                    guard let section, let text = section.text, !text.isEmpty else { return nil }
                    return (section.title.map { "<h3>\(HTMLEntities.escape($0))</h3>" } ?? "") + text
                }.joined()
            }
        }
        let sections: Sections
    }
    let jobAd: JobAd
}

/// A company's BambooHR careers page, through its public JSON (no key). The list has titles and
/// places but no text, so each job's text is one more request: asked only for new jobs at your
/// roles. A name that isn't a BambooHR customer redirects to bamboohr.com: that's "not found".
public struct BambooHRReader: JobReader {
    let board: Board
    let http: any HTTPClient

    public init(board: Board, http: any HTTPClient) {
        self.board = board
        self.http = http
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        let host = "\(board.slug).bamboohr.com"
        guard BoardSlug.isValid(board.slug), let url = URL(string: "https://\(host)/careers/list") else {
            throw .invalidConfiguration("BambooHR company: \(board.slug)")
        }
        let response = try await http.fetch(.json(url))
        guard response.url.host() == host else { throw .notFound(endpoint: endpoint(of: url)) }
        let list: BambooHRList
        do {
            list = try JSONDecoder.snakeCase().decode(BambooHRList.self, from: response.body)
        } catch {
            throw .decoding("BambooHR list")
        }
        let company = board.name.isEmpty ? board.slug : board.name
        let listed = list.result.compactMap { item -> Posting? in
            guard let link = URL(string: "https://\(host)/careers/\(item.id)") else { return nil }
            let place = item.atsLocation
            return Posting(
                url: link, company: company, title: item.jobOpeningName,
                location: [
                    place?.city ?? item.location?.city, place?.state ?? place?.province ?? item.location?.state,
                    place?.country,
                ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                countryHint: place?.country,
                workplace: item.isRemote == true || item.locationType == "1" ? .remote : nil, textOmitted: true)
        }
        let http = http
        let postings = await concurrentMap(listed, limit: 4) { posting -> Posting in
            let known = request.knownURLs.contains(URLCanonicalizer.canonical(posting.url))
            guard !known, request.roles.matches(posting.title),
                let detail = URL(string: posting.url.absoluteString + "/detail"),
                let opening = try? await http.getJSON(detail, as: BambooHRDetail.self).result.jobOpening
            else { return posting }
            var withText = posting
            withText.descriptionHTML = opening.description ?? ""
            withText.postedAt = opening.datePosted.flatMap(ISODate.parse)
            withText.textOmitted = false
            return withText
        }
        let detailed = postings.filter { !$0.textOmitted }.count
        return ReadResult(postings: postings, requests: 1 + detailed, complete: true)
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
