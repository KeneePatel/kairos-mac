import Foundation

/// A real opening, however many sources list it. It shows its primary listing's text and link: a
/// company's own board wins over a search's copy.
public struct Job: Sendable, Equatable, Identifiable, Codable {
    /// What you decided, apart from building and applying.
    public enum Decision: String, Codable, Sendable, CaseIterable {
        case saved, skipped
    }

    /// The id of the listing it was first found as.
    public let id: String
    public var company: String
    public var title: String
    public var location: String
    public var city: String?
    public var region: String?
    public var country: Country?
    public var remoteScope: RemoteScope
    public var postedAt: Date?
    /// Markdown.
    public var description: String
    public var salary: Salary?
    /// The primary listing's address.
    public var url: String
    /// The page Open posting opens, when better than `url`.
    public var applyURL: String?
    /// The site the posting was taken from, when a search says.
    public var via: String?
    /// Where the primary listing comes from.
    public var sourceKind: SourceKind?
    public var primaryListingID: String
    public var dedupKey: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    /// When its last open listing closed; nil while it's posted somewhere.
    public var closedAt: Date?
    public var decision: Decision?
    public var decidedAt: Date?
    /// Set by retention or "Clear jobs": out of every list, kept so the same posting isn't new again.
    public var archivedAt: Date?

    public init(
        id: String, company: String, title: String, location: String = "", city: String? = nil, region: String? = nil,
        country: Country? = nil, remoteScope: RemoteScope = .unknown, postedAt: Date? = nil, description: String = "",
        salary: Salary? = nil, url: String, applyURL: String? = nil, via: String? = nil, sourceKind: SourceKind? = nil,
        primaryListingID: String? = nil, dedupKey: String? = nil, firstSeenAt: Date, lastSeenAt: Date? = nil,
        closedAt: Date? = nil, decision: Decision? = nil, decidedAt: Date? = nil, archivedAt: Date? = nil
    ) {
        self.id = id
        self.company = company
        self.title = title
        self.location = location
        self.city = city
        self.region = region
        self.country = country
        self.remoteScope = remoteScope
        self.postedAt = postedAt
        self.description = description
        self.salary = salary
        self.url = url
        self.applyURL = applyURL
        self.via = via
        self.sourceKind = sourceKind
        self.primaryListingID = primaryListingID ?? id
        self.dedupKey = dedupKey ?? DedupKey.make(company: company, title: title, city: city)
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt ?? firstSeenAt
        self.closedAt = closedAt
        self.decision = decision
        self.decidedAt = decidedAt
        self.archivedAt = archivedAt
    }

    /// A new job from its first listing.
    public init(_ listing: Listing, sourceKind: SourceKind?, at now: Date) {
        self.init(
            id: listing.id, company: listing.company, title: listing.title, location: listing.location,
            city: listing.city, region: listing.region, country: listing.country, remoteScope: listing.remoteScope,
            postedAt: listing.postedAt, description: listing.description, salary: listing.salary, url: listing.url,
            applyURL: listing.applyURL, via: listing.via, sourceKind: sourceKind, primaryListingID: listing.id,
            dedupKey: listing.dedupKey, firstSeenAt: now)
    }

    /// The address Open posting and Copy link use.
    public var openURL: String { applyURL ?? url }

    /// Still posted somewhere.
    public var isOpen: Bool { closedAt == nil }

    /// "Toronto, ON" or "Remote (Canada)", short enough for a row.
    public var placeLine: String {
        let place = [city, region].compactMap { $0 }.joined(separator: ", ")
        switch remoteScope {
        case .remote, .remoteAnywhere: return place.isEmpty ? "Remote" : "Remote · \(place)"
        case .remoteCountry: return "Remote (\(country?.name ?? "one country"))"
        case .hybrid: return place.isEmpty ? "Hybrid" : "\(place) · Hybrid"
        case .onsite, .unknown:
            if !place.isEmpty { return place }
            return location.split(separator: ";").first.map(String.init) ?? location
        }
    }
}

/// Something that happened to a job, for "where did this come from, and is it still up?".
public struct JobEvent: Sendable, Equatable, Codable {
    public enum Kind: String, Codable, Sendable {
        /// First seen.
        case found
        /// Another source lists it too.
        case postedElsewhere = "posted_elsewhere"
        /// Its title, place or text changed.
        case changed
        /// A whole posting replaced a partial one.
        case upgraded
        case closed, reopened
    }

    public var kind: Kind
    public var at: Date
    public var sourceKind: SourceKind?
    public var detail: String?

    public init(kind: Kind, at: Date, sourceKind: SourceKind? = nil, detail: String? = nil) {
        self.kind = kind
        self.at = at
        self.sourceKind = sourceKind
        self.detail = detail
    }
}

/// A company a snippet search (Adzuna) found hiring at your roles: never a job, but a name to look
/// up on public boards, which list the same postings in full.
public struct Lead: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var company: String
    public var title: String
    public var location: String
    public var postedAt: Date?
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(
        id: String, company: String, title: String, location: String, postedAt: Date?, firstSeenAt: Date,
        lastSeenAt: Date
    ) {
        self.id = id
        self.company = company
        self.title = title
        self.location = location
        self.postedAt = postedAt
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    public init(_ listing: Listing, at now: Date) {
        self.init(
            id: listing.id, company: listing.company, title: listing.title, location: listing.location,
            postedAt: listing.postedAt, firstSeenAt: now, lastSeenAt: now)
    }
}
