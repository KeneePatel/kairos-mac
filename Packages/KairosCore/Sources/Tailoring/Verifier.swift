import Foundation
import MasterResume

/// A bullet a writer produced (SPEC §5.3, Write): its text and the master-resume bullets it cites.
public struct TailoredBullet: Codable, Sendable, Equatable {
    public var text: String
    public var sourceIDs: [UUID]
    /// A stretch-mode bullet covering a requirement the master resume doesn't.
    public var gap: Bool
    /// How well its sources matched the job (the selector's score): page fitting drops the lowest.
    public var rank: Double
    /// The requirement a gap bullet answers, for "Be ready to discuss".
    public var covers: String?

    /// Backed by your master resume. A gap bullet isn't, so it's stored `verified: false` and listed
    /// to prepare (SPEC §5.3, Flagging); the PDF never marks it.
    public var verified: Bool { !gap }

    public init(text: String, sourceIDs: [UUID], gap: Bool = false, rank: Double = 0, covers: String? = nil) {
        self.text = text
        self.sourceIDs = sourceIDs
        self.gap = gap
        self.rank = rank
        self.covers = covers
    }

    private enum CodingKeys: String, CodingKey { case text, sourceIDs, gap, rank, covers, verified }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        sourceIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceIDs) ?? []
        gap = try container.decodeIfPresent(Bool.self, forKey: .gap) ?? false
        rank = try container.decodeIfPresent(Double.self, forKey: .rank) ?? 0
        covers = try container.decodeIfPresent(String.self, forKey: .covers)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(sourceIDs, forKey: .sourceIDs)
        try container.encode(gap, forKey: .gap)
        try container.encode(rank, forKey: .rank)
        try container.encodeIfPresent(covers, forKey: .covers)
        try container.encode(verified, forKey: .verified)
    }
}

/// A rule the verifier enforces. Raw values are what reports and stored builds use.
public enum VerificationRule: String, Sendable, CaseIterable, Codable {
    case missingSource = "missing_source"
    case unknownSource = "unknown_source"
    case gapNotAllowed = "gap_not_allowed"
    case unsupportedTechnology = "unsupported_technology"
    case unsupportedNumber = "unsupported_number"
    case yearsOverstated = "years_overstated"
    case employerOrTitle = "employer_or_title"
    case dates
    case credential
    case hiringCompanyProduct = "hiring_company_product"
    case personalField = "personal_field"
}

public struct Violation: Sendable, Equatable {
    public let rule: VerificationRule
    /// The bullet or field that broke it.
    public let text: String
    /// What exactly, in a sentence.
    public let detail: String
}

/// Checks every claim in a build against the master resume (SPEC §5.3, Verify). Code decides, not
/// the model.
///
/// - Strict mode: a bullet cites existing master-resume bullets; it names only technologies in
///   those bullets or your Proven skills, and only numbers from those bullets.
/// - Stretch mode: a gap bullet needs no source, may use a Can-discuss skill and estimate a number,
///   but claims no degree, certification, licence, title or promotion your master resume lacks.
/// - Every mode: employers, titles and dates match an experience exactly; degrees and
///   certifications exist; no claim exceeds your total years; nothing names the hiring company or
///   its products unless your master resume does; no personal fields.
public struct Verifier: Sendable {
    public enum Mode: String, Sendable, Codable { case strict, stretch }

    public let resume: MasterResume
    public let mode: Mode
    public let hiringCompany: String?
    public let companyProducts: [String]

    private let bullets: [UUID: ResumeBullet]
    private let provenTechnologies: Set<String>
    private let canDiscussTechnologies: Set<String>
    /// Technologies any master-resume bullet names, for text that cites none (a summary).
    private let resumeTechnologies: Set<String>
    private let resumeNumbers: [Double]
    /// Everything your master resume says, for the hiring-company rule.
    private let resumeText: String
    /// Your degrees and certifications as they may be written, normalized.
    private let credentials: Set<String>

