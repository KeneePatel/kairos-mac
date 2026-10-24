import Foundation
import Store

/// Himalayas, a board of remote jobs, through its public search API (himalayas.app/api; job
/// collection v2, J7). Each of your roles is searched in each of your countries, newest first, with
/// the full text of every job. A free key lifts the limit to 60 a minute and 10,000 a day; without
/// one, requests share a public allowance. Its terms: name Himalayas as the source, use its
/// application link unchanged, show its jobs only in your own app, and drop them once expired.
public struct HimalayasSource: JobSource {
    /// Requests a run makes: Himalayas allows far more, but its jobs change slowly.
    public static let maxCallsPerRun = 30
    static let maxPages = 3

    public let id: SourceID
    let key: String?
    let http: any HTTPClient
    let now: @Sendable () -> Date

    public init(id: SourceID, key: String?, http: any HTTPClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id
        self.key = key.flatMap { $0.isEmpty ? nil : $0 }
        self.http = http
        self.now = now
    }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard case .postings(let postings, _) = try await fetch(query, since: nil) else { return [] }
        return postings
    }

    public func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        let titles = query.titles.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !titles.isEmpty else {
            throw SourceError.invalidConfiguration("Himalayas searches by your roles; choose some in Settings, Search")
        }
        let budget = query.callBudget ?? Self.maxCallsPerRun
        let cutoff = query.maxAgeDays.map { now().addingTimeInterval(-Double($0) * 86_400) }
        var calls = 0
        var seen: Set<String> = []
        var postings: [Posting] = []
        searches: for country in query.countries {
            for title in titles {
                for page in 1...Self.maxPages {
                    guard calls < budget else { break searches }
                    calls += 1
                    let result: HimalayasPage
                    do {
                        result = try await search(title, in: country, page: page)
                    } catch {
                        guard calls > 1, error as? SourceError != .cancelled else { throw error }
                        break searches
                    }
                    var fresh = 0
                    for job in result.jobs where seen.insert(job.guid).inserted {
                        // Expired jobs go, as its terms ask; jobs older than your limit aren't wanted.
                        if let expiry = job.expiryDate, Date(timeIntervalSince1970: expiry) < now() { continue }
                        let posted = job.pubDate.map { Date(timeIntervalSince1970: $0) }
                        if let cutoff, let posted, posted < cutoff { continue }
                        guard let posting = posting(job, country: country, posted: posted) else { continue }
                        if !query.knownURLs.contains(URLCanonicalizer.canonical(posting.url)) { fresh += 1 }
                        postings.append(posting)
                    }
                    if result.jobs.isEmpty || fresh == 0 { break }
                }
            }
        }
        return .postings(postings, memo: FetchMemo(etag: nil, requests: calls))
    }

    private func search(_ title: String, in country: Country, page: Int) async throws -> HimalayasPage {
        var components = URLComponents(string: "https://himalayas.app/jobs/api/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: title), URLQueryItem(name: "country", value: country.rawValue),
            URLQueryItem(name: "sort", value: "recent"), URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components?.url else { throw SourceError.invalidConfiguration("Himalayas search for \(title)") }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await http.data(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw SourceError.invalidConfiguration("Himalayas didn't accept the key; check it in Find jobs, Himalayas")
        }
        try HTTPClientChecks.check(response)
        do {
            return try JSONDecoder().decode(HimalayasPage.self, from: data)
        } catch {
            throw SourceError.decoding("Himalayas search")
        }
    }

    private func posting(_ job: HimalayasPage.Job, country: Country, posted: Date?) -> Posting? {
        // Its own page names Himalayas as the source and carries its apply link.
        guard let url = URL(string: job.guid) ?? job.applicationLink.flatMap(URL.init(string:)) else { return nil }
        let places = job.locationRestrictions ?? []
        return Posting(
            sourceID: id, url: url, company: job.companyName, title: job.title,
            location: places.isEmpty ? "Remote, anywhere" : "Remote - " + places.joined(separator: ", "),
            postedAt: posted, descriptionHTML: job.description ?? job.excerpt ?? "",
            countryHint: places.isEmpty ? nil : country.rawValue, workplace: .remote)
    }
}

struct HimalayasPage: Decodable {
    struct Job: Decodable {
        let title: String
        let companyName: String
        let guid: String
        let applicationLink: String?
        let description: String?
        let excerpt: String?
        /// Seconds since 1970.
        let pubDate: Double?
        let expiryDate: Double?
        let locationRestrictions: [String]?
    }
    let jobs: [Job]
}
