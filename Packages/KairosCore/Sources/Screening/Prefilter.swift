import Foundation
import Jobs
import Resume

/// The prefilter's rules, in the order they run. The raw value is the rule id stored with a
/// prefilter verdict, so it never changes.
public enum PrefilterRule: String, Sendable, CaseIterable, Codable {
    case titleInclude = "title_include"
    case titleExclude = "title_exclude"
    case seniority
    case yearsRequired = "years_required"
    case location
    case remoteScope = "remote_scope"
    case workAuthorization = "work_authorization"
    case clearance
    case french
    case blacklist
    case agency
    case postingAge = "posting_age"
    case alreadyApplied = "already_applied"

    /// The reason group Filtered out lists it under.
    public var title: String {
        switch self {
        case .titleInclude: "Not one of your roles"
        case .titleExclude: "A title you excluded"
        case .seniority: "A level you turned off"
        case .yearsRequired: "Too many years asked"
        case .location: "Outside your places"
        case .remoteScope: "Remote where you'd need a visa"
        case .workAuthorization: "Work authorization"
        case .clearance: "Security clearance"
        case .french: "French required"
        case .blacklist: "A company you blocked"
        case .agency: "Staffing agency"
        case .postingAge: "Posted too long ago"
        case .alreadyApplied: "Already applied"
        }
    }
}

/// Why the prefilter dropped a job: the first rule it failed, and one sentence you can read.
public struct Rejection: Sendable, Equatable, Codable {
    public let rule: PrefilterRule
    public let reason: String

    public init(rule: PrefilterRule, reason: String) {
        self.rule = rule
        self.reason = reason
    }
}

/// A job you applied to, for the "already applied" rule.
public struct AppliedJob: Sendable, Equatable {
    public let company: String
    public let title: String

    public init(company: String, title: String) {
        self.company = company
        self.title = title
    }
}

/// The deterministic first pass over each new job: free, instant, and run before any AI call. Rules
/// run in a fixed order and the first one a job fails is recorded. When a rule can't tell (no text,
/// a country you haven't set), the job stays in.
public struct Prefilter: Sendable {
    public let preferences: SearchPreferences
    public let profile: WorkProfile
    /// French at conversational level or better among your languages.
    public let speaksFrench: Bool
    public let applied: [AppliedJob]
    public let now: Date

    public init(
        preferences: SearchPreferences, profile: WorkProfile, languages: [EntryFields.Language],
        applied: [AppliedJob] = [], now: Date = Date()
    ) {
        self.preferences = preferences
        self.profile = profile
        self.applied = applied
        self.now = now
        speaksFrench = Self.speaksFrench(languages)
    }

    static func speaksFrench(_ languages: [EntryFields.Language]) -> Bool {
        languages.contains { language in
            TextScan.containsAny(TextScan.fold(language.language), ["french", "francais"]) && language.proficiency != .basic
        }
    }

    /// The first rule `job` fails, or nil when it passes them all.
    public func rejection(for job: Job) -> Rejection? {
        let posting = Reading(job)
        let rules: [(Reading) -> Rejection?] = [
            titleInclude, titleExclude, seniority, yearsRequired, location, remoteScope, workAuthorization, clearance,
            french, blacklist, agency, postingAge, alreadyApplied,
        ]
        for rule in rules {
            if let rejection = rule(posting) { return rejection }
        }
        return nil
    }

    private func titleInclude(_ posting: Reading) -> Rejection? {
        let phrases = preferences.titleInclude.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !preferences.roles.isEmpty else {
            guard !phrases.isEmpty, !TextScan.containsAny(posting.title, phrases) else { return nil }
            return Rejection(rule: .titleInclude, reason: "The title has none of your phrases (\(phrases.joined(separator: ", "))).")
        }
        guard !preferences.roleMatcher.matches(posting.job.title) else { return nil }
        let roles = RoleFamily.allCases.filter(preferences.roles.contains).map(\.title)
        return Rejection(
            rule: .titleInclude,
            reason: "The title isn't one of your roles (\(roles.joined(separator: "; ")))"
                + (phrases.isEmpty ? "." : " or other titles (\(phrases.joined(separator: ", "))).")
        )
    }

