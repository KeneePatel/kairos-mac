import Foundation
import Store

/// `company|title|city`, each folded to plain lowercase words, so the same job reads the same on every board.
public enum DedupKey {
    static let companySuffixes: Set<String> = [
        "inc", "incorporated", "ltd", "limited", "llc", "llp", "corp", "corporation", "co", "company", "gmbh", "plc",
        "the",
    ]
    static let titleAbbreviations: [String: String] = [
        "sr": "senior", "snr": "senior", "jr": "junior", "eng": "engineer", "engr": "engineer", "dev": "developer",
        "mgr": "manager", "swe": "software engineer", "sde": "software engineer", "ml": "machine learning",
    ]

    public static func make(company: String, title: String, city: String?) -> String {
        let companyWords = words(company).filter { !companySuffixes.contains($0) }
        let titleWords = words(title).map { titleAbbreviations[$0] ?? $0 }
        return [companyWords, titleWords, words(city ?? "")].map { $0.joined(separator: " ") }.joined(separator: "|")
    }

    /// The company part, which is how candidates are grouped before any comparing.
    public static func company(of key: String) -> Substring {
        key.prefix { $0 != "|" }
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")).lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Drops postings already stored and cross-board near-duplicates (SPEC §5.2, step 3).
public enum Deduplicator {
    /// Key similarity at or above this, for the same company on a different source, is the same job.
    public static let threshold = 0.9
    /// Looser, on titles, for a snippet whose text is found in the other copy's (job collection v2, J6).
    public static let looseThreshold = 0.7

    /// A job already stored, as far as de-duplication needs it.
    public struct Known: Sendable, Equatable {
        public let sourceID: UUID
        public let dedupKey: String

        public init(sourceID: UUID, dedupKey: String) {
            self.sourceID = sourceID
            self.dedupKey = dedupKey
        }
    }

    /// The candidates worth storing, in order: an id not seen before, and no near-duplicate from
    /// another source among stored jobs or the candidates kept before it. Two postings from the same
    /// source are never duplicates, since a board lists each job once.
    public static func newJobs(_ candidates: [Job], knownIDs: Set<JobID>, existing: [Known]) -> [Job] {
        var seen = knownIDs
        var byCompany = Dictionary(grouping: existing) { DedupKey.company(of: $0.dedupKey) }
        var kept: [Job] = []
        for job in candidates where seen.insert(job.id).inserted {
            let company = DedupKey.company(of: job.dedupKey)
            let duplicate = byCompany[company, default: []].contains { other in
                other.sourceID != job.sourceID && similarity(other.dedupKey, job.dedupKey) >= threshold
            }
            guard !duplicate else { continue }
            kept.append(job)
            byCompany[company, default: []].append(Known(sourceID: job.sourceID, dedupKey: job.dedupKey))
        }
        return kept
    }

    /// Whether two dedup keys name the same job: the same company, the same city when both say,
    /// and titles similar enough.
    public static func isSameJob(_ a: String, _ b: String) -> Bool {
        titleSimilarity(a, b) >= threshold
    }

    /// How alike two jobs' titles are when they're at the same company and, when both say, in the
    /// same city; 0 otherwise. Titles compared alone: on whole keys a shared company and city made
    /// "QA Engineer" and "Data Engineer" 0.91 alike (2026-10-23).
    public static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let x = a.split(separator: "|", omittingEmptySubsequences: false)
        let y = b.split(separator: "|", omittingEmptySubsequences: false)
        guard x.count == 3, y.count == 3, x[0] == y[0], x[2].isEmpty || y[2].isEmpty || x[2] == y[2] else { return 0 }
        return similarity(String(x[1]), String(y[1]))
    }

    /// 1 minus the Levenshtein distance over the longer length: 1 for equal strings, 0 for nothing shared.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1 : 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
