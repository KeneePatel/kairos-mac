import Foundation

/// A company's Greenhouse job board, through the public board API (no key).
public struct GreenhouseSource: JobSource {
    public let id: SourceID
    let boardToken: String
    let http: any HTTPClient

    public init(id: SourceID, boardToken: String, http: any HTTPClient) {
        self.id = id
        self.boardToken = boardToken
        self.http = http
    }

    public var listsEverything: Bool { true }

    public func fetch(_ query: SourceQuery) async throws -> [Posting] {
        guard case .postings(let postings, _) = try await fetch(query, since: nil) else { return [] }
        return postings
    }

    /// The board answers 304 to an ETag it last sent when no job changed (2026-10-23: 0 bytes
    /// instead of 2 MB for Stripe).
    public func fetch(_ query: SourceQuery, since memo: FetchMemo?) async throws -> FetchAnswer {
        // The token goes into the URL path, so only allow what board tokens use.
        guard BoardSlug.isValid(boardToken),
            let url = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(boardToken)/jobs?content=true")
        else {
            throw SourceError.invalidConfiguration("Greenhouse board token: \(boardToken)")
        }
        let (answer, etag) = try await http.getJSON(url, as: GreenhousePage.self, ifNoneMatch: memo?.etag)
        guard let page = answer else { return .unchanged }
        return .postings(postings(page, query), memo: FetchMemo(etag: etag))
    }

    private func postings(_ page: GreenhousePage, _ query: SourceQuery) -> [Posting] {
        page.jobs.map { job in
            Posting(
                sourceID: id,
                url: job.absoluteUrl,
                company: query.companyName ?? job.companyName ?? boardToken,
                title: job.title,
                location: job.location?.name ?? "",
                // updated_at moves on every edit, which would make old postings look new.
                postedAt: job.firstPublished ?? job.updatedAt,
                // Greenhouse sends the HTML entity-escaped once.
                descriptionHTML: HTMLEntities.decode(job.content ?? "")
            )
        }
    }
}

struct GreenhousePage: Decodable {
    struct Job: Decodable {
        struct Location: Decodable { let name: String }
        let title: String
        let updatedAt: Date?
        let firstPublished: Date?
        let absoluteUrl: URL
        let location: Location?
        let companyName: String?
        let content: String?
    }
    let jobs: [Job]
}

/// Board tokens, slugs and org names as the ATS APIs accept them: ASCII letters, digits, "-" and "_".
/// No "." or "/", so a token can never step out of its URL path segment.
enum BoardSlug {
    static func isValid(_ slug: String) -> Bool {
        (1...100).contains(slug.count)
            && slug.unicodeScalars.allSatisfy {
                $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
            }
    }
}
