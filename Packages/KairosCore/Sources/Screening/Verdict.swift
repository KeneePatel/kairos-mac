import Foundation
import MasterResume
import Store

/// How much of a posting your skills must cover (SPEC §5.2, step 6, "your thresholds"). Part of
/// your synced "screening" preferences.
public struct VerdictThresholds: Codable, Sendable, Equatable {
    /// Share of the must-haves your skills cover for a yes.
    public var yesAt: Double
    /// Below this share, a no; between the two, a maybe.
    public var maybeAt: Double
    /// Asking for up to this many years more than you have makes a maybe at best; more is a no.
    public var yearsGrace: Int

    public init(yesAt: Double = 0.75, maybeAt: Double = 0.5, yearsGrace: Int = 2) {
        self.yesAt = yesAt
        self.maybeAt = maybeAt
        self.yearsGrace = yearsGrace
    }

    private enum CodingKeys: String, CodingKey { case yesAt, maybeAt, yearsGrace }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VerdictThresholds()
        yesAt = try container.decodeIfPresent(Double.self, forKey: .yesAt) ?? defaults.yesAt
        maybeAt = try container.decodeIfPresent(Double.self, forKey: .maybeAt) ?? defaults.maybeAt
        yearsGrace = try container.decodeIfPresent(Int.self, forKey: .yearsGrace) ?? defaults.yearsGrace
    }
}

/// What decided a verdict. The raw value is stored in `screening.rule_id`, so it never changes.
public enum VerdictRule: String, Sendable, CaseIterable, Codable {
    case workAuthorization = "work_authorization"
    case remoteScope = "remote_scope"
    case clearance
    case french
    case enrolment
    case seniority
    case yearsRequired = "years_required"
    case yearsAboveYours = "years_above_yours"
    case strongMatch = "strong_match"
    case partialMatch = "partial_match"
    case weakMatch = "weak_match"
    case noRequirements = "no_requirements"
    /// The posting is a search's snippet (Adzuna), so a strong match is only worth a Maybe.
    case snippetOnly = "snippet_only"
}

/// How much of a posting's skills, experience, education and languages your master resume shows:
/// a yes is worth 1 and a partial ½, so "3.5 of 5". Soft skills, location, authorization and
/// availability don't count (the flags and the prefilter judge the last three).
public struct Coverage: Codable, Sendable, Equatable {
    public var mustCovered: Double
    public var mustTotal: Int
    public var niceCovered: Double
    public var niceTotal: Int

    public init(mustCovered: Double, mustTotal: Int, niceCovered: Double, niceTotal: Int) {
        self.mustCovered = mustCovered
        self.mustTotal = mustTotal
        self.niceCovered = niceCovered
        self.niceTotal = niceTotal
    }

    public init(_ analysis: JobAnalysis) {
        let counted = analysis.requirements.filter(\.counts)
        let musts = counted.filter { $0.kind == .must }
        let nices = counted.filter { $0.kind == .nice }
        self.init(
            mustCovered: musts.reduce(0) { $0 + $1.effectiveMatch.credit }, mustTotal: musts.count,
            niceCovered: nices.reduce(0) { $0 + $1.effectiveMatch.credit }, niceTotal: nices.count)
    }

    public var must: Double { mustTotal == 0 ? 0 : mustCovered / Double(mustTotal) }
    public var nice: Double { niceTotal == 0 ? 0 : niceCovered / Double(niceTotal) }

    /// 0 to 1, for ranking: must-haves weigh 80%, nice-to-haves 20%.
    public var match: Double {
        switch (mustTotal, niceTotal) {
        case (0, 0): 0
        case (_, 0): must
        case (0, _): nice
        default: 0.8 * must + 0.2 * nice
        }
    }

    var summary: String {
        "Covers \(mustCovered.formatted()) of \(mustTotal) must-haves and \(niceCovered.formatted()) of \(niceTotal) nice-to-haves."
    }

    /// Work authorization, clearance, a language, a degree, travel or a licence: judged against your
    /// profile rather than your skills.
    public static func isCondition(_ text: String) -> Bool {
        let folded = TextScan.fold(text)
        return conditionWords.contains { folded.contains($0) }
    }

    private static let conditionWords = [
        "authoriz", "authoris", "entitled to work", "eligible to work", "right to work", "sponsor", "citizen",
        "permanent resident", "work permit", "visa", "clearance", "reliability status", "french", "english",
        "bilingual", "francais", "anglais", "language", "degree", "bachelor", "master's", "masters", "phd",
        "diploma", "travel", "driver", "licence", "license",
    ]
}

public struct VerdictDecision: Sendable, Equatable {
    public let verdict: Verdict
    public let rule: VerdictRule
    public let coverage: Coverage
    /// For the job's "why": the deciding reason first, then coverage and notes.
    public let reasons: [String]
}

/// Turns an analysis into a verdict (SPEC §5.2, step 6): code decides, not the model. Your profile
/// against the posting's flags comes first, then your level and years policy, then how much of
/// the posting your skills cover.
public struct VerdictEngine: Sendable {
    public let preferences: SearchPreferences
    public let profile: WorkProfile
    public let speaksFrench: Bool
    /// Your master resume's languages: a requirement naming one counts as shown.
    public let languages: [EntryFields.Language]
    /// From your master resume; nil skips the years-above-yours check.
    public let totalYears: Double?

    public init(
        preferences: SearchPreferences, profile: WorkProfile, languages: [EntryFields.Language], totalYears: Double?
    ) {
        self.preferences = preferences
        self.profile = profile
        self.languages = languages
        self.totalYears = totalYears
        speaksFrench = Prefilter.speaksFrench(languages)
    }

