import Foundation
import Store

/// The Inbox (UI v2, ADR-017): the jobs waiting for your decision, in two groups, best first
/// (three until job collection v3 dropped snippets, ADR-018). Pure functions over the jobs the app
/// already holds, so the grouping and the order are tested.
public enum Inbox {
    /// Which of the Inbox's groups a job falls in.
    public enum GroupKind: String, Sendable, CaseIterable, Identifiable {
        /// Judged on the whole posting: decide now.
        case decide
        /// The AI's No, kept out of the way.
        case noFromAI

        public var id: Self { self }

        public var title: String {
            switch self {
            case .decide: "Decide"
            case .noFromAI: "No from the AI"
            }
        }
    }

    public struct Group: Identifiable, Equatable, Sendable {
        public let kind: GroupKind
        public let jobs: [Job]
        public var id: GroupKind { kind }

        public init(kind: GroupKind, jobs: [Job]) {
            self.kind = kind
            self.jobs = jobs
        }
    }

    public enum Sort: String, Sendable, CaseIterable, Identifiable {
        case match, newest, company
        public var id: Self { self }

        public var title: String {
            switch self {
            case .match: "Match"
            case .newest: "Newest"
            case .company: "Company"
            }
        }
    }

    /// What narrows the list: the toolbar's Filter and Sort menus and the search field.
    public struct Query: Sendable, Equatable {
        public var verdict: Verdict?
        public var country: Country?
        public var search = ""
        public var sort = Sort.match

        public init(verdict: Verdict? = nil, country: Country? = nil, search: String = "", sort: Sort = .match) {
            self.verdict = verdict
            self.country = country
            self.search = search
            self.sort = sort
        }
    }

    /// Jobs waiting for your decision: they passed your filters, the AI judged them, they're still
    /// posted, and you haven't saved, skipped or applied to them.
    public static func waiting(_ jobs: [Job]) -> [Job] {
        jobs.filter { $0.state == .new && $0.verdict != nil && $0.verdictSource != .prefilter && $0.isOpen }
    }

    /// Jobs you saved for later, whatever became of them since.
    public static func saved(_ jobs: [Job]) -> [Job] { jobs.filter { $0.state == .shortlisted } }

    /// Jobs you skipped, and judged jobs that are no longer posted anywhere.
    public static func skipped(_ jobs: [Job]) -> [Job] {
        jobs.filter {
            $0.state == .skipped
                || ($0.state == .new && !$0.isOpen && $0.verdict != nil && $0.verdictSource != .prefilter)
        }
    }

    /// `jobs` (already narrowed to a list) in the two groups, each ordered by `query.sort`: a No
    /// sits apart, the rest are to decide. Empty groups are left out.
    public static func groups(_ jobs: [Job], query: Query, countries: [Country]) -> [Group] {
        let shown = jobs.filter { job in
            (query.verdict == nil || job.verdict == query.verdict)
                && (query.country == nil || job.country == query.country) && matches(job, query.search)
        }
        var byKind: [GroupKind: [Job]] = [:]
        for job in shown {
            byKind[job.verdict == .no ? .noFromAI : .decide, default: []].append(job)
        }
        return GroupKind.allCases.compactMap { kind in
            guard let members = byKind[kind], !members.isEmpty else { return nil }
            return Group(kind: kind, jobs: sorted(members, by: query.sort, countries: countries))
        }
    }

    /// The order within a group. Match: your countries first, then Yes before Maybe before No,
    /// then the screening's rank, then the newest. Newest: when Kairos first saw the job. Company:
    /// alphabetical, then the title.
    public static func sorted(_ jobs: [Job], by sort: Sort, countries: [Country]) -> [Job] {
        func countryRank(_ job: Job) -> Int {
            guard let country = job.country else { return countries.count + 1 }
            return countries.firstIndex(of: country) ?? countries.count
        }
        func verdictRank(_ job: Job) -> Int {
            switch job.verdict {
            case .yes?: 0
            case .maybe?: 1
            case .no?: 2
            case nil: 3
            }
        }
        switch sort {
        case .match:
            return jobs.sorted {
                (countryRank($0), verdictRank($0), -($0.rank ?? -1), -$0.firstSeenAt.timeIntervalSince1970, $0.title)
                    < (
                        countryRank($1), verdictRank($1), -($1.rank ?? -1), -$1.firstSeenAt.timeIntervalSince1970,
                        $1.title
                    )
            }
        case .newest:
            return jobs.sorted {
                ($1.firstSeenAt, $0.rank ?? -1, $0.title) < ($0.firstSeenAt, $1.rank ?? -1, $1.title)
            }
        case .company:
            return jobs.sorted {
                ($0.company.localizedLowercase, $0.title.localizedLowercase)
                    < ($1.company.localizedLowercase, $1.title.localizedLowercase)
            }
        }
    }

    /// Every word of `search` appears in the title, the company or the place.
    static func matches(_ job: Job, _ search: String) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = "\(job.title) \(job.company) \(job.location)".localizedLowercase
        return words.allSatisfy { haystack.contains($0.localizedLowercase) }
    }

    /// How many of `jobs` Kairos first saw today.
    public static func newToday(_ jobs: [Job], now: Date = Date(), calendar: Calendar = .current) -> Int {
        jobs.count { calendar.isDate($0.firstSeenAt, inSameDayAs: now) }
    }
}
