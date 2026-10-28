import Foundation

/// How well a build answers the posting, out of 100, in code. Each section
/// gets its own score and the findings a rewrite should fix.
public struct MatchScore: Codable, Sendable, Equatable {
    public enum Section: String, Codable, Sendable, CaseIterable {
        case summary, skills, experience, projects
    }

    /// Points per component; the maximums are the weights the first Kairos tuned.
    public struct Breakdown: Codable, Sendable, Equatable {
        /// Of 40.
        public var mustHaves: Double
        /// Of 10.
        public var niceToHaves: Double
        /// Of 15: requirements shown in bullets beat a skills list.
        public var evidence: Double
        /// Of 10.
        public var domain: Double
        /// Of 10.
        public var metrics: Double
        /// Of 10.
        public var language: Double
        /// Of 5.
        public var structure: Double

        public var total: Double { mustHaves + niceToHaves + evidence + domain + metrics + language + structure }
    }

    public var breakdown: Breakdown
    /// Section raw value → 0 to 100. A section with nothing in it isn't scored.
    public var sections: [String: Double]
    /// Section raw value → what to fix, for `rewriteSection`.
    public var findings: [String: [String]]

    public var total: Double { breakdown.total }

    public func score(_ section: Section) -> Double? { sections[section.rawValue] }
    public func findings(_ section: Section) -> [String] { findings[section.rawValue] ?? [] }

    /// Bullets between these lengths read well; longer ones crowd the page.
    static let bulletLengths = 40...220

    public static func score(_ resume: TailoredResume, for job: JobRequirements, pages: Int? = nil, pageBudget: Int = 1)
        -> MatchScore
    {
        let musts = job.musts.filter { !Requirements.isCondition($0) }
        let nices = job.nices.filter { !Requirements.isCondition($0) }
        let bullets = resume.allBullets.map(\.text)
        let experience = resume.experience.flatMap(\.bullets).map(\.text)
        let projects = resume.projects.flatMap(\.bullets).map(\.text)
        let skills = resume.skills.flatMap(\.skills)
        let summary = resume.summary.map { [$0] } ?? []

        let everything = Evidence(bullets + skills + summary)
        let inBullets = Evidence(bullets)
        let mustCovered = musts.filter(everything.covers)
        let niceCovered = nices.filter(everything.covers)
        let covered = mustCovered + niceCovered
        let shownInBullets = covered.filter(inBullets.covers)
        // Where you worked counts for the domain too: Harbourline Logistics is logistics experience.
        let organizations = (resume.experience + resume.projects).compactMap(\.organization)
        let domainWords = everything.words.union(organizations.flatMap(Keywords.keywords))
        let domains = job.domains.filter { !Keywords.keywords(in: $0).isDisjoint(with: domainWords) }
        let issues = languageIssues(experience) + languageIssues(projects) + languageIssues(summary, verbs: false)
        let fitting = bullets.filter { bulletLengths.contains($0.count) }

        let breakdown = Breakdown(
            mustHaves: 40 * share(mustCovered.count, of: musts.count),
            niceToHaves: 10 * share(niceCovered.count, of: nices.count),
            evidence: 15
                * (covered.isEmpty
                    ? (musts.isEmpty && nices.isEmpty ? 1 : 0) : share(shownInBullets.count, of: covered.count)),
            domain: 10 * share(domains.count, of: job.domains.count),
            metrics: 10 * metricsShare(bullets),
            language: max(0, 10 - 2 * Double(issues.count)),
            structure: 3 * share(fitting.count, of: bullets.count) + 2 * ((pages ?? pageBudget) <= pageBudget ? 1 : 0))

        var sections: [String: Double] = [:]
        var findings: [String: [String]] = [:]
        for (section, texts) in [(Section.experience, experience), (.projects, projects)] where !texts.isEmpty {
            let evidence = Evidence(texts)
            let missing = musts.filter { !evidence.covers($0) }
            let relevance =
                section == .experience
                ? share(musts.count - missing.count, of: musts.count)
                : min(1, Double((musts + nices).filter(evidence.covers).count) / 2)
            let sectionIssues = languageIssues(texts)
            let long = texts.filter { !bulletLengths.contains($0.count) }
            sections[section.rawValue] = rounded(
                100
                    * (0.5 * relevance + 0.2 * metricsShare(texts) + 0.2
                        * max(0, 1 - 0.25 * Double(sectionIssues.count))
                        + 0.1 * share(texts.count - long.count, of: texts.count)))
            var notes: [String] = []
            if section == .experience {
                notes += missing.prefix(4).map {
                    "Not shown in any bullet: \($0). Show it if a cited bullet supports it."
                }
            }
            let withNumbers = texts.filter(hasNumber).count
            if metricsShare(texts) < 1 {
                notes.append(
                    "\(withNumbers) of \(texts.count) bullets have a number; keep every number the cited bullets state."
                )
            }
            notes += sectionIssues
            notes += long.prefix(2).map {
                "Out of \(bulletLengths.lowerBound)–\(bulletLengths.upperBound) characters: “\($0.prefix(50))…”"
            }
            findings[section.rawValue] = notes
        }
        if let text = resume.summary {
            let mentioned = musts.filter { Evidence([text]).covers($0) }
            sections[Section.summary.rawValue] = rounded(
                100
                    * (0.6 * share(mentioned.count, of: min(3, musts.count))
                        + 0.25 * max(0, 1 - 0.25 * Double(languageIssues([text], verbs: false).count))
                        + 0.15 * (text.count <= 450 ? 1 : 0)))
        }
        if !skills.isEmpty {
            let technical = musts.filter { !Keywords.terms(in: $0).isEmpty }
            let listed = technical.filter(Evidence(skills).covers)
            sections[Section.skills.rawValue] =
                100
                * (0.8 * share(listed.count, of: technical.count) + 0.2
                    * ((1...5).contains(resume.skills.count) ? 1 : 0))
        }
        return MatchScore(breakdown: breakdown, sections: sections, findings: findings)
    }

