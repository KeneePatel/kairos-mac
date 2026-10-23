import CryptoKit
import Foundation

/// A job's id: the first 16 bytes of SHA-256 over its canonical URL, as lowercase hex. Every device
/// that sees the same posting derives the same id (SPEC §6.1).
public struct JobID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(canonicalURL: String) {
        rawValue = SHA256.hash(data: Data(canonicalURL.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// An id as stored, such as a build's `job_id`.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum Country: String, Sendable, CaseIterable, Codable {
    case canada = "CA"
    case unitedStates = "US"
}

/// Where you are with a posting. `shortlisted` is the design's "Save".
public enum JobState: String, Sendable, CaseIterable {
    case new, shortlisted, skipped, applied, archived
}

public enum Verdict: String, Sendable, CaseIterable {
    case yes, maybe, no
}

/// What set the verdict: a prefilter rule, the analysis, or you overruling it.
public enum VerdictSource: String, Sendable, CaseIterable {
    case prefilter, analysis, user
}

/// `remoteCountry` means remote within `country` only, such as "Remote (US only)". `remoteAnywhere`
/// spans countries ("Remote - North America", "Worldwide"). `remote` doesn't say where.
public enum RemoteScope: String, Sendable, CaseIterable, Codable {
    case unknown, onsite, hybrid, remote
    case remoteCountry = "remote_country"
    case remoteAnywhere = "remote_anywhere"
}

/// How much of a posting Kairos holds: the whole text, a search's snippet (Adzuna sends 500
/// characters), or none (a stub or tombstone).
public enum DescriptionKind: String, Sendable, CaseIterable, Codable {
    case full, snippet, none
}

/// A posted pay range, in the job's `currency`.
public struct Salary: Codable, Sendable, Equatable {
    public enum Period: String, Codable, Sendable, CaseIterable { case year, month, week, day, hour }

    public var min: Double?
    public var max: Double?
    public var period: Period

    public init(min: Double?, max: Double?, period: Period) {
        self.min = min
        self.max = max
        self.period = period
    }
}

/// One posting (SPEC §6.2, `job`). The id comes from the canonical URL, so the two can't disagree.
public struct Job: Sendable, Equatable, Identifiable {
    public let id: JobID
    public let canonicalURL: String
    public var sourceID: UUID
    public var url: String
    public var dedupKey: String
    public var company: String
    public var title: String
    public var location: String
    public var city: String?
    public var region: String?
    public var country: Country?
    public var remoteScope: RemoteScope
    public var currency: String?
    public var salary: Salary?
    public var postedAt: Date?
    /// Markdown. Nil for jobs kept as stubs.
    public var descriptionMarkdown: String?
    public var state: JobState
    public var verdict: Verdict?
    public var verdictSource: VerdictSource?
    /// Higher ranks list first.
    public var rank: Double?
    public var firstSeenAt: Date
    /// When any of its listings was last seen; nil before job collection v2 tracked it.
    public var lastSeenAt: Date?
    /// When its last open listing closed; nil while it's posted somewhere.
    public var closedAt: Date?
    public var descriptionKind: DescriptionKind
    /// The listing whose text and link the job shows: a company's board over a search's copy.
    public var primaryListingID: JobID?
    /// Set by the repository on every write.
    public internal(set) var updatedHLC: HLCTimestamp?

    public init(
        canonicalURL: String, sourceID: UUID, url: String, dedupKey: String, company: String, title: String,
        location: String = "", city: String? = nil, region: String? = nil, country: Country? = nil,
        remoteScope: RemoteScope = .unknown, currency: String? = nil, salary: Salary? = nil, postedAt: Date? = nil,
        descriptionMarkdown: String? = nil, state: JobState = .new, verdict: Verdict? = nil,
        verdictSource: VerdictSource? = nil, rank: Double? = nil, firstSeenAt: Date, lastSeenAt: Date? = nil,
        closedAt: Date? = nil, descriptionKind: DescriptionKind = .full, primaryListingID: JobID? = nil
    ) {
        self.id = JobID(canonicalURL: canonicalURL)
        self.canonicalURL = canonicalURL
        self.sourceID = sourceID
        self.url = url
        self.dedupKey = dedupKey
        self.company = company
        self.title = title
        self.location = location
        self.city = city
        self.region = region
        self.country = country
        self.remoteScope = remoteScope
        self.currency = currency
        self.salary = salary
        self.postedAt = postedAt
        self.descriptionMarkdown = descriptionMarkdown
        self.state = state
        self.verdict = verdict
        self.verdictSource = verdictSource
        self.rank = rank
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.closedAt = closedAt
        self.descriptionKind = descriptionKind
        self.primaryListingID = primaryListingID
    }

    /// Still posted somewhere.
    public var isOpen: Bool { closedAt == nil }
}
