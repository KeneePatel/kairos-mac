import Foundation

/// A company's SmartRecruiters board, through its public postings API (no key; job collection v2,
/// J2). The list has titles and places but no text, so each job's text is one more request:
/// asked only for jobs at your roles that Kairos doesn't already have. Kairos covers Canada and
/// the US, so the list is asked per country (`country=ca`, `country=us`), 100 a page.
public struct SmartRecruitersSource: JobSource {
    public let id: SourceID
    /// The company identifier, case-sensitive: "Ubisoft2", "BoschGroup".
    let company: String
    let http: any HTTPClient

    static let pageSize = 100
    /// A board this large is unusual; the cap keeps one company from taking over a fetch.
    static let maxPages = 20

    public init(id: SourceID, company: String, http: any HTTPClient) {
        self.id = id
        self.company = company
        self.http = http
    }

    public var listsEverything: Bool { true }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard BoardSlug.isValid(company) else {
            throw SourceError.invalidConfiguration("SmartRecruiters company: \(company)")
        }
        var postings: [Posting] = []
        for country in ["ca", "us"] {
            var offset = 0
            for _ in 0..<Self.maxPages {
                guard
                    let url = URL(
                        string:
                            "https://api.smartrecruiters.com/v1/companies/\(company)/postings?limit=\(Self.pageSize)&offset=\(offset)&country=\(country)"
                    )
                else { break }
                let page = try await http.getJSON(url, as: SmartRecruitersPage.self)
                for item in page.content {
                    if let posting = await posting(item, query) { postings.append(posting) }
                }
                offset += page.content.count
                if page.content.isEmpty || offset >= page.totalFound { break }
            }
        }
        return postings
    }

    /// The text is asked for only when it's a job you'd want and Kairos doesn't have it yet; a
    /// failed ask leaves it for the next fetch.
    private func posting(_ item: SmartRecruitersPage.Item, _ query: SourceQuery) async -> Posting? {
        // The id alone opens the posting, and stays the same when its title changes.
        guard let url = URL(string: "https://jobs.smartrecruiters.com/\(company)/\(item.id)") else { return nil }
        let location =
            item.location.fullLocation
            ?? [item.location.city, item.location.region].compactMap { $0 }
            .joined(separator: ", ")
        var posting = Posting(
            sourceID: id, url: url,
            company: query.companyName ?? item.company?.name ?? company, title: item.name, location: location,
            postedAt: item.releasedDate, descriptionHTML: "", countryHint: item.location.country?.uppercased(),
            workplace: item.location.remote == true ? .remote : item.location.hybrid == true ? .hybrid : nil,
            textOmitted: true)
        let known = query.knownURLs.contains(URLCanonicalizer.canonical(url))
        let wanted = query.roles.map { $0.matches(item.name) } ?? true
        guard !known, wanted,
            let detail = URL(string: "https://api.smartrecruiters.com/v1/companies/\(company)/postings/\(item.id)"),
            let full = try? await http.getJSON(detail, as: SmartRecruitersPosting.self)
        else { return posting }
        posting.descriptionHTML = full.jobAd.sections.html
        posting.textOmitted = false
        return posting
    }
}

struct SmartRecruitersPage: Decodable {
    struct Item: Decodable {
        struct Company: Decodable { let name: String? }
        struct Location: Decodable {
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

            /// The job, then what it asks for, then the rest, then the company: the requirements
            /// matter most to screening.
            var html: String {
                [jobDescription, qualifications, additionalInformation, companyDescription].compactMap { section in
                    guard let section, let text = section.text, !text.isEmpty else { return nil }
                    let title = section.title.map { "<h3>\(HTMLEntities.escape($0))</h3>" } ?? ""
                    return title + text
                }.joined()
            }
        }
        let sections: Sections
    }
    let jobAd: JobAd
}
