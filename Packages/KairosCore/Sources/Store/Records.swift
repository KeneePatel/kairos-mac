import Foundation
import Jobs
import KairosKit
import Screening
import Tailoring

/// One configured source: a company board or a search.
public struct Source: Sendable, Equatable, Identifiable, Hashable {
    /// How it came to be watched.
    public enum Origin: String, Sendable, Codable, CaseIterable {
        /// You added it.
        case you
        /// Kairos's catalog of boards with jobs in your countries.
        case catalog
        /// Found behind a search's links (a Google Jobs result on a Greenhouse board).
        case link
        /// Found by looking up a lead's company.
        case lead
        /// One of the searches.
        case search
    }

    public enum Status: String, Sendable, Codable, CaseIterable {
        case watching, muted
        /// "Not found" three times in a row: not read again until you resume it.
        case gone
        /// You removed it: never added back by the catalog or a lookup.
        case removed
    }

    public let id: UUID
    public var kind: SourceKind
    public var slug: String
    public var name: String
    public var region: String?
    public var origin: Origin
    public var status: Status
    public var addedAt: Date
    public var checkedAt: Date?
    public var okAt: Date?
    public var etag: String?
    public var failStreak: Int
    public var missingStreak: Int
    public var quietStreak: Int
    public var restUntil: Date?
    public var lastError: String?

    public init(
        id: UUID = .v7(), kind: SourceKind, slug: String = "", name: String = "", region: String? = nil, origin: Origin,
        status: Status = .watching, addedAt: Date, checkedAt: Date? = nil, okAt: Date? = nil, etag: String? = nil,
        failStreak: Int = 0, missingStreak: Int = 0, quietStreak: Int = 0, restUntil: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.slug = slug
        self.name = name
        self.region = region
        self.origin = origin
        self.status = status
        self.addedAt = addedAt
        self.checkedAt = checkedAt
        self.okAt = okAt
        self.etag = etag
        self.failStreak = failStreak
        self.missingStreak = missingStreak
        self.quietStreak = quietStreak
        self.restUntil = restUntil
        self.lastError = lastError
    }

    /// The board it reads, for a company board.
    public var board: Board? {
        kind.isBoard ? Board(kind: kind, slug: slug, name: name, region: region) : nil
    }

    public var displayName: String { kind.isBoard ? (name.isEmpty ? slug : name) : kind.displayName }

    /// Read on the next fetch: watched, and not resting.
    public func isDue(at now: Date) -> Bool {
        status == .watching && (restUntil.map { $0 <= now } ?? true)
    }
}

/// Where screening left a job.
public struct ScreeningState: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        /// A filter dropped it.
        case filtered
        /// It passed the filters and waits for the AI.
        case waiting
        /// The AI's analysis and the verdict engine judged it.
        case judged
    }

    public var stage: Stage
    public var verdict: Verdict?
    /// The filter rule or the verdict rule.
    public var rule: String?
    public var reasons: [String]
    public var coverage: Coverage?
    public var match: Double?
    public var rank: Double?
    /// You overruled it.
    public var yourVerdict: Verdict?
    /// You brought it back from Filtered out: filters never drop it again.
    public var broughtBack: Bool
    public var screenedAt: Date

    public init(
        stage: Stage, verdict: Verdict? = nil, rule: String? = nil, reasons: [String] = [], coverage: Coverage? = nil,
        match: Double? = nil, rank: Double? = nil, yourVerdict: Verdict? = nil, broughtBack: Bool = false,
        screenedAt: Date
    ) {
        self.stage = stage
        self.verdict = verdict
        self.rule = rule
        self.reasons = reasons
        self.coverage = coverage
        self.match = match
        self.rank = rank
        self.yourVerdict = yourVerdict
        self.broughtBack = broughtBack
        self.screenedAt = screenedAt
    }

    /// Yours when you set one.
    public var shownVerdict: Verdict? { yourVerdict ?? verdict }

    public var filterRule: PrefilterRule? { stage == .filtered ? rule.flatMap(PrefilterRule.init) : nil }
    public var verdictRule: VerdictRule? { stage == .judged ? rule.flatMap(VerdictRule.init) : nil }
}