    public init(
        resume: MasterResume, mode: Mode = .strict, hiringCompany: String? = nil, companyProducts: [String] = []
    ) {
        self.resume = resume
        self.mode = mode
        self.hiringCompany = hiringCompany
        self.companyProducts = companyProducts
        let all = resume.entries.flatMap(\.bullets)
        bullets = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func technologies(of skills: [Skill]) -> Set<String> {
            Set(skills.flatMap { Keywords.technologies(in: $0.name).union([$0.name.lowercased()]) })
        }
        provenTechnologies = technologies(of: resume.skills.filter { $0.level == .proven })
        canDiscussTechnologies = technologies(of: resume.skills.filter { $0.level == .canDiscuss })
        resumeTechnologies = Set(all.flatMap { Self.technologies(of: $0) })
        resumeNumbers = all.flatMap { Numbers.values(in: ([$0.text] + $0.metrics).joined(separator: " ")) }
        resumeText = (all.map(\.text) + resume.entries.compactMap(Self.employer)).joined(separator: "\n")
        var credentials: Set<String> = []
        for entry in resume.entries {
            switch entry.fields {
            case .education(let education):
                credentials.formUnion([
                    education.credential, "\(education.credential), \(education.field)",
                    "\(education.credential) in \(education.field)", "\(education.credential) \(education.field)",
                ])
            case .certification(let certification):
                credentials.insert(certification.name)
            default:
                continue
            }
        }
        self.credentials = Set(credentials.map(Self.normalized).filter { !$0.isEmpty })
    }

    // MARK: - Bullets

    public func check(_ bullet: TailoredBullet) -> [Violation] {
        let text = bullet.text
        let personal = personalFields(in: text)
        guard personal.isEmpty else { return personal }
        let gapInStretch = bullet.gap && mode == .stretch
        var violations: [Violation] = []
        if bullet.gap && mode == .strict {
            violations.append(Violation(rule: .gapNotAllowed, text: text, detail: "Strict mode has no gap bullets."))
        }
        let sources = bullet.sourceIDs.compactMap { bullets[$0] }
        if !gapInStretch {
            if bullet.sourceIDs.isEmpty {
                violations.append(
                    Violation(rule: .missingSource, text: text, detail: "It cites no master-resume bullet."))
            } else if sources.count < bullet.sourceIDs.count {
                violations.append(
                    Violation(
                        rule: .unknownSource, text: text, detail: "It cites a bullet your master resume doesn't have."))
            }
        }
        var allowed = provenTechnologies.union(sources.flatMap { Self.technologies(of: $0) })
        if gapInStretch { allowed.formUnion(canDiscussTechnologies) }
        violations += technologies(
            in: text, allowed: allowed,
            source: gapInStretch ? "your Proven or Can-discuss skills" : "the cited bullets or your Proven skills")
        let years = Numbers.yearsClaims(in: text)
        violations += overstated(years.map(\.value), in: text)
        if !gapInStretch {
            let known = sources.flatMap { Numbers.values(in: ([$0.text] + $0.metrics).joined(separator: " ")) }
            violations += numbers(in: text, excluding: years.map(\.range), known: known, source: "the cited bullets")
        }
        violations += hiringCompany(in: text)
        if gapInStretch { violations += inventedClaims(in: text) }
        return violations
    }

    // MARK: - Other text

    /// Text that cites no bullet, such as the summary: technologies from your skills or any
    /// master-resume bullet, numbers from any bullet, years up to your total.
    public func check(text: String) -> [Violation] {
        let personal = personalFields(in: text)
        guard personal.isEmpty else { return personal }
        let years = Numbers.yearsClaims(in: text)
        return technologies(
            in: text, allowed: provenTechnologies.union(resumeTechnologies), source: "your Proven skills or bullets")
            + overstated(years.map(\.value), in: text)
            + numbers(in: text, excluding: years.map(\.range), known: resumeNumbers, source: "your master resume")
            + hiringCompany(in: text)
    }