    private func titleExclude(_ posting: Reading) -> Rejection? {
        guard let phrase = preferences.titleExclude.first(where: { TextScan.containsPhrase(posting.title, $0) }) else {
            return nil
        }
        return Rejection(rule: .titleExclude, reason: "The title has “\(phrase)”, which you excluded.")
    }

    private func seniority(_ posting: Reading) -> Rejection? {
        guard let level = Seniority.of(title: posting.job.title), !preferences.seniority.contains(level) else { return nil }
        return Rejection(rule: .seniority, reason: "\(level.title) level, which you've turned off.")
    }

    private func yearsRequired(_ posting: Reading) -> Rejection? {
        guard let limit = preferences.maxYearsRequired, let years = YearsParser.requiredYears(inSentences: posting.sentences),
            years > limit
        else { return nil }
        return Rejection(rule: .yearsRequired, reason: "Asks for \(years)+ years; your limit is \(limit).")
    }

    private func location(_ posting: Reading) -> Rejection? {
        let job = posting.job
        if job.remoteScope.isRemote && !preferences.remoteAllowed {
            return Rejection(rule: .location, reason: "Remote, and you're looking for on-site or hybrid work.")
        }
        if let country = job.country, !preferences.countries.contains(country), job.remoteScope != .remoteAnywhere {
            return Rejection(rule: .location, reason: "In \(country.inSentence), which isn't one of your countries.")
        }
        if !job.remoteScope.isRemote, let country = job.country, let region = job.region,
            let allowed = preferences.regions[country.rawValue], !allowed.isEmpty, !allowed.contains(region)
        {
            return Rejection(rule: .location, reason: "In \(region); you're looking in \(allowed.joined(separator: ", ")).")
        }
        return nil
    }

    /// "Remote (US only)" means living and working in the US.
    private func remoteScope(_ posting: Reading) -> Rejection? {
        let job = posting.job
        let country: Country? =
            switch job.remoteScope {
            case .remoteCountry: job.country
            case .remote, .remoteAnywhere, .unknown: Signals.residencyCountry(posting.sentences)
            case .onsite, .hybrid: nil
            }
        guard let country, profile.authorization[country] == .needsSponsorship else { return nil }
        return Rejection(rule: .remoteScope, reason: "Remote in \(country.inSentence) only, where you'd need visa sponsorship.")
    }

    private func workAuthorization(_ posting: Reading) -> Rejection? {
        for need in Signals.authorizationNeeds(posting.sentences) {
            guard let country = need.country ?? posting.job.country, let status = profile.authorization[country] else {
                continue
            }
            switch need.kind {
            case .noSponsorship where status == .needsSponsorship:
                return Rejection(rule: .workAuthorization, reason: "Won't sponsor a visa, and you'd need one in \(country.inSentence).")
            case .authorization where status == .needsSponsorship:
                return Rejection(rule: .workAuthorization, reason: "Needs you to be authorized to work in \(country.inSentence) already.")
            case .citizenship where status != .citizen:
                return Rejection(rule: .workAuthorization, reason: "Needs \(country.adjective) citizenship.")
            default:
                continue
            }
        }
        return nil
    }

    private func clearance(_ posting: Reading) -> Rejection? {
        guard !profile.hasClearance else { return nil }
        for need in Signals.clearanceNeeds(posting.sentences) {
            switch need {
            case .hold:
                return Rejection(rule: .clearance, reason: "Needs a security clearance you don't hold.")
            case .obtain(let named):
                // Clearances need citizenship; Canada's Reliability Status is open to permanent residents too.
                guard let country = named ?? posting.job.country, let status = profile.authorization[country],
                    status != .citizen, !(country == .canada && status == .permanentResident)
                else { continue }
                return Rejection(rule: .clearance, reason: "Needs a \(country.adjective) security clearance, which needs citizenship.")
            }
        }
        return nil
    }