    // MARK: - Parts

    /// What some text shows: its technologies and keywords.
    private struct Evidence {
        let technologies: Set<String>
        let words: Set<String>

        init(_ texts: [String]) {
            technologies = Set(texts.flatMap { Keywords.technologies(in: $0).union([$0.lowercased()]) })
            words = Set(texts.flatMap(Keywords.keywords))
        }

        /// By technology when the requirement names one, else by at least half its keywords.
        func covers(_ requirement: String) -> Bool {
            let terms = Keywords.terms(in: requirement)
            if !terms.isEmpty { return !terms.isDisjoint(with: technologies) }
            let keys = Keywords.keywords(in: requirement)
            guard !keys.isEmpty else { return false }
            return Double(keys.intersection(words).count) >= max(1, Double(keys.count) / 2)
        }
    }

    /// One decimal, so 99.99999999999999 is 100 and stored scores read cleanly.
    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    private static func share(_ part: Int, of whole: Int) -> Double {
        whole == 0 ? 1 : Double(part) / Double(whole)
    }

    /// Full marks when at least 60% of bullets carry a number.
    private static func metricsShare(_ bullets: [String]) -> Double {
        guard !bullets.isEmpty else { return 0 }
        return min(1, share(bullets.filter(hasNumber).count, of: bullets.count) / 0.6)
    }

    private static func hasNumber(_ text: String) -> Bool { !Numbers.mentions(in: text).isEmpty }

    /// Weak openers, first person, buzzwords, and (for bullets) a repeated opening verb.
    static func languageIssues(_ texts: [String], verbs: Bool = true) -> [String] {
        var issues: [String] = []
        var openers: Set<String> = []
        for text in texts {
            let lower = text.lowercased()
            if let weak = ["responsible for", "worked on", "assisted with", "helped with", "involved in"].first(where: {
                lower.hasPrefix($0)
            }) {
                issues.append("“\(text.prefix(40))…” opens with “\(weak)”; lead with what you did.")
            }
            if text.contains(/\b(?:I|my|me)\b/) {
                issues.append("“\(text.prefix(40))…” is in the first person.")
            }
            if let buzzword = ["spearheaded", "leveraged", "synergy", "seamlessly", "results-driven", "passionate"]
                .first(where: { lower.contains($0) })
            {
                issues.append("“\(text.prefix(40))…” uses “\(buzzword)”.")
            }
            let verb = String(lower.prefix { $0.isLetter })
            if verbs, !verb.isEmpty, !openers.insert(verb).inserted {
                issues.append("More than one bullet opens with “\(verb.capitalized)”.")
            }
        }
        return issues
    }
}