/// A job as lists show it: no posting text, with what screening, builds and applications say.
public struct JobSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public var company: String
    public var title: String
    public var placeLine: String
    public var country: Country?
    public var remoteScope: RemoteScope
    public var salary: Salary?
    public var postedAt: Date?
    public var firstSeenAt: Date
    public var closedAt: Date?
    public var decision: Job.Decision?
    public var sourceKind: SourceKind?
    public var via: String?
    public var screening: ScreeningState?
    public var build: BuildBrief?
    public var application: ApplicationBrief?

    public struct BuildBrief: Sendable, Equatable {
        public let id: UUID
        public let status: BuildRecord.Status
        public let score: Double?

        public init(id: UUID, status: BuildRecord.Status, score: Double? = nil) {
            self.id = id
            self.status = status
            self.score = score
        }
    }

    public struct ApplicationBrief: Sendable, Equatable {
        public let id: UUID
        public let status: Application.Status

        public init(id: UUID, status: Application.Status) {
            self.id = id
            self.status = status
        }
    }

    public init(
        id: String, company: String, title: String, placeLine: String, country: Country? = nil,
        remoteScope: RemoteScope = .unknown, salary: Salary? = nil, postedAt: Date? = nil, firstSeenAt: Date,
        closedAt: Date? = nil, decision: Job.Decision? = nil, sourceKind: SourceKind? = nil, via: String? = nil,
        screening: ScreeningState? = nil, build: BuildBrief? = nil, application: ApplicationBrief? = nil
    ) {
        self.id = id
        self.company = company
        self.title = title
        self.placeLine = placeLine
        self.country = country
        self.remoteScope = remoteScope
        self.salary = salary
        self.postedAt = postedAt
        self.firstSeenAt = firstSeenAt
        self.closedAt = closedAt
        self.decision = decision
        self.sourceKind = sourceKind
        self.via = via
        self.screening = screening
        self.build = build
        self.application = application
    }

    public var isOpen: Bool { closedAt == nil }
    public var verdict: Verdict? { screening?.shownVerdict }
    public var match: Double? { screening?.match }
}

/// Everything about one job, for its pane.
public struct JobDetail: Sendable, Equatable {
    public struct ListingRecord: Sendable, Equatable, Identifiable {
        public let id: String
        public let sourceID: UUID
        public let sourceKind: SourceKind?
        public let sourceName: String
        public let url: String
        public let firstSeenAt: Date
        public let lastSeenAt: Date
        public let closedAt: Date?

        public init(
            id: String, sourceID: UUID, sourceKind: SourceKind?, sourceName: String, url: String, firstSeenAt: Date,
            lastSeenAt: Date, closedAt: Date? = nil
        ) {
            self.id = id
            self.sourceID = sourceID
            self.sourceKind = sourceKind
            self.sourceName = sourceName
            self.url = url
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
            self.closedAt = closedAt
        }
    }

    public var job: Job
    public var listings: [ListingRecord]
    public var events: [JobEvent]
    public var analysis: JobAnalysis?
    public var screening: ScreeningState?

    public init(
        job: Job, listings: [ListingRecord] = [], events: [JobEvent] = [], analysis: JobAnalysis? = nil,
        screening: ScreeningState? = nil
    ) {
        self.job = job
        self.listings = listings
        self.events = events
        self.analysis = analysis
        self.screening = screening
    }
}

/// A build as stored.
public struct BuildRecord: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Codable, CaseIterable {
        case queued, running, done, failed, stopped

        public var isFinished: Bool { [.done, .failed, .stopped].contains(self) }
    }

    public struct File: Sendable, Equatable {
        public enum Kind: String, Sendable, Codable { case resume, letter }
        public let kind: Kind
        /// Relative to the data folder.
        public let path: String
        public let sha256: String

        public init(kind: Kind, path: String, sha256: String) {
            self.kind = kind
            self.path = path
            self.sha256 = sha256
        }
    }

    public let id: UUID
    public var jobID: String
    public var mode: BuildMode
    public var resumeVersion: Int
    public var status: Status
    public var wantsLetter: Bool
    public var resume: TailoredResume?
    public var letter: CoverLetter?
    public var letterError: String?
    public var report: BuildNotes?
    public var score: Double?
    public var error: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var files: [File]

    public init(
        id: UUID = .v7(), jobID: String, mode: BuildMode, resumeVersion: Int, status: Status = .queued,
        wantsLetter: Bool = false, resume: TailoredResume? = nil, letter: CoverLetter? = nil,
        letterError: String? = nil,
        report: BuildNotes? = nil, score: Double? = nil, error: String? = nil, createdAt: Date, startedAt: Date? = nil,
        finishedAt: Date? = nil, files: [File] = []
    ) {
        self.id = id
        self.jobID = jobID
        self.mode = mode
        self.resumeVersion = resumeVersion
        self.status = status
        self.wantsLetter = wantsLetter
        self.resume = resume
        self.letter = letter
        self.letterError = letterError
        self.report = report
        self.score = score
        self.error = error
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.files = files
    }

    public func file(_ kind: File.Kind) -> File? { files.first { $0.kind == kind } }

    public var seconds: Double? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

