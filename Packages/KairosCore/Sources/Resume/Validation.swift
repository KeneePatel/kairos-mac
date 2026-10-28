import Foundation

/// Phone numbers in E.164 form ("+14165550123"), with +1 assumed when no country code is given.
public enum PhoneNumber {
    private static let allowed = Set("0123456789 -.()")

    /// The E.164 form, or nil if it can't be a full number. Extensions aren't kept, so a number with
    /// one is refused rather than silently shortened.
    public static func e164(_ text: String) -> String? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var international = false
        if rest.first == "+" {
            international = true
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty, rest.allSatisfy(allowed.contains) else { return nil }
        var digits = rest.filter(\.isNumber)
        if !international && digits.hasPrefix("00") {
            digits.removeFirst(2)
            international = true
        }
        if !international {
            if digits.count == 10 {
                digits = "1" + digits
            } else if !(digits.count == 11 && digits.first == "1") {
                return nil
            }
        }
        guard (8...15).contains(digits.count) else { return nil }
        if digits.first == "1" {
            // North America: 1, then an area code and an exchange that each start with 2–9.
            let numbers = Array(digits)
            guard numbers.count == 11, ("2"..."9").contains(numbers[1]), ("2"..."9").contains(numbers[4]) else {
                return nil
            }
        }
        return "+" + digits
    }

    /// "+14165550123" → "416-555-0123"; other countries keep their E.164 form.
    public static func display(_ e164: String) -> String {
        let digits = e164.filter(\.isNumber)
        guard e164.hasPrefix("+1"), digits.count == 11 else { return e164 }
        let d = Array(digits.dropFirst())
        return "\(String(d[0..<3]))-\(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}

/// A header field the editor shows an inline message for.
public enum ResumeField: String, Sendable, CaseIterable {
    case fullName, email, phone, linkedIn, gitHub, portfolio, totalYears

    public var isOptional: Bool { self == .gitHub || self == .portfolio }
}

public struct FieldIssue: Equatable, Sendable {
    public enum Kind: Sendable { case missing, invalid }

    public let field: ResumeField
    public let kind: Kind

    public init(field: ResumeField, kind: Kind) {
        self.field = field
        self.kind = kind
    }

    public var message: String {
        switch (field, kind) {
        case (.fullName, _): "Add your full name."
        case (.email, .missing): "Add your email address."
        case (.email, .invalid): "That doesn't look like an email address."
        case (.phone, .missing): "Add your phone number."
        case (.phone, .invalid): "Use a full phone number with its area code, like 416-555-0123."
        case (.linkedIn, .missing): "Add your LinkedIn profile URL."
        case (.linkedIn, .invalid): "Use your LinkedIn profile's address, like https://www.linkedin.com/in/your-name."
        case (.gitHub, _): "Use your GitHub profile's address, like https://github.com/your-name."
        case (.portfolio, _): "Your portfolio address should start with https://."
        case (.totalYears, .missing): "Enter your total years of experience."
        case (.totalYears, .invalid): "Enter a number of years from 0 to 60."
        }
    }
}

/// The header after validation: values cleaned (phone in E.164, profile links in their one form,
/// blank optional fields nil), and what's still missing or wrong.
public struct HeaderValidation: Equatable, Sendable {
    public var header: ResumeHeader
    public var issues: [FieldIssue]

    public var isValid: Bool { issues.isEmpty }

    /// Issues with fields every build needs. A malformed optional link only keeps that link off resumes.
    public var blocking: [FieldIssue] { issues.filter { !$0.field.isOptional } }

    public func issue(for field: ResumeField) -> FieldIssue? { issues.first { $0.field == field } }
}

/// What still stands between the master resume and its first build.
public enum Requirement: Equatable, Sendable {
    case header(FieldIssue)
    case experienceBullet
    case provenSkills(have: Int, need: Int)

    public var message: String {
        switch self {
        case .header(let issue): issue.message
        case .experienceBullet: "Add a work experience with at least one bullet."
        case .provenSkills(let have, let need): "Mark at least \(need) skills as Proven (you have \(have))."
        }
    }
}

public struct BuildReadiness: Equatable, Sendable {
    /// Each one blocks Build.
    public var missing: [Requirement]
    /// Worth a look; never blocks.
    public var warnings: [String]

    public var isReady: Bool { missing.isEmpty }
}

public enum Validator {
    public static let provenSkillsNeeded = 5

    public static func validate(_ header: ResumeHeader) -> HeaderValidation {
        var cleaned = header
        var issues: [FieldIssue] = []
        func check(_ field: ResumeField, _ value: String, required: Bool, normalize: (String) -> String?) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                if required { issues.append(FieldIssue(field: field, kind: .missing)) }
                return required ? "" : nil
            }
            guard let normalized = normalize(trimmed) else {
                issues.append(FieldIssue(field: field, kind: .invalid))
                return trimmed
            }
            return normalized
        }

        cleaned.fullName = check(.fullName, header.fullName, required: true) { $0 } ?? ""
        cleaned.email = check(.email, header.email, required: true) { isEmail($0) ? $0 : nil } ?? ""
        cleaned.phone = check(.phone, header.phone, required: true, normalize: PhoneNumber.e164) ?? ""
        cleaned.linkedInURL = check(.linkedIn, header.linkedInURL, required: true, normalize: linkedInProfile) ?? ""
        cleaned.gitHubURL = check(.gitHub, header.gitHubURL ?? "", required: false, normalize: gitHubProfile)
        cleaned.portfolioURL = check(.portfolio, header.portfolioURL ?? "", required: false, normalize: httpsURL)
        if let years = header.totalYears {
            if !(0...60).contains(years) { issues.append(FieldIssue(field: .totalYears, kind: .invalid)) }
        } else {
            issues.append(FieldIssue(field: .totalYears, kind: .missing))
        }
        return HeaderValidation(header: cleaned, issues: issues)
    }

