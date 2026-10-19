import Foundation
import Store

/// What a company-board source stores in `source.config`.
public struct BoardConfig: Codable, Sendable, Equatable {
    public var slug: String
    /// The display name you gave the company, if any.
    public var company: String?

    public init(slug: String, company: String? = nil) {
        self.slug = slug
        self.company = company
    }

    public var json: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) -> BoardConfig? {
        try? JSONDecoder().decode(BoardConfig.self, from: Data(json.utf8))
    }
}

/// Builds the fetcher for a configured source.
public enum SourceFactory {
    public static func make(_ source: Source, http: any HTTPClient) throws(SourceError) -> (any JobSource, SourceQuery)
    {
        switch source.kind {
        case .greenhouse, .lever, .ashby:
            guard let config = BoardConfig.decode(source.config) else {
                throw .invalidConfiguration("\(source.kind.rawValue) source has no board slug")
            }
            let query = SourceQuery(companyName: config.company)
            switch source.kind {
            case .greenhouse: return (GreenhouseSource(id: source.id, boardToken: config.slug, http: http), query)
            case .lever: return (LeverSource(id: source.id, slug: config.slug, http: http), query)
            default: return (AshbySource(id: source.id, organization: config.slug, http: http), query)
            }
        case .adzuna, .linkedIn, .indeedCanada, .indeedUS, .glassdoor, .googleJobs, .wellfound, .jobBank:
            throw .invalidConfiguration("\(source.kind.rawValue) isn't available yet")
        }
    }
}

extension SourceError {
    /// A short sentence for the Sources screen and run history.
    public var message: String {
        switch self {
        case .invalidConfiguration(let detail): "Check the settings: \(detail)."
        case .timedOut: "The board took too long to answer."
        case .offline: "You're offline."
        case .network(let detail): "Network error (\(detail))."
        case .notFound: "The board wasn't found. The company may have moved to another job site."
        case .rateLimited(let seconds):
            "The board asked us to slow down" + (seconds.map { "; try again in \($0) s." } ?? ".")
        case .http(let status, _): "The board answered with HTTP \(status)."
        case .decoding(let detail): "The board's response changed shape (\(detail))."
        case .cancelled: "Stopped."
        }
    }
}
