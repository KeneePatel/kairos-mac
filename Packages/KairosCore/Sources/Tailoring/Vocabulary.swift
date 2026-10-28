import Foundation

/// Finds technologies and keywords in text with `synonyms.json`: "Postgres" is PostgreSQL, "k8s" is
/// Kubernetes, and "Go" is the language only when written "Go" ("go live" isn't).
enum Keywords {
    struct Mention: Equatable {
        let canonical: String
        let written: String
    }

    private struct Vocabulary: Decodable {
        let technologies: [String: [String]]
        let caseSensitive: [String]
        let concepts: [String: [String]]
    }

    private struct Alias {
        let text: String
        let canonical: String
        /// For names that are also ordinary words: the only spelling that counts.
        let exact: String?
    }

    private static let vocabulary: Vocabulary = {
        guard let url = Bundle.module.url(forResource: "synonyms", withExtension: "json", subdirectory: "Resources"),
            let data = try? Data(contentsOf: url), let vocabulary = try? JSONDecoder().decode(Vocabulary.self, from: data)
        else { return Vocabulary(technologies: [:], caseSensitive: [], concepts: [:]) }
        return vocabulary
    }()

    private static let aliases: [Alias] = {
        let exact = Dictionary(vocabulary.caseSensitive.map { ($0.lowercased(), $0) }) { first, _ in first }
        return vocabulary.technologies.flatMap { canonical, others in
            ([canonical] + others).map { Alias(text: $0, canonical: canonical, exact: exact[$0]) }
        }.sorted { ($0.text.count, $0.text) > ($1.text.count, $1.text) }
    }()

    static var isLoaded: Bool { !vocabulary.technologies.isEmpty }

    /// Every technology a text names, in the order first named.
    static func mentions(in text: String) -> [Mention] {
        var found: [(String.Index, Mention)] = []
        for alias in aliases {
            var from = text.startIndex
            while from < text.endIndex, let range = text.range(of: alias.text, options: .caseInsensitive, range: from..<text.endIndex) {
                from = range.upperBound
                let written = String(text[range])
                guard isWholeWord(range, in: text), alias.exact.map({ $0 == written }) ?? true else { continue }
                found.append((range.lowerBound, Mention(canonical: alias.canonical, written: written)))
            }
        }
        var seen: Set<String> = []
        return found.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0.canonical).inserted }
    }

    static func technologies(in text: String) -> Set<String> {
        Set(mentions(in: text).map(\.canonical))
    }

    /// Technologies plus those a broader term stands for ("message queues" includes Kafka), for
    /// matching requirements. Never used to judge a claim.
    static func terms(in text: String) -> Set<String> {
        var terms = technologies(in: text)
        for (concept, members) in vocabulary.concepts where contains(concept, in: text) {
            terms.formUnion(members)
        }
        return terms
    }

    static func concepts(in text: String) -> [(concept: String, members: [String])] {
        vocabulary.concepts.filter { contains($0.key, in: text) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Content words, singular, for matching what technologies don't cover ("on-call", "services").
    static func keywords(in text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        return Set(
            words.filter { $0.count >= 4 && !stopwords.contains($0) }.map { word in
                word.hasSuffix("s") && word.count > 4 && !word.hasSuffix("ss") ? String(word.dropLast()) : word
            })
    }

    static func contains(_ phrase: String, in text: String) -> Bool {
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: phrase, options: .caseInsensitive, range: from..<text.endIndex) {
            if isWholeWord(range, in: text) { return true }
            from = range.upperBound
        }
        return false
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
        let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
        return !isWordCharacter(before) && !isWordCharacter(after)
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        character.map { $0.isLetter || $0.isNumber } ?? false
    }

    private static let stopwords: Set = [
        "with", "that", "this", "from", "have", "years", "year", "experience", "strong", "ability", "knowledge", "working",
        "work", "using", "including", "such", "team", "teams", "skills", "skill", "understanding", "familiarity", "plus",
        "required", "preferred", "least", "more", "their", "they", "will", "your", "into", "about", "across", "other",
        "within", "excellent", "good", "great", "proven", "solid", "hands-on", "built", "build", "building",
    ]
}

/// The technologies and broader terms a text names, for code outside tailoring: Improve groups
/// requirements with it, so "K8s" and "Kubernetes" count as one ask.
public enum TechVocabulary {
    public struct Named: Sendable, Equatable {
        /// Lowercase.
        public let canonical: String
        public let written: String
    }

    public static func technologies(in text: String) -> [Named] {
        Keywords.mentions(in: text).map { Named(canonical: $0.canonical, written: $0.written) }
    }

    public static func concepts(in text: String) -> [(concept: String, members: [String])] {
        Keywords.concepts(in: text)
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
        let pattern = /(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?(\s*(?:million|billion|thousand|[kmbx])(?![A-Za-z]))?(?![A-Za-z0-9])/
            .ignoresCase()
        return text.matches(of: pattern).compactMap { match in
            let range = match.range
            if range.lowerBound > text.startIndex {
                let before = text[text.index(before: range.lowerBound)]
                if before.isLetter || before.isNumber || before == "." { return nil }
            }
            guard let whole = Double(match.output.1.replacing(",", with: "") + (match.output.2 ?? "")) else { return nil }
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

    static func values(in text: String) -> [Double] { mentions(in: text).map(\.value) }

    /// "5 years", "8+ yrs": claims about experience, judged against your total years.
    static func yearsClaims(in text: String) -> [Mention] {
        text.matches(of: /(\d{1,2})\s*\+?\s*(?:years?|yrs?)\b/.ignoresCase()).compactMap { match in
            Double(match.output.1).map { Mention(value: $0, range: match.range) }
        }
    }
}

/// Requirements a resume can't show with a bullet: work authorization, clearance, languages,
/// degrees, travel, licences. The profile and screening judge those.
enum Requirements {
    static func isCondition(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [
            "authoriz", "authoris", "entitled to work", "eligible to work", "right to work", "sponsor", "citizen",
            "permanent resident", "work permit", "visa", "clearance", "reliability status", "french", "english",
            "bilingual", "language", "degree", "bachelor", "master's", "phd", "diploma", "travel", "driver", "licence",
            "license",
        ].contains { lower.contains($0) }
    }
}