    public static func readiness(_ resume: MasterResume, now: YearMonth) -> BuildReadiness {
        let header = validate(resume.header)
        var missing = header.blocking.map(Requirement.header)
        let hasBullet = resume.entries(.experience).contains { entry in
            entry.bullets.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        if !hasBullet { missing.append(.experienceBullet) }
        let proven = resume.skills.count {
            $0.level == .proven && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if proven < provenSkillsNeeded { missing.append(.provenSkills(have: proven, need: provenSkillsNeeded)) }

        var warnings: [String] = []
        if header.issue(for: .gitHub) != nil {
            warnings.append(
                "Your GitHub link is left off resumes until it's a profile address, like https://github.com/your-name.")
        }
        if header.issue(for: .portfolio) != nil {
            warnings.append("Your portfolio is left off resumes until its address starts with https://.")
        }
        if let entered = resume.header.totalYears, (0...60).contains(entered),
            let dated = experienceYears(resume.entries, now: now), abs(entered - dated) > 1
        {
            warnings.append(
                "You entered \(years(entered)) years of experience, but your work dates add up to \(years(dated)). Check one of them."
            )
        }
        return BuildReadiness(missing: missing, warnings: warnings)
    }

    /// Years covered by dated work experience, overlaps counted once. Nil when no experience has
    /// both a start and an end (or is current).
    public static func experienceYears(_ entries: [ResumeEntry], now: YearMonth) -> Double? {
        let spans = entries.filter { $0.kind == .experience }.compactMap { entry -> (YearMonth, YearMonth)? in
            guard let start = entry.start, let end = entry.isCurrent ? now : entry.end, start <= end else { return nil }
            return (start, end)
        }.sorted { $0.0 < $1.0 }
        guard var current = spans.first else { return nil }
        var months = 0
        for span in spans.dropFirst() {
            if span.0 <= current.1 {
                current.1 = max(current.1, span.1)
            } else {
                months += current.0.months(until: current.1)
                current = span
            }
        }
        months += current.0.months(until: current.1)
        return Double(months) / 12
    }

    static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !text.contains(where: \.isWhitespace) else { return false }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let top = labels.last, top.count >= 2, top.allSatisfy(\.isLetter) else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    /// "linkedin.com/in/x", "https://ca.linkedin.com/in/x/?trk=…" → "https://www.linkedin.com/in/x".
    public static func linkedInProfile(_ text: String) -> String? {
        guard let (host, path) = hostAndPath(text), host == "linkedin.com" || host.hasSuffix(".linkedin.com"),
            path.count == 2, path[0] == "in"
        else { return nil }
        let handle = path[1]
        guard (3...100).contains(handle.count),
            handle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "%") })
        else { return nil }
        return "https://www.linkedin.com/in/\(handle)"
    }

    /// "github.com/x/" → "https://github.com/x". GitHub's rules: 1–39 letters, digits and single
    /// hyphens, not at either end.
    public static func gitHubProfile(_ text: String) -> String? {
        guard let (host, path) = hostAndPath(text), host == "github.com" || host == "www.github.com", path.count == 1
        else { return nil }
        let user = path[0]
        guard (1...39).contains(user.count), !user.hasPrefix("-"), !user.hasSuffix("-"), !user.contains("--"),
            user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        else { return nil }
        return "https://github.com/\(user)"
    }

    /// An https address with a real host. A bare "jordan.dev" gets https:// added; http:// is
    /// refused rather than upgraded, since the site may not serve https.
    public static func httpsURL(_ text: String) -> String? {
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme), components.scheme?.lowercased() == "https",
            let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return withScheme
    }

    private static func hostAndPath(_ text: String) -> (String, [String])? {
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: withScheme),
            ["http", "https"].contains(components.scheme?.lowercased() ?? ""), let host = components.host?.lowercased()
        else { return nil }
        return (host, components.path.split(separator: "/").map(String.init))
    }

    private static func years(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