    /// A cover letter's text (SPEC §5.3, Cover letter): the summary's rules, except that it may name
    /// the company you're writing to (never its products), and it may not claim a degree,
    /// certification or licence your master resume doesn't list.
    public func check(letter text: String) -> [Violation] {
        let personal = personalFields(in: text)
        guard personal.isEmpty else { return personal }
        let years = Numbers.yearsClaims(in: text)
        return technologies(
            in: text, allowed: provenTechnologies.union(resumeTechnologies), source: "your Proven skills or bullets")
            + overstated(years.map(\.value), in: text)
            + numbers(in: text, excluding: years.map(\.range), known: resumeNumbers, source: "your master resume")
            + hiringCompany(in: text, names: companyProducts)
            + inventedCredential(in: text)
    }

    /// An experience as the build shows it: employer, title and dates as in your master resume.
    public func check(employer: String, title: String, start: YearMonth?, end: YearMonth?) -> [Violation] {
        let shown = "\(title), \(employer)"
        let roles = resume.entries(.experience)
        guard
            let role = roles.first(where: { entry in
                guard case .experience(let fields) = entry.fields else { return false }
                return Self.same(fields.employer, employer) && Self.same(fields.title, title)
            })
        else {
            return [
                Violation(
                    rule: .employerOrTitle, text: shown,
                    detail: "“\(title)” at “\(employer)” isn't in your master resume.")
            ]
        }
        let expectedEnd = role.isCurrent ? nil : role.end
        guard role.start == start && expectedEnd == end else {
            return [Violation(rule: .dates, text: shown, detail: "The dates differ from your master resume's.")]
        }
        return []
    }

    /// A degree, certification or licence the build shows.
    public func check(credential: String) -> [Violation] {
        guard !credentials.contains(Self.normalized(credential)) else { return [] }
        return [
            Violation(rule: .credential, text: credential, detail: "“\(credential)” isn't in your master resume.")
        ]
    }

    // MARK: - Rules

    private func technologies(in text: String, allowed: Set<String>, source: String) -> [Violation] {
        Keywords.mentions(in: text).filter { !allowed.contains($0.canonical) }.map {
            Violation(rule: .unsupportedTechnology, text: text, detail: "“\($0.written)” isn't in \(source).")
        }
    }

    private func numbers(in text: String, excluding: [Range<String.Index>], known: [Double], source: String)
        -> [Violation]
    {
        Numbers.mentions(in: text).filter { mention in
            !excluding.contains { $0.overlaps(mention.range) }
                && !known.contains { abs($0 - mention.value) < 0.000_1 * max(1, abs(mention.value)) }
        }
        .map {
            Violation(rule: .unsupportedNumber, text: text, detail: "“\(text[$0.range])” isn't in \(source).")
        }
    }

    private func overstated(_ years: [Double], in text: String) -> [Violation] {
        guard let total = resume.header.totalYears else { return [] }
        return years.filter { $0 > total }.map {
            Violation(
                rule: .yearsOverstated, text: text,
                detail: "It claims \(Int($0)) years; your master resume says \(total.formatted()).")
        }
    }

    /// One violation at most: the first name it finds.
    private func hiringCompany(in text: String, names: [String]? = nil) -> [Violation] {
        let names = (names ?? [hiringCompany].compactMap { $0 } + companyProducts).filter { !$0.isEmpty }
        guard
            let name = names.first(where: { Keywords.contains($0, in: text) && !Keywords.contains($0, in: resumeText) })
        else { return [] }
        return [
            Violation(
                rule: .hiringCompanyProduct, text: text,
                detail: "“\(name)” belongs to the company you're applying to, and your master resume doesn't name it.")
        ]
    }

    /// A gap bullet cites nothing, so it may not claim a credential (unless it names one of yours
    /// exactly), a title or a promotion: those are hard limits (SPEC §5.3).
    private func inventedClaims(in text: String) -> [Violation] {
        var violations = inventedCredential(in: text)
        if text.contains(Self.titleClaim) {
            violations.append(
                Violation(
                    rule: .employerOrTitle, text: text,
                    detail: "It claims a title or promotion; titles stay as your master resume has them."))
        }
        return violations
    }