    private func french(_ posting: Reading) -> Rejection? {
        guard !speaksFrench else { return nil }
        if TextScan.isFrench(posting.job.title + "\n" + posting.job.description) {
            return Rejection(rule: .french, reason: "Written in French, which isn't among your languages.")
        }
        guard Signals.requiresFrench(posting.sentences, country: posting.job.country) else { return nil }
        return Rejection(rule: .french, reason: "Asks for French, which isn't among your languages.")
    }

    private func blacklist(_ posting: Reading) -> Rejection? {
        let company = Self.companyWords(posting.job.company)
        guard
            let blocked = preferences.blacklist.first(where: { name in
                let words = Self.companyWords(name)
                return !words.isEmpty && Self.contains(company, words)
            })
        else { return nil }
        return Rejection(rule: .blacklist, reason: "You've blocked \(blocked).")
    }

    private func agency(_ posting: Reading) -> Rejection? {
        guard !preferences.showAgencies, Agencies.isAgency(company: posting.job.company, text: posting.job.description)
        else { return nil }
        return Rejection(rule: .agency, reason: "Posted by a staffing agency (\(posting.job.company)).")
    }

    private func postingAge(_ posting: Reading) -> Rejection? {
        guard let days = preferences.maxAgeDays, let posted = posting.job.postedAt,
            posted < now.addingTimeInterval(-Double(days) * 86_400)
        else { return nil }
        let age = Int(now.timeIntervalSince(posted) / 86_400)
        return Rejection(rule: .postingAge, reason: "Posted \(age) days ago; your limit is \(days).")
    }

    /// Same company and a title with at least 80% of its words in common.
    private func alreadyApplied(_ posting: Reading) -> Rejection? {
        let company = Self.companyWords(posting.job.company)
        let title = Set(TextScan.words(posting.title))
        guard
            let match = applied.first(where: { applied in
                let other = Set(TextScan.words(TextScan.fold(applied.title)))
                let shared = Double(title.intersection(other).count) / Double(max(title.union(other).count, 1))
                return Self.companyWords(applied.company) == company && shared >= 0.8
            })
        else { return nil }
        return Rejection(rule: .alreadyApplied, reason: "You applied to “\(match.title)” at \(match.company).")
    }

    /// Whether `job` is a copy of a posting you applied to: the same company and a title with at
    /// least 80% of its words in common, or the same title and text under another company name (one
    /// posting listed twice, as Himalayas did for a foundation and its lab). A copy leaves the Inbox
    /// when you apply.
    public static func isCopy(_ job: Job, of applied: Job) -> Bool {
        guard job.id != applied.id else { return false }
        let title = Set(TextScan.words(TextScan.fold(job.title)))
        let other = Set(TextScan.words(TextScan.fold(applied.title)))
        let shared = Double(title.intersection(other).count) / Double(max(title.union(other).count, 1))
        if companyWords(job.company) == companyWords(applied.company), shared >= 0.8 { return true }
        let text = job.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shared >= 0.999, text.count >= 200 else { return false }
        return text == applied.description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A company's name without legal suffixes: "Amazon.com Services LLC" is amazon, com, services.
    static func companyWords(_ name: String) -> [String] {
        TextScan.words(TextScan.fold(name)).filter { !companySuffixes.contains($0) }
    }

    private static let companySuffixes: Set = [
        "inc", "incorporated", "llc", "ltd", "limited", "corp", "corporation", "co", "plc", "gmbh", "ulc", "lp", "llp",
        "ltee", "the",
    ]

    private static func contains(_ text: [String], _ words: [String]) -> Bool {
        guard words.count <= text.count else { return false }
        return (0...(text.count - words.count)).contains { Array(text[$0..<($0 + words.count)]) == words }
    }
}

/// A job read once for all the rules: its folded title and its required sentences.
private struct Reading {
    let job: Job
    let title: String
    let sentences: [String]

    init(_ job: Job) {
        self.job = job
        title = TextScan.fold(job.title)
        sentences = TextScan.requiredSentences(job.description)
    }
}
