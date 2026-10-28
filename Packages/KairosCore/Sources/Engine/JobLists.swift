import Foundation
import Jobs
import Screening
import Store

/// The job lists: which jobs each shows and in what order. Pure functions over the summaries the
/// app holds, so the grouping and the order are tested.
public enum JobLists {
    /// The Inbox's groups.
    public enum Group: String, Sendable, CaseIterable, Identifiable {
        /// Judged Yes or Maybe: decide now.
        case decide
        /// The AI's No, kept out of the way.
        case no

        public var id: Self { self }

        public var title: String {
            switch self {
            case .decide: "Decide"
            case .no: "No from the AI"
            }
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

    /// The toolbar's filter and sort, and the search field.
    public struct Query: Sendable, Equatable {
        public var verdict: Verdict?
        public var country: Country?
        public var search: String
        public var sort: Sort

        public init(verdict: Verdict? = nil, country: Country? = nil, search: String = "", sort: Sort = .match) {
            self.verdict = verdict
            self.country = country
            self.search = search
            self.sort = sort
        }
    }

    /// Jobs waiting for your decision: judged, still posted, and not saved, skipped or applied to.
    public static func inbox(_ jobs: [JobSummary]) -> [JobSummary] {
        jobs.filter { isUndecided($0) && isJudged($0) && $0.isOpen }
    }

    /// Jobs you saved, until you apply.
    public static func saved(_ jobs: [JobSummary]) -> [JobSummary] {
        jobs.filter { $0.decision == .saved && $0.application == nil }
    }

    /// Jobs you skipped, and judged jobs no longer posted anywhere.
    public static func skipped(_ jobs: [JobSummary]) -> [JobSummary] {
        jobs.filter {
            ($0.decision == .skipped && $0.application == nil) || (isUndecided($0) && isJudged($0) && !$0.isOpen)
        }
    }

    /// Jobs your filters dropped, still posted: Bring back is one click away.
    public static func filteredOut(_ jobs: [JobSummary]) -> [JobSummary] {
        jobs.filter { isUndecided($0) && $0.screening?.stage == .filtered && $0.verdict == nil && $0.isOpen }
    }

    /// Jobs that passed your filters and wait for the AI.
    public static func waitingForAI(_ jobs: [JobSummary]) -> [JobSummary] {
        jobs.filter { $0.screening?.stage == .waiting && $0.verdict == nil && $0.isOpen }
    }

    /// `jobs`, narrowed by `query`, in the Inbox's groups, each in `query.sort`'s order. Empty
    /// groups are left out.
    public static func groups(_ jobs: [JobSummary], query: Query, countries: [Country]) -> [(Group, [JobSummary])] {
        let shown = narrowed(jobs, by: query)
        return Group.allCases.compactMap { group in
            let members = shown.filter { ($0.verdict == .no) == (group == .no) }
            return members.isEmpty ? nil : (group, sorted(members, by: query.sort, countries: countries))
        }
    }

    public static func narrowed(_ jobs: [JobSummary], by query: Query) -> [JobSummary] {
        jobs.filter { job in
            (query.verdict == nil || job.verdict == query.verdict)
                && (query.country == nil || job.country == query.country) && matches(job, query.search)
        }
    }

    /// Match: your countries first, then Yes before Maybe before No, then screening's rank, then the
    /// newest. Newest: when Kairos first saw it. Company: alphabetical, then the title.
    public static func sorted(_ jobs: [JobSummary], by sort: Sort, countries: [Country]) -> [JobSummary] {
        func countryRank(_ job: JobSummary) -> Int {
            guard let country = job.country else { return countries.count + 1 }
            return countries.firstIndex(of: country) ?? countries.count
        }
        func verdictRank(_ job: JobSummary) -> Int {
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
                (
                    countryRank($0), verdictRank($0), -($0.screening?.rank ?? -1),
                    -$0.firstSeenAt.timeIntervalSince1970, $0.id
                )
                    < (
                        countryRank($1), verdictRank($1), -($1.screening?.rank ?? -1),
                        -$1.firstSeenAt.timeIntervalSince1970, $1.id
                    )
            }
        case .newest:
            return jobs.sorted { ($1.firstSeenAt, $0.id) < ($0.firstSeenAt, $1.id) }
        case .company:
            return jobs.sorted {
                ($0.company.localizedLowercase, $0.title.localizedLowercase, $0.id)
                    < ($1.company.localizedLowercase, $1.title.localizedLowercase, $1.id)
            }
        }
    }

    /// Every word of `search` appears in the title, the company or the place.
    public static func matches(_ job: JobSummary, _ search: String) -> Bool {
        let words = search.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = "\(job.title) \(job.company) \(job.placeLine)".localizedLowercase
        return words.allSatisfy { haystack.contains($0.localizedLowercase) }
    }

    /// How many of `jobs` Kairos first saw today.
    public static func newToday(_ jobs: [JobSummary], now: Date = Date(), calendar: Calendar = .current) -> Int {
        jobs.count { calendar.isDate($0.firstSeenAt, inSameDayAs: now) }
    }

    private static func isUndecided(_ job: JobSummary) -> Bool { job.decision == nil && job.application == nil }

    /// Judged by the AI's analysis or by you; a filter's drop isn't a verdict.
    private static func isJudged(_ job: JobSummary) -> Bool {
        job.verdict != nil && (job.screening?.stage != .filtered || job.screening?.yourVerdict != nil)
    }
}
