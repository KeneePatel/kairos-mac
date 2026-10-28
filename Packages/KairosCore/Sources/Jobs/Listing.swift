import Foundation
import KairosKit

/// One source's copy of a job, read and tidied: its place parsed, its text in Markdown, its
/// identity fixed. Postings become listings; listings attach to jobs.
public struct Listing: Sendable, Equatable, Identifiable {
    /// `StableID.of(canonicalURL)`: every device and every fetch agree on it.
    public let id: String
    public let canonicalURL: String
    public var url: String
    public var applyURL: String?
    public var via: String?
    public var company: String
    public var title: String
    /// Every place it names, joined: "Toronto, ON; Remote - Canada".
    public var location: String
    public var city: String?
    public var region: String?
    public var country: Country?
    public var remoteScope: RemoteScope
    public var postedAt: Date?
    /// Markdown; empty when the text wasn't asked for.
    public var description: String
    public var salary: Salary?
    public var textOmitted: Bool
    public var isSnippet: Bool
    /// `company|title|city`, folded: how copies of one job on different sources find each other.
    public var dedupKey: String
    /// Changes when the title, place or text does: an edit.
    public var contentHash: String
    public var links: [URL]

    public init(
        canonicalURL: String, url: String, applyURL: String? = nil, via: String? = nil, company: String,
        title: String, location: String = "", city: String? = nil, region: String? = nil, country: Country? = nil,
        remoteScope: RemoteScope = .unknown, postedAt: Date? = nil, description: String = "", salary: Salary? = nil,
        textOmitted: Bool = false, isSnippet: Bool = false, links: [URL] = []
    ) {
        self.id = StableID.of(canonicalURL)
        self.canonicalURL = canonicalURL
        self.url = url
        self.applyURL = applyURL
        self.via = via
        self.company = company
        self.title = title
        self.location = location
        self.city = city
        self.region = region
        self.country = country
        self.remoteScope = remoteScope
        self.postedAt = postedAt
        self.description = description
        self.salary = salary
        self.textOmitted = textOmitted
        self.isSnippet = isSnippet
        self.links = links
        self.dedupKey = DedupKey.make(company: company, title: title, city: city)
        self.contentHash = StableID.of([title, location, description].joined(separator: "\u{1F}"))
    }
}

public enum Normalizer {
    /// The listing for `posting`, or nil when every place it names is outside Canada and the US.
    public static func normalize(_ posting: Posting) -> Listing? {
        let geo = Geo.parse(
            location: posting.location, otherLocations: posting.otherLocations, countryHint: posting.countryHint,
            workplace: posting.workplace)
        if geo.outsideCanadaAndUS { return nil }
        var places: [String] = []
        for place in ([posting.location] + posting.otherLocations).map(\.tidied) where !place.isEmpty {
            if !places.contains(place) { places.append(place) }
        }
        let canonical = URLCanonicalizer.canonical(posting.url)
        let apply = posting.applyURL.map { $0.absoluteString }
        return Listing(
            canonicalURL: canonical, url: posting.url.absoluteString,
            applyURL: apply == posting.url.absoluteString ? nil : apply, via: posting.via,
            company: posting.company.tidied, title: posting.title.tidied, location: places.joined(separator: "; "),
            city: geo.city, region: geo.region, country: geo.country, remoteScope: geo.remoteScope,
            postedAt: posting.postedAt, description: HTMLToMarkdown.convert(posting.descriptionHTML),
            salary: posting.salary, textOmitted: posting.textOmitted, isSnippet: posting.isSnippet,
            links: posting.links)
    }
}

/// The form of a posting's URL that every device and visit agree on, so its hash can be the id.
public enum URLCanonicalizer {
    /// Query parameters that only say how you arrived. Anything else could identify the job.
    static let trackingParameters: Set<String> = [
        "gh_src", "lever-source", "lever-origin", "lever-via", "source", "src", "ref", "referrer", "refid", "trk",
        "trkinfo", "trackingid", "fbclid", "gclid", "msclkid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok",
        "igshid",
    ]

    public static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme == "http" ? "https" : scheme
        var host = components.host?.lowercased()
        // Greenhouse serves the same posting on both hosts.
        if host == "boards.greenhouse.io" { host = "job-boards.greenhouse.io" }
        components.host = host
        if components.port == 443 || components.port == 80 { components.port = nil }
        components.fragment = nil
        // An Adzuna advert's link carries tracking that changes with every search; its id is the path.
        if let host, host.hasPrefix("www.adzuna.") || host.hasPrefix("adzuna."), components.path.hasPrefix("/land/ad/")
        {
            components.query = nil
        }
        let kept = (components.percentEncodedQueryItems ?? []).filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        components.percentEncodedQueryItems =
            kept.isEmpty ? nil : kept.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        if components.percentEncodedPath.count > 1 && components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        return components.string ?? url.absoluteString
    }

    public static func canonical(_ text: String) -> String {
        URL(string: text).map(canonical) ?? text
    }
}

/// `company|title|city`, each folded to plain lowercase words, so the same job reads the same on
/// every source.
public enum DedupKey {
    static let companySuffixes: Set<String> = [
        "inc", "incorporated", "ltd", "limited", "llc", "llp", "corp", "corporation", "co", "company", "gmbh", "plc",
        "the",
    ]
    static let titleAbbreviations: [String: String] = [
        "sr": "senior", "snr": "senior", "jr": "junior", "eng": "engineer", "engr": "engineer", "dev": "developer",
        "mgr": "manager", "swe": "software engineer", "sde": "software engineer", "ml": "machine learning",
    ]

    public static func make(company: String, title: String, city: String?) -> String {
        let companyWords = words(company).filter { !companySuffixes.contains($0) }
        let titleWords = words(title).map { titleAbbreviations[$0] ?? $0 }
        return [companyWords, titleWords, words(city ?? "")].map { $0.joined(separator: " ") }.joined(separator: "|")
    }

    /// A company name folded for comparing: "Syndio Inc." and "syndio" are one company.
    public static func company(_ name: String) -> String {
        words(name).filter { !companySuffixes.contains($0) }.joined(separator: " ")
    }

    /// The company part of a key, which is how candidates are grouped before comparing.
    public static func company(of key: String) -> Substring {
        key.prefix { $0 != "|" }
    }

    static func words(_ text: String) -> [String] {
        text.folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

public enum Similarity {
    /// Titles at least this alike, at the same company in the same city, are the same job.
    public static let sameJob = 0.9

    /// Whether two dedup keys name the same job.
    public static func isSameJob(_ a: String, _ b: String) -> Bool {
        titles(a, b) >= sameJob
    }

    /// How alike two jobs' titles are when they're at the same company and, when both say, in the
    /// same city; 0 otherwise. Titles are compared alone: on whole keys a shared company and city
    /// made "QA Engineer" and "Data Engineer" 0.91 alike (2026-10-23).
    public static func titles(_ a: String, _ b: String) -> Double {
        let x = a.split(separator: "|", omittingEmptySubsequences: false)
        let y = b.split(separator: "|", omittingEmptySubsequences: false)
        guard x.count == 3, y.count == 3, x[0] == y[0], x[2].isEmpty || y[2].isEmpty || x[2] == y[2] else { return 0 }
        return of(String(x[1]), String(y[1]))
    }

    /// 1 minus the edit distance over the longer length: 1 for equal strings, 0 for nothing shared.
    public static func of(_ a: String, _ b: String) -> Double {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1 : 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
