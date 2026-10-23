import Foundation

/// A kind of work you look for (job collection v2, J3; the owner picked all four on 2026-10-23).
/// Each names the titles it covers, the titles that only look like it, and what a search asks.
/// Titles are matched on whole words after common abbreviations expand ("SDE" is "software
/// development engineer"), so "Developer" never matches "Business Development".
public enum RoleFamily: String, Codable, Sendable, CaseIterable, Identifiable {
    case software, devops, data, qa

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .software: "Software development"
        case .devops: "DevOps, cloud and SRE"
        case .data: "Data, ML and AI engineering"
        case .qa: "QA and test automation"
        }
    }

    /// A few of its titles, for Settings.
    public var example: String {
        switch self {
        case .software: "Software engineer or developer, SDE, full stack, backend, frontend, web, mobile"
        case .devops: "DevOps, site reliability, cloud, platform and infrastructure engineer"
        case .data: "Machine learning, AI, data and analytics engineer, MLOps"
        case .qa: "QA engineer, SDET, test automation, quality assurance"
        }
    }

    /// Phrases a title of this kind contains.
    var titles: [String] {
        switch self {
        case .software:
            [
                "software engineer", "software engineering", "software developer", "software development engineer",
                "developer", "programmer", "full stack", "fullstack", "backend", "back end", "frontend", "front end",
                "web engineer", "mobile engineer", "ios engineer", "android engineer", "product engineer",
                "founding engineer", "member of technical staff", "forward deployed engineer", "embedded software",
                "firmware engineer", "application engineer", "applications engineer",
            ]
        case .devops:
            [
                "devops", "dev ops", "site reliability", "platform engineer", "platform engineering",
                "infrastructure engineer", "cloud engineer", "cloud developer", "cloud architect",
                "cloud infrastructure",
                "build engineer", "release engineer", "reliability engineer", "observability engineer",
                "kubernetes engineer",
            ]
        case .data:
            [
                "machine learning", "mlops", "ml ops", "ai engineer", "ai developer", "artificial intelligence",
                "data engineer", "data engineering", "analytics engineer", "deep learning", "computer vision",
                "natural language processing", "nlp engineer", "llm engineer", "generative ai", "applied scientist",
            ]
        case .qa:
            [
                "qa", "quality assurance", "sdet", "software development engineer in test", "software engineer in test",
                "test automation", "automation tester", "software tester", "software test", "test engineer",
            ]
        }
    }

    /// Phrases that make a matching title another kind of job.
    var unlike: [String] {
        switch self {
        case .software:
            [
                "business developer", "business development", "sales development", "developer advocate",
                "developer relations", "real estate", "property developer", "land developer", "curriculum developer",
                "course developer", "content developer", "talent developer", "account development",
            ]
        case .qa: ["food", "quality control", "qc", "manufacturing", "laboratory", "technician"]
        case .devops, .data: []
        }
    }

    /// What a search asks for, broadest first: each a title-only search (Adzuna's `title_only`).
    public var searches: [String] {
        switch self {
        case .software:
            [
                "software engineer", "software developer", "full stack", "backend developer", "frontend developer",
                "web developer", "mobile developer", "software development engineer", "programmer analyst",
                "application developer",
            ]
        case .devops: ["devops", "site reliability", "cloud engineer", "platform engineer"]
        case .data: ["machine learning", "data engineer", "ai engineer"]
        case .qa: ["qa engineer", "quality assurance", "test automation", "sdet"]
        }
    }
}

/// Whether a title is one you look for: one of your role families (and none of its look-alikes),
/// or one of your own phrases. With neither, every title is.
public struct RoleMatcher: Sendable, Equatable {
    public var families: Set<RoleFamily>
    /// Your own phrases (Settings, Search: other titles).
    public var extra: [String]

    public init(families: Set<RoleFamily>, extra: [String] = []) {
        self.families = families
        self.extra = extra.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Nothing set: no title is left out.
    public var isOpen: Bool { families.isEmpty && extra.isEmpty }

    public func matches(_ title: String) -> Bool {
        guard !isOpen else { return true }
        let text = Self.normalized(title)
        func has(_ phrase: String) -> Bool { text.contains(Self.normalized(phrase)) }
        for family in RoleFamily.allCases where families.contains(family) {
            if family.titles.contains(where: has) && !family.unlike.contains(where: has) { return true }
        }
        return extra.contains(where: has)
    }

    /// Searches for every family you look for, in a fixed order, then your phrases, without repeats.
    public var searches: [String] {
        let all = RoleFamily.allCases.filter(families.contains).flatMap(\.searches) + extra.map { $0.lowercased() }
        return all.reduce(into: []) { kept, search in if !kept.contains(search) { kept.append(search) } }
    }

    /// Settings fingerprint: changes when what's kept changes.
    public var fingerprint: String {
        (families.map(\.rawValue).sorted() + extra.map { $0.lowercased() }.sorted()).joined(separator: ",")
    }

    /// Abbreviations titles use, by the words they stand for.
    static let abbreviations = [
        "sde": "software development engineer", "swe": "software engineer", "sre": "site reliability engineer",
        "dev": "developer", "devs": "developers", "eng": "engineer", "engr": "engineer", "ml": "machine learning",
        "sr": "senior", "snr": "senior", "jr": "junior", "fe": "frontend", "be": "backend",
    ]

    /// Lowercase words, accents folded, hyphens and punctuation as spaces, abbreviations expanded,
    /// padded with spaces so a phrase matches only whole words: " full stack developer ".
    static func normalized(_ text: String) -> String {
        let folded = text.lowercased().folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en"))
        let words = folded.split { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "#" }.map(String.init)
        return " " + words.map { abbreviations[$0] ?? $0 }.joined(separator: " ") + " "
    }
}
