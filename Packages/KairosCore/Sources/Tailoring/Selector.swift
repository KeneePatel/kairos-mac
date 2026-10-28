import Foundation
import Resume

public struct RankedBullet: Sendable, Equatable {
    public let bullet: ResumeBullet
    public let score: Double
    /// The requirement technologies it shows, canonical and sorted.
    public let matched: [String]
}

public struct SelectedEntry: Sendable, Equatable {
    public let entry: ResumeEntry
    public let bullets: [RankedBullet]
    public let score: Double
}

/// The master-resume entries a build may use: roles most recent first with
/// their best bullets, the most relevant projects, and your Proven skills, matching ones first.
public struct Selection: Sendable, Equatable {
    public let experience: [SelectedEntry]
    public let projects: [SelectedEntry]
    public let skills: [Skill]
}

/// Scores every bullet and project by overlap with the requirements (technologies through
/// `Synonyms.json`, then plain keywords at half weight), with a small bonus for numbers and a
/// recency factor between roles. Code decides.
public struct Selector: Sendable {
    /// Bullets kept per role, most recent role first; the last count repeats. Generous by default:
    /// the writers get more than fits, and the page fitter keeps what earns its lines.
    public let maxBulletsPerRole: [Int]
    public let maxProjects: Int
    public let now: Date

    public init(maxBulletsPerRole: [Int] = [6], maxProjects: Int = 4, now: Date = Date()) {
        self.maxBulletsPerRole = maxBulletsPerRole.isEmpty ? [3] : maxBulletsPerRole
        self.maxProjects = maxProjects
        self.now = now
    }

    private struct Requirement {
        let weight: Double
        let technologies: Set<String>
        let words: Set<String>
    }

    public func select(from resume: MasterResume, for job: JobRequirements) -> Selection {
        let requirements =
            job.musts.map { requirement($0, weight: 2) } + job.nices.map { requirement($0, weight: 1) }

        let roles = resume.entries(.experience).sorted { recencyKey($0) > recencyKey($1) }
        let experience = roles.enumerated().map { index, entry in
            let cap = maxBulletsPerRole[min(index, maxBulletsPerRole.count - 1)]
            let ranked = rank(entry.bullets, against: requirements)
            return SelectedEntry(
                entry: entry, bullets: Array(ranked.prefix(max(cap, 1))), score: ranked.first?.score ?? 0)
        }

        let projects = resume.entries(.project).enumerated().map { index, entry -> (SelectedEntry, Int) in
            let ranked = rank(entry.bullets, against: requirements)
            var claims: Set<String> = []
            if case .project(let project) = entry.fields {
                claims = Set(project.tech.flatMap { Keywords.technologies(in: $0) })
            }
            claims.formUnion(entry.bullets.flatMap { technologies(of: $0) })
            let words = Set(entry.bullets.flatMap { Keywords.keywords(in: $0.text) })
            let score = overlap(claims, words, requirements).score * recency(entry)
            return (SelectedEntry(entry: entry, bullets: ranked, score: score), index)
        }
        .sorted { ($0.0.score, -$0.1) > ($1.0.score, -$1.1) }
        let relevant = projects.filter { $0.0.score > 0 }.map(\.0)
        let chosen = relevant.isEmpty ? Array(projects.prefix(1).map(\.0)) : Array(relevant.prefix(maxProjects))

        return Selection(experience: experience, projects: chosen, skills: skills(resume.skills, requirements))
    }

    // MARK: - Scoring

    private func requirement(_ text: String, weight: Double) -> Requirement {
        Requirement(weight: weight, technologies: Keywords.terms(in: text), words: Keywords.keywords(in: text))
    }

    /// Best first; ties keep the master resume's order.
    private func rank(_ bullets: [ResumeBullet], against requirements: [Requirement]) -> [RankedBullet] {
        bullets.enumerated().map { index, bullet -> (RankedBullet, Int) in
            let (score, matched) = overlap(technologies(of: bullet), Keywords.keywords(in: bullet.text), requirements)
            let numbers = !bullet.metrics.isEmpty || bullet.text.contains(where: \.isNumber)
            return (RankedBullet(bullet: bullet, score: score + (numbers ? 0.25 : 0), matched: matched.sorted()), index)
        }
        .sorted { ($0.0.score, -$0.1) > ($1.0.score, -$1.1) }
        .map(\.0)
    }

    /// Each requirement counts once: fully for a shared technology, half for a shared keyword.
    private func overlap(_ technologies: Set<String>, _ words: Set<String>, _ requirements: [Requirement]) -> (
        score: Double, matched: Set<String>
    ) {
        var score = 0.0
        var matched: Set<String> = []
        for requirement in requirements {
            let shared = requirement.technologies.intersection(technologies)
            if !shared.isEmpty {
                score += requirement.weight
                matched.formUnion(shared)
            } else if !requirement.words.isDisjoint(with: words) {
                score += requirement.weight / 2
            }
        }
        return (score, matched)
    }

    private func technologies(of bullet: ResumeBullet) -> Set<String> {
        Keywords.technologies(in: bullet.text).union(bullet.skills.flatMap { Keywords.technologies(in: $0) })
    }

    /// Proven skills only (design rule 8), the ones a requirement names first, in requirement order.
    private func skills(_ skills: [Skill], _ requirements: [Requirement]) -> [Skill] {
        let proven = skills.filter { $0.level == .proven }
        func firstRequirement(_ skill: Skill) -> Int {
            let names = Keywords.technologies(in: skill.name).union([skill.name.lowercased()])
            return requirements.firstIndex { !$0.technologies.isDisjoint(with: names) } ?? Int.max
        }
        return proven.enumerated().sorted {
            (firstRequirement($0.element), $0.offset) < (firstRequirement($1.element), $1.offset)
        }
        .map(\.element)
    }

    // MARK: - Recency

    /// Current roles first, then by end date, then by start date.
    private func recencyKey(_ entry: ResumeEntry) -> (Int, Int, Int) {
        let end = entry.end.map { $0.year * 12 + $0.month } ?? 0
        let start = entry.start.map { $0.year * 12 + $0.month } ?? 0
        return (entry.isCurrent ? 1 : 0, end, start)
    }

    /// 1 for current work, 0.85 for each year since it ended, never below 0.4.
    private func recency(_ entry: ResumeEntry) -> Double {
        guard !entry.isCurrent, let end = entry.end else { return 1 }
        let months = end.months(until: YearMonth.containing(now))
        return max(0.4, pow(0.85, Double(max(0, months)) / 12))
    }
}