    private func inventedCredential(in text: String) -> [Violation] {
        let normalizedText = Self.normalized(text)
        guard text.contains(Self.credentialClaim), !credentials.contains(where: { normalizedText.contains($0) })
        else { return [] }
        return [
            Violation(
                rule: .credential, text: text,
                detail: "It claims a degree, certification or licence your master resume doesn't list.")
        ]
    }

    private static var credentialClaim: Regex<Substring> {
        /(?i)\b(?:certified|certifications?|degree in|diploma|bachelor'?s?|master'?s|msc|bsc|beng|meng|mba|ph\.?d|doctorate|licen[cs]ed|p\.?\s?eng)\b/
    }

    private static var titleClaim: Regex<Substring> {
        /(?i)\bpromoted\b|\bas (?:a |an |the )?(?:senior|lead|staff|principal|team lead|tech lead|technical lead|head of|engineering manager|manager|director)\b/
    }

    /// North American resumes leave these out (SPEC §5.3, hard limits).
    private func personalFields(in text: String) -> [Violation] {
        let patterns: [(String, Regex<Substring>)] = [
            ("date of birth", /(?i)\b(?:date of birth|d\.?o\.?b\.?|born (?:on|in))\b/),
            ("a SIN or SSN", /\b(?:SIN|SSN)\b|(?i)\bsocial (?:insurance|security)\b/),
            ("marital status", /(?i)\b(?:marital status|married|divorced|widowed)\b/),
            ("a photo", /(?i)\b(?:headshot|photo (?:attached|enclosed|of me))\b/),
        ]
        return patterns.filter { text.contains($0.1) }.map {
            Violation(rule: .personalField, text: text, detail: "It mentions \($0.0), which resumes here leave out.")
        }
    }

    // MARK: - Helpers

    private static func technologies(of bullet: ResumeBullet) -> Set<String> {
        Keywords.technologies(in: bullet.text).union(bullet.skills.flatMap { Keywords.technologies(in: $0) })
            .union(bullet.skills.map { $0.lowercased() })
    }

    private static func employer(_ entry: ResumeEntry) -> String? {
        if case .experience(let fields) = entry.fields { return fields.employer }
        return nil
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces) == b.trimmingCharacters(in: .whitespaces)
    }

    /// Spacing, case and dash style don't make a different credential.
    private static func normalized(_ text: String) -> String {
        text.lowercased().replacing("–", with: "-").replacing("—", with: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Numbers in text: "4.2M" is 4,200,000, "40%" is 40, "30+" is 30. Digits inside a name ("p99",
/// "S3") and years written as dates ("2022") aren't claims of their own.
enum Numbers {
    struct Mention {
        let value: Double
        let range: Range<String.Index>
    }

    static func mentions(in text: String) -> [Mention] {
        let pattern =
            /(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?(\s*(?:million|billion|thousand|[kmbx])(?![A-Za-z]))?(?![A-Za-z0-9])/
            .ignoresCase()
        return text.matches(of: pattern).compactMap { match in
            let range = match.range
            if range.lowerBound > text.startIndex {
                let before = text[text.index(before: range.lowerBound)]
                if before.isLetter || before.isNumber || before == "." { return nil }
            }
            guard let whole = Double(match.output.1.replacing(",", with: "") + (match.output.2 ?? ""))
            else { return nil }
            let suffix = match.output.3.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if suffix.isEmpty, match.output.2 == nil, (1950...2100).contains(whole) { return nil }  // a year
            let scale: Double =
                switch suffix {
                case "k", "thousand": 1_000
                case "m", "million": 1_000_000
                case "b", "billion": 1_000_000_000
                default: 1
                }
            return Mention(value: whole * scale, range: range)
        }
    }

    static func values(in text: String) -> [Double] {
        mentions(in: text).map(\.value)
    }

    /// "5 years", "8+ yrs": claims about experience, judged against your total years.
    static func yearsClaims(in text: String) -> [Mention] {
        text.matches(of: /(\d{1,2})\s*\+?\s*(?:years?|yrs?)\b/.ignoresCase()).compactMap { match in
            Double(match.output.1).map { Mention(value: $0, range: match.range) }
        }
    }
}