/// What a finished build says about itself: the report card, sections that fell back to your
/// words, and notes on models that failed or steps that were skipped.
public struct BuildNotes: Codable, Sendable, Equatable {
    public var report: BuildReport?
    public var score: MatchScore?
    public var fellBack: [String]
    public var notes: [String]

    public init(report: BuildReport? = nil, score: MatchScore? = nil, fellBack: [String] = [], notes: [String] = []) {
        self.report = report
        self.score = score
        self.fellBack = fellBack
        self.notes = notes
    }
}

/// A job you applied to.
public struct Application: Sendable, Equatable, Identifiable {
    /// Raw values are what the first Kairos stored.
    public enum Status: String, Sendable, Codable, CaseIterable, Identifiable {
        case applied, screen, interview, offer, accepted, rejected, ghosted, withdrawn

        public var id: Self { self }

        public var title: String {
            switch self {
            case .applied: "Applied"
            case .screen: "Screen"
            case .interview: "Interview"
            case .offer: "Offer"
            case .accepted: "Accepted"
            case .rejected: "Rejected"
            case .ghosted: "No reply"
            case .withdrawn: "Withdrawn"
            }
        }

        /// Waiting to hear back.
        public var isWaiting: Bool { self == .applied }
        /// Talking to them: the Interviews board's columns.
        public var isInProgress: Bool { [.screen, .interview, .offer].contains(self) }
        public var isClosed: Bool { [.accepted, .rejected, .ghosted, .withdrawn].contains(self) }
    }

    public let id: UUID
    public var jobID: String
    public var buildID: UUID?
    public var appliedAt: Date
    public var channel: String?
    public var status: Status
    public var statusAt: Date
    public var followUpAt: Date?
    public var nextStep: String?
    public var notes: String
    public var updatedAt: Date

    public init(
        id: UUID = .v7(), jobID: String, buildID: UUID? = nil, appliedAt: Date, channel: String? = nil,
        status: Status = .applied, statusAt: Date? = nil, followUpAt: Date? = nil, nextStep: String? = nil,
        notes: String = "",
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.buildID = buildID
        self.appliedAt = appliedAt
        self.channel = channel
        self.status = status
        self.statusAt = statusAt ?? appliedAt
        self.followUpAt = followUpAt
        self.nextStep = nextStep
        self.notes = notes
        self.updatedAt = updatedAt ?? appliedAt
    }
}

public struct ApplicationEvent: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var applicationID: UUID
    /// A status reached, or "note".
    public var kind: String
    public var at: Date
    public var note: String?

    public init(id: UUID = .v7(), applicationID: UUID, kind: String, at: Date, note: String? = nil) {
        self.id = id
        self.applicationID = applicationID
        self.kind = kind
        self.at = at
        self.note = note
    }
}

/// A fetch or a screening, for the status line and history.
public struct Run: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case fetch, screen }

    public let id: UUID
    public var kind: Kind
    public var startedAt: Date
    public var finishedAt: Date?
    public var stats: RunStats
    public var error: String?
}

/// What a run did. Every field is optional, so each kind of run fills its own.
public struct RunStats: Codable, Sendable, Equatable {
    public var sources: Int?
    public var failed: Int?
    public var unchanged: Int?
    public var found: Int?
    public var added: Int?
    public var changed: Int?
    public var closed: Int?
    public var leads: Int?
    public var newBoards: Int?
    public var screened: Int?
    public var filtered: Int?
    public var judged: Int?
    public var waiting: Int?
    public var yes: Int?
    public var maybe: Int?
    public var no: Int?
    public var aiCalls: Int?
    public var stopped: Bool?

    public init() {}
}
