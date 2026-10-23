import Foundation

/// A company's Workable board, through the public widget feed its careers page uses
/// (`apply.workable.com/api/v1/widget/accounts/{account}?details=true`, no key; job collection v2,
/// J2). Every open job, with its text, in one answer. Workable doesn't document this feed, so
/// its shape is pinned by a recorded answer (2026-10-23).
public struct WorkableSource: JobSource {
    public let id: SourceID
    let account: String
    let http: any HTTPClient

    public init(id: SourceID, account: String, http: any HTTPClient) {
        self.id = id
        self.account = account
        self.http = http
    }

    public var listsEverything: Bool { true }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard BoardSlug.isValid(account),
            let url = URL(string: "https://apply.workable.com/api/v1/widget/accounts/\(account)?details=true")
        else {
            throw SourceError.invalidConfiguration("Workable account: \(account)")
        }
        let board = try await http.getJSON(url, as: WorkableBoard.self)
        return board.jobs.compactMap { job in
            guard let link = URL(string: job.url) else { return nil }
            let places = (job.locations ?? []).filter { $0.hidden != true }
            let main = places.first
            return Posting(
                sourceID: id, url: link, company: query.companyName ?? board.name ?? account, title: job.title,
                location: main.map(Self.place)
                    ?? [job.city, job.state, job.country].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: ", "),
                postedAt: SourceDates.parse(job.publishedOn ?? job.createdAt), descriptionHTML: job.description ?? "",
                otherLocations: places.dropFirst().map(Self.place),
                countryHint: main?.countryCode ?? job.country, workplace: job.telecommuting == true ? .remote : nil)
        }
    }

    static func place(_ location: WorkableBoard.Job.Location) -> String {
        [location.city, location.region, location.country].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

struct WorkableBoard: Decodable {
    struct Job: Decodable {
        struct Location: Decodable {
            let country: String?
            let countryCode: String?
            let city: String?
            let region: String?
            let hidden: Bool?
        }
        let title: String
        let url: String
        let publishedOn: String?
        let createdAt: String?
        let country: String?
        let city: String?
        let state: String?
        let telecommuting: Bool?
        let locations: [Location]?
        let description: String?
    }
    let name: String?
    let jobs: [Job]
}
