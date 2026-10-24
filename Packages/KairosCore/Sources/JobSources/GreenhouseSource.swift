import Foundation

/// A company's Greenhouse job board, through the public board API (no key). With your roles set
/// (the app's case, job collection v2), it reads the board's light list (2026-10-23: 39 KB instead
/// of 2 MB for Stripe) and asks for a job's text only when it's new and at your roles, or known and
/// edited in the last two days; the rest count as seen. Without roles it reads the full board.
public struct GreenhouseSource: JobSource {
    public let id: SourceID
    let boardToken: String
    let http: any HTTPClient
    let now: @Sendable () -> Date

    /// A known job edited this recently has its text read again.
    static let editedWithin: TimeInterval = 2 * 86_400

    public init(
        id: SourceID, boardToken: String, http: any HTTPClient, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.id = id
        self.boardToken = boardToken
        self.http = http
        self.now = now
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
        let light = query.roles != nil
        guard BoardSlug.isValid(boardToken),
            let url = URL(
                string: "https://boards-api.greenhouse.io/v1/boards/\(boardToken)/jobs" + (light ? "" : "?content=true")
            )
        else {
            throw SourceError.invalidConfiguration("Greenhouse board token: \(boardToken)")
        }
        let (answer, etag) = try await http.getJSON(url, as: GreenhousePage.self, ifNoneMatch: memo?.etag)
        guard let page = answer else { return .unchanged }
        guard light else { return .postings(postings(page, query), memo: FetchMemo(etag: etag)) }
        var postings: [Posting] = []
        for job in page.jobs {
            var posting = posting(job, query)
            let known = query.knownURLs.contains(URLCanonicalizer.canonical(job.absoluteUrl))
            let wanted = query.roles?.matches(job.title) ?? true
            let edited = job.updatedAt.map { now().timeIntervalSince($0) < Self.editedWithin } ?? false
            if known ? edited : wanted, let jobID = job.id,
                let detail = URL(
                    string:
                        "https://boards-api.greenhouse.io/v1/boards/\(boardToken)/jobs/\(jobID)?pay_transparency=true"),
                let full = try? await http.getJSON(detail, as: GreenhousePage.Job.self)
            {
                posting = self.posting(full, query)
            } else {
                posting.textOmitted = true
            }
            postings.append(posting)
        }
        return .postings(postings, memo: FetchMemo(etag: etag))
    }

    private func postings(_ page: GreenhousePage, _ query: SourceQuery) -> [Posting] {
        page.jobs.map { posting($0, query) }
    }

    private func posting(_ job: GreenhousePage.Job, _ query: SourceQuery) -> Posting {
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

struct GreenhousePage: Decodable {
    struct Job: Decodable {
        struct Location: Decodable { let name: String }
        let id: Int?
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