    /// `snippetOnly`: the description is a search's snippet, not the whole posting (Adzuna). What
    /// it shows can still rule a job out, but it can't make it a Yes.
    public func decide(_ analysis: JobAnalysis, for job: Job, snippetOnly: Bool = false) -> VerdictDecision {
        let analysis = analysis.recognizingLanguages(languages)
        let coverage = Coverage(analysis)
        let flags = analysis.flags
        var notes = [coverage.summary]
        if flags.french == .asset && !speaksFrench { notes.append("French is an asset.") }
        let country = job.country
        let status = country.flatMap { profile.authorization[$0] }
        // SPEC §5.9: informational only.
        if country == .unitedStates, status == .needsSponsorship, profile.authorization[.canada] == .citizen,
            flags.sponsorship == .notOffered
        {
            notes.append("Possible TN route: as a Canadian citizen you may qualify for TN status for some professions.")
        }
        func decision(_ verdict: Verdict, _ rule: VerdictRule, _ reason: String? = nil) -> VerdictDecision {
            VerdictDecision(
                verdict: verdict, rule: rule, coverage: coverage, reasons: [reason].compactMap { $0 } + notes)
        }

        if let country, status == .needsSponsorship {
            if flags.sponsorship == .notOffered {
                return decision(.no, .workAuthorization, "Won't sponsor a visa, and you'd need one in \(country.name).")
            }
            if flags.remoteScope == .remoteCountry {
                return decision(.no, .remoteScope, "Remote in \(country.name) only, where you'd need visa sponsorship.")
            }
        }
        if !profile.hasClearance {
            if flags.clearance == .required {
                return decision(.no, .clearance, "Needs a security clearance you don't hold.")
            }
            if flags.clearance == .obtainable, let country, let status, status != .citizen,
                !(country == .canada && status == .permanentResident)
            {
                return decision(
                    .no, .clearance, "Needs a \(country.adjective) security clearance, which needs citizenship.")
            }
        }
        if flags.french == .required && !speaksFrench {
            return decision(.no, .french, "Asks for French, which isn't among your languages.")
        }
        // A student-only posting: judged against your work profile, taken as met while it's unset.
        if analysis.requirements.contains(where: { $0.kind == .must && $0.category == .enrolment }) {
            switch profile.enrolment {
            case .graduated?:
                return decision(.no, .enrolment, "Asks for a current student, and you've said you've graduated.")
            case .student?:
                break
            case nil:
                notes.append("Asks for a current student; set whether you are in Settings, Search.")
            }
        }
        if let level = analysis.seniority, !preferences.seniority.contains(level) {
            return decision(.no, .seniority, "\(level.rawValue.capitalized) level, which you've turned off.")
        }
        var yearsNote: String?
        if let required = analysis.yearsRequired {
            if let limit = preferences.maxYearsRequired, required > limit {
                return decision(.no, .yearsRequired, "Asks for \(required)+ years; your limit is \(limit).")
            }
            if let yours = totalYears, Double(required) > yours {
                let note =
                    "Asks for \(required)+ years; you have \(yours.formatted(.number.precision(.fractionLength(0...1))))."
                if Double(required) > yours + Double(preferences.thresholds.yearsGrace) {
                    return decision(.no, .yearsAboveYours, note)
                }
                yearsNote = note
            }
        }

        if coverage.mustTotal + coverage.niceTotal == 0 {
            if snippetOnly { return decision(.maybe, .snippetOnly, Self.snippetReason) }
            return decision(.maybe, .noRequirements, "The posting lists no skills to compare with yours.")
        }
        let share = coverage.mustTotal > 0 ? coverage.must : coverage.nice
        let thresholds = preferences.thresholds
        if share >= thresholds.yesAt {
            if let yearsNote { return decision(.maybe, .yearsAboveYours, yearsNote) }
            if snippetOnly { return decision(.maybe, .snippetOnly, Self.snippetReason) }
            return decision(.yes, .strongMatch)
        }
        let gap = Self.missing(analysis)
        return share >= thresholds.maybeAt ? decision(.maybe, .partialMatch, gap) : decision(.no, .weakMatch, gap)
    }

    static let snippetReason =
        "Only a snippet of this posting came from Adzuna. Open it to read the rest before you build."

    /// "Missing Rust", "Missing Rust and Scala", "Missing Rust, Scala and 2 more": the counted
    /// must-haves your master resume doesn't show at all.
    private static func missing(_ analysis: JobAnalysis) -> String? {
        let names = analysis.requirements.filter { $0.kind == .must && $0.counts && $0.effectiveMatch == .no }
            .map(\.text)
        switch names.count {
        case 0: return nil
        case 1: return "Missing \(names[0])"
        case 2: return "Missing \(names[0]) and \(names[1])"
        default: return "Missing \(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// The order of Today's list (SPEC §5.2, step 7): verdict first, then your country priority
/// (Canada before the US by default), then match. Stored in `job.rank`; higher lists first.
public enum Ranking {
    public static func rank(_ verdict: Verdict, country: Country?, match: Double, countries: [Country]) -> Double {
        let verdictWeight: Double =
            switch verdict {
            case .yes: 2
            case .maybe: 1
            case .no: 0
            }
        // Your first country weighs most; one you didn't list, or an unknown one, weighs nothing.
        let countryWeight = country.flatMap { countries.firstIndex(of: $0) }.map { Double(countries.count - $0) } ?? 0
        return verdictWeight * 100 + countryWeight * 10 + min(max(match, 0), 1)
    }
}
