import Foundation
import Resume

/// A build's report card: what made the page, how well it fills it, and whether the writing kept
/// your facts. Code only, so builds can be compared before and after a change to the pipeline.
public struct BuildReport: Codable, Sendable, Equatable {
    /// Bullets per role and per project, in the resume's order.
    public var experienceBullets: [Int]
    public var projectBullets: [Int]
    /// Your roles and projects the page leaves out, by title.
    public var leftOut: [String]
    public var certifications: Int
    public var languages: Bool
    /// Bullets dropped to fit the page budget.
    public var dropped: Int
    public var pages: Int?
    /// Lines left empty on the last page, and bullets running a few words onto an extra line; nil
    /// when the template wasn't measured.
    public var freeLines: Double?
    public var shortWraps: Int?
    /// Of the numbers in the bullets each written bullet cites, the share it still states.
    public var numbersKept: Double
    /// Of 100, and its must-have part as a share.
    public var score: Double
    public var mustHaves: Double

    public var bullets: Int { (experienceBullets + projectBullets).reduce(0, +) }

    public init(_ outcome: BuildOutcome, master: MasterResume) {
        self.init(
            resume: outcome.resume, score: outcome.score, layout: outcome.layout, dropped: outcome.dropped,
            master: master)
    }

    /// From a saved build: its resume and score, its layout measured again, and the bullets dropped.
    public init(resume: TailoredResume, score: MatchScore, layout: PageLayout?, dropped: Int, master: MasterResume) {
        experienceBullets = resume.experience.map(\.bullets.count)
        projectBullets = resume.projects.map(\.bullets.count)
        let shown = Set((resume.experience + resume.projects).map(\.entryID))
        leftOut = (master.entries(.experience) + master.entries(.project)).filter { !shown.contains($0.id) }.map {
            switch $0.fields {
            case .experience(let role): "\(role.title), \(role.employer)"
            case .project(let project): project.name
            default: ""
            }
        }
        certifications = resume.certifications.count
        languages = resume.languages != nil
        self.dropped = dropped
        pages = layout?.pages
        let measured = layout.flatMap { $0.isMeasured ? $0 : nil }
        freeLines = measured.map { ($0.freeLines * 10).rounded() / 10 }
        shortWraps = measured.map { $0.bullets.count(where: \.isShortWrap) }
        numbersKept = Self.numbersKept(resume.allBullets, master: master)
        self.score = score.total
        mustHaves = score.breakdown.mustHaves / 40
    }

    /// A number counts as kept when the bullet states the same value its source did ("1,300" or
    /// "1300"). Bullets citing no numbers don't count either way; with none at all, everything's kept.
    static func numbersKept(_ bullets: [TailoredBullet], master: MasterResume) -> Double {
        let sources = Dictionary(
            master.entries.flatMap(\.bullets).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var stated = 0
        var kept = 0
        for bullet in bullets {
            let written = Set(Numbers.mentions(in: bullet.text).map(\.value))
            let cited = Set(
                bullet.sourceIDs.compactMap { sources[$0] }.flatMap { Numbers.mentions(in: $0).map(\.value) })
            stated += cited.count
            kept += cited.intersection(written).count
        }
        return stated == 0 ? 1 : (Double(kept) / Double(stated) * 100).rounded() / 100
    }
}
