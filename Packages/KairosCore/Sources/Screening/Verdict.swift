import Foundation
import Jobs
import Resume

/// What decided a verdict. The raw value is stored, so it never changes.
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
    /// Before job collection v3, a search's snippet was worth a Maybe at most. Stored verdicts may
    /// carry it; nothing makes it now.
    case snippetOnly = "snippet_only"
}

/// How much of a posting's skills, experience, education and languages your master resume shows: a
/// yes is worth 1 and a partial ½, so "3.5 of 5".
public struct Coverage: Codable, Sendable, Equatable {
    public var mustCovered: Double
    public var mustTotal: Int
    public var niceCovered: Double
    public var niceTotal: Int

    public init(mustCovered: Double = 0, mustTotal: Int = 0, niceCovered: Double = 0, niceTotal: Int = 0) {
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

    /// The score shown on rows: the match as a whole percentage.
    public var percent: Int { Int((match * 100).rounded()) }

    public var summary: String {
        "Shows \(mustCovered.formatted()) of \(mustTotal) must-haves and \(niceCovered.formatted()) of \(niceTotal) nice-to-haves."
    }

    /// Work authorization, clearance, a language, a degree, travel or a licence: judged against your
    /// profile rather than your skills (for analyses from the first prompt, which had no categories).
    public static func isCondition(_ text: String) -> Bool {
        let folded = TextScan.fold(text)
        return conditionWords.contains { folded.contains($0) }
    }

    private static let conditionWords = [
        "authoriz", "authoris", "entitled to work", "eligible to work", "right to work", "sponsor", "citizen",
        "permanent resident", "work permit", "visa", "clearance", "reliability status", "french", "english",
        "bilingual",
        "francais", "anglais", "language", "degree", "bachelor", "master's", "masters", "phd", "diploma", "travel",
        "driver", "licence", "license",
    ]
}

public struct VerdictDecision: Sendable, Equatable, Codable {
    public let verdict: Verdict
    public let rule: VerdictRule
    public let coverage: Coverage
    /// For the job's "why": the deciding reason first, then coverage and notes.
    public let reasons: [String]
}

/// Turns an analysis into a verdict: code decides, not the model. Your profile against the
/// posting's flags comes first, then your level and years policy, then how much the resume shows.
public struct VerdictEngine: Sendable {
    public let preferences: SearchPreferences
    public let profile: WorkProfile
    public let speaksFrench: Bool
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

    public func decide(_ analysis: JobAnalysis, for job: Job) -> VerdictDecision {
        let analysis = analysis.recognizingLanguages(languages)
        let coverage = Coverage(analysis)
        let flags = analysis.flags
        var notes = [coverage.summary]
        if flags.french == .asset && !speaksFrench { notes.append("French is an asset.") }
        let country = job.country
        let status = country.flatMap { profile.authorization[$0] }
        // Informational only: never changes a verdict.
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
                return decision(
                    .no, .workAuthorization, "Won't sponsor a visa, and you'd need one in \(country.inSentence).")
            }
            if flags.remoteScope == .remoteCountry {
                return decision(
                    .no, .remoteScope, "Remote in \(country.inSentence) only, where you'd need visa sponsorship.")
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
        if analysis.requirements.contains(where: { $0.kind == .must && $0.category == .enrolment }) {
            switch profile.enrolment {
            case .graduated?:
                return decision(.no, .enrolment, "Asks for a current student, and you've said you've graduated.")
            case .student?: break
            case nil: notes.append("Asks for a current student; set whether you are in Settings, Search.")
            }
        }
        if let level = analysis.seniority, !preferences.seniority.contains(level) {
            return decision(.no, .seniority, "\(level.title) level, which you've turned off.")
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
            return decision(.maybe, .noRequirements, "The posting lists no skills to compare with yours.")
        }
        let share = coverage.mustTotal > 0 ? coverage.must : coverage.nice
        let thresholds = preferences.thresholds
        if share >= thresholds.yesAt {
            if let yearsNote { return decision(.maybe, .yearsAboveYours, yearsNote) }
            return decision(.yes, .strongMatch)
        }
        let gap = Self.missing(analysis)
        return share >= thresholds.maybeAt ? decision(.maybe, .partialMatch, gap) : decision(.no, .weakMatch, gap)
    }

    /// "Missing Rust", "Missing Rust and Scala", "Missing Rust, Scala and 2 more".
    private static func missing(_ analysis: JobAnalysis) -> String? {
        let names = analysis.requirements.filter { $0.kind == .must && $0.counts && $0.effectiveMatch == .no }.map(
            \.text)
        switch names.count {
        case 0: return nil
        case 1: return "Missing \(names[0])"
        case 2: return "Missing \(names[0]) and \(names[1])"
        default: return "Missing \(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// The Inbox's order: verdict first, then your country priority (Canada before the US by default),
/// then match. Higher lists first.
public enum Ranking {
    public static func rank(_ verdict: Verdict, country: Country?, match: Double, countries: [Country]) -> Double {
        let verdictWeight: Double =
            switch verdict {
            case .yes: 2
            case .maybe: 1
            case .no: 0
            }
        let countryWeight = country.flatMap { countries.firstIndex(of: $0) }.map { Double(countries.count - $0) } ?? 0
        return verdictWeight * 100 + countryWeight * 10 + min(max(match, 0), 1)
    }
}

/// Everything screening reads about you, gathered once per run.
public struct ScreeningContext: Sendable {
    public var preferences: SearchPreferences
    public var profile: WorkProfile
    public var resume: MasterResume
    public var applied: [AppliedJob]
    /// Your master resume as evidence, built once (it redacts every line).
    public let evidence: ScreeningProfile

    public init(
        preferences: SearchPreferences = SearchPreferences(), profile: WorkProfile = WorkProfile(),
        resume: MasterResume = MasterResume(), applied: [AppliedJob] = []
    ) {
        self.preferences = preferences
        self.profile = profile
        self.resume = resume
        self.applied = applied
        evidence = ScreeningProfile(resume)
    }

    public func prefilter(now: Date) -> Prefilter {
        Prefilter(preferences: preferences, profile: profile, languages: resume.languages, applied: applied, now: now)
    }

    public var verdicts: VerdictEngine {
        VerdictEngine(
            preferences: preferences, profile: profile, languages: resume.languages,
            totalYears: resume.header.totalYears)
    }

    public func analysisInput(for job: Job) -> AnalyzeJobTask.Input {
        AnalyzeJobTask.Input(job: job, profile: evidence)
    }

    public func rank(_ verdict: Verdict, for job: Job, match: Double) -> Double {
        Ranking.rank(verdict, country: job.country, match: match, countries: preferences.countries)
    }
}
