import Foundation

/// Removes contact details from resume text before any of it is sent to a model (SPEC §5.10,
/// Import): the values you entered, plus anything shaped like an email, a phone number or a profile
/// link, whoever's they are. Locations, dates, numbers and employers stay: tailoring needs them.
public enum ContactRedactor {
    public static let marker = "[removed]"

    /// Sites whose URLs point at a person.
    static let profileHosts = [
        "linkedin.com", "github.com", "gitlab.com", "bitbucket.org", "x.com", "twitter.com", "stackoverflow.com",
        "medium.com", "behance.net", "dribbble.com",
    ]

    public static func redact(_ text: String, header: ResumeHeader) -> String {
        var result = text
        let path = #"(?:/[^\s,;)\]]*)?"#
        // Profile links on the sites above, with or without a scheme or subdomain.
        let hosts = profileHosts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        result = replace(#"(?<![\w.-])(?:https?://)?(?:[a-z0-9-]+\.)*(?:"# + hosts + ")" + path, in: result)
        // Your portfolio, wherever it's hosted.
        if let host = header.portfolioURL.flatMap({ URL(string: $0.contains("://") ? $0 : "https://" + $0)?.host() }) {
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            let site = NSRegularExpression.escapedPattern(for: bare)
            result = replace(#"(?<![\w.-])(?:https?://)?(?:www\.)?"# + site + path, in: result)
        }
        result = replace(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: result)
        result = replacePhones(in: result)
        result = replaceName(header.fullName, in: result)
        return result
    }

    /// Work authorization and clearance, which stay on this Mac (SPEC §5.5, Privacy): "Canadian
    /// citizen", "permanent resident", "requires sponsorship", "Secret clearance". Only these status
    /// phrases go; a bullet about building a visa portal stays as written.
    public static func redactWorkStatus(_ text: String) -> String {
        let country = #"(?:canada|the\s+us|the\s+u\.s\.|the\s+united\s+states|the\s+usa)"#
        let patterns = [
            #"\b(?:canadian|american|u\.s\.|us)\s+citizen(?:ship)?\b"#,
            #"\bcitizen(?:ship)?\s+of\s+"# + country,
            #"\bpermanent\s+resident(?:\s+of\s+canada)?\b"#,
            #"\b(?:open\s+|closed\s+|post-graduation\s+)?work\s+permit(?:\s+holder)?\b"#,
            #"\b(?:tn|h-?1b|l-?1)\s+(?:visa|status)\b"#,
            #"\b(?:require|requires|need|needs|will\s+need|without)\s+(?:visa\s+)?sponsorship\b"#,
            #"\b(?:eligible|authori[sz]ed|legally\s+entitled)\s+to\s+work\s+in\s+"# + country,
            #"\b(?:top\s+secret|secret|enhanced\s+reliability|reliability)\s+(?:security\s+)?clearance\b"#,
            #"\bsecurity\s+clearance\b"#,
        ]
        return patterns.reduce(text) { replace($1, in: $0) }
    }

    /// Digit runs shaped like a phone number: 10–15 digits in two to four groups, an optional
    /// "+country" and an area code in brackets. Year ranges, metrics and versions don't qualify.
    private static func replacePhones(in text: String) -> String {
        let pattern = #"(?<![\w+])(?:\+\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)|\d{2,4})(?:[\s.-]?\d{2,4}){2,3}(?![\w])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let digits = result[range].filter(\.isNumber).count
            if (10...15).contains(digits) { result.replaceSubrange(range, with: marker) }
        }
        return result
    }

    /// Your full name, in either order ("Jordan Rivera", "Rivera, Jordan"), in any case.
    private static func replaceName(_ fullName: String, in text: String) -> String {
        let parts = fullName.split(whereSeparator: \.isWhitespace).map {
            NSRegularExpression.escapedPattern(for: String($0))
        }
        guard !parts.isEmpty else { return text }
        var result = replace(#"\b"# + parts.joined(separator: #"\s+"#) + #"\b"#, in: text)
        if parts.count >= 2, let last = parts.last {
            result = replace(
                #"\b"# + last + #",\s*"# + parts.dropLast().joined(separator: #"\s+"#) + #"\b"#, in: result)
        }
        return result
    }

    private static func replace(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: marker))
    }
}
