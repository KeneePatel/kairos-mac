import Foundation
import Jobs
import KairosKit
import Resume
import Screening
import Store
import Tailoring

/// Improve: what keeps your Maybe and No jobs from a Yes, as fixes ranked by how many verdicts
/// each could move. A fix groups what several postings ask for (a technology, or the same words),
/// says where your master resume stands on it, and counts the verdicts that would change if those
/// asks were shown, by running the same verdict code on the stored analyses: an upper bound, and no
/// AI call. Reasons no resume changes (your levels, authorization, French) stand apart.
public struct ImproveReport: Sendable, Equatable {
    /// Where your master resume stands on a fix.
    public enum Standing: Sendable, Equatable {
        case proven(String)
        case canDiscuss(String)
        /// Named in a role or project, but not in your Skills.
        case mentioned(String)
        case absent
    }

    public struct Fix: Sendable, Equatable, Identifiable {
        /// "tech:kubernetes" or "text:…".
        public let id: String
        public let title: String
        public let standing: Standing
        /// The postings' own words, one per job.
        public let asks: [String]
        public let jobs: [String]
        /// Verdicts that would become Yes, and No that would become Maybe.
        public let toYes: Int
        public let toMaybe: Int

        public var moves: Int { toYes + toMaybe }
    }

    /// Jobs a reason no resume changes decided.
    public struct Held: Sendable, Equatable, Identifiable {
        public let rule: VerdictRule
        public let jobs: [String]

        public var id: VerdictRule { rule }
    }

    /// Maybe and No jobs the AI analysed.
    public let analysed: Int
    /// Ranked: the most verdicts moved first.
    public let fixes: [Fix]
    public let held: [Held]

    public init(
        jobs: [JobSummary], analyses: [String: StoredAnalysis], details: [String: Job], resume: MasterResume,
        preferences: SearchPreferences, profile: WorkProfile
    ) {
        let engine = VerdictEngine(
            preferences: preferences, profile: profile, languages: resume.languages,
            totalYears: resume.header.totalYears)
        var analysed = 0
        var held: [VerdictRule: [String]] = [:]
        var considered: [(job: Job, analysis: JobAnalysis, verdict: Verdict)] = []
        for summary in jobs where summary.screening?.stage == .judged && summary.verdict != .yes {
            guard let rule = summary.screening?.verdictRule, let stored = analyses[summary.id],
                let job = details[summary.id]
            else { continue }
            analysed += 1
            switch rule {
            case .seniority, .workAuthorization, .remoteScope, .clearance, .french, .enrolment, .yearsRequired:
                held[rule, default: []].append(summary.id)
            case .weakMatch, .partialMatch, .yearsAboveYours:
                let analysis = stored.analysis.recognizingLanguages(resume.languages)
                considered.append((job, analysis, engine.decide(analysis, for: job).verdict))
            case .noRequirements, .strongMatch, .snippetOnly:
                break
            }
        }
        self.analysed = analysed
        self.held = VerdictRule.allCases.compactMap { rule in held[rule].map { Held(rule: rule, jobs: $0) } }

        // Each unmet requirement under every key it names: "Go or Rust" counts toward both.
        var groups: [String: (title: String, asks: [Int: (positions: [Int], text: String)])] = [:]
        var order: [String] = []
        for (index, entry) in considered.enumerated() {
            for (position, requirement) in entry.analysis.requirements.enumerated()
            where requirement.counts && [.no, .partial].contains(requirement.effectiveMatch) {
                for (id, title) in Self.keys(requirement.text) {
                    if groups[id] == nil {
                        groups[id] = (title, [:])
                        order.append(id)
                    }
                    groups[id]?.asks[index, default: ([], requirement.text)].positions.append(position)
                }
            }
        }

        let evidence = Evidence(resume)
        fixes = order.compactMap { id -> Fix? in
            guard let group = groups[id] else { return nil }
            var toYes = 0
            var toMaybe = 0
            for (index, ask) in group.asks {
                let entry = considered[index]
                var analysis = entry.analysis
                for position in ask.positions { analysis.requirements[position].match = .yes }
                let after = engine.decide(analysis, for: entry.job).verdict
                if after == .yes { toYes += 1 } else if after == .maybe, entry.verdict == .no { toMaybe += 1 }
            }
            let indices = group.asks.keys.sorted()
            return Fix(
                id: id, title: group.title, standing: evidence.standing(id: id, title: group.title),
                asks: indices.compactMap { group.asks[$0]?.text }, jobs: indices.map { considered[$0].job.id },
                toYes: toYes, toMaybe: toMaybe)
        }
        .filter { $0.moves > 0 || $0.jobs.count > 1 }
        .sorted { ($0.toYes, $0.moves, $0.jobs.count, $1.title) > ($1.toYes, $1.moves, $1.jobs.count, $0.title) }
    }

    /// A requirement's keys: each technology it names, or else its own words, folded.
    static func keys(_ text: String) -> [(id: String, title: String)] {
        let named = TechVocabulary.technologies(in: text)
        if !named.isEmpty { return named.map { ("tech:\($0.canonical)", $0.written) } }
        let folded = text.folded.split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        return folded.isEmpty ? [] : [("text:\(folded)", text.trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    /// Where a key appears in your master resume.
    struct Evidence {
        let proven: [String: String]
        let canDiscuss: [String: String]
        let mentioned: [String: String]

        init(_ resume: MasterResume) {
            func technologies(_ text: String) -> [String] { TechVocabulary.technologies(in: text).map(\.canonical) }
            var proven: [String: String] = [:]
            var canDiscuss: [String: String] = [:]
            for skill in resume.skills {
                for key in technologies(skill.name) + [skill.name.folded] {
                    if skill.level == .proven { proven[key] = skill.name } else { canDiscuss[key] = skill.name }
                }
            }
            var mentioned: [String: String] = [:]
            for entry in resume.entries {
                for bullet in entry.bullets {
                    for key in technologies(bullet.text) + bullet.skills.map(\.folded) {
                        mentioned[key] = mentioned[key] ?? entry.fields.headline
                    }
                }
            }
            self.proven = proven
            self.canDiscuss = canDiscuss
            self.mentioned = mentioned
        }

        func standing(id: String, title: String) -> Standing {
            let key = id.hasPrefix("tech:") ? String(id.dropFirst(5)) : title.folded
            if let name = proven[key] { return .proven(name) }
            if let name = canDiscuss[key] { return .canDiscuss(name) }
            if let place = mentioned[key] { return .mentioned(place) }
            return .absent
        }
    }
}
