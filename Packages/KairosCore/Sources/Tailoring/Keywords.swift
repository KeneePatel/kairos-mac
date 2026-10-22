import Foundation

/// Finds technologies and keywords in text, using `Synonyms.json`: "Postgres" is PostgreSQL, "k8s"
/// is Kubernetes, and "Go" is the language only when written "Go" ("go live" isn't).
enum Keywords {
    /// A technology named in a text: its canonical name and the words as written.
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
        /// Set for names that are also ordinary words: the only spelling that counts.
        let exact: String?
    }

    private static let vocabulary: Vocabulary = {
        guard let url = Bundle.module.url(forResource: "Synonyms", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let vocabulary = try? JSONDecoder().decode(Vocabulary.self, from: data)
        else { return Vocabulary(technologies: [:], caseSensitive: [], concepts: [:]) }
        return vocabulary
    }()

    private static let aliases: [Alias] = {
        let exact = Dictionary(
            vocabulary.caseSensitive.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        return vocabulary.technologies.flatMap { canonical, others in
            ([canonical] + others).map { Alias(text: $0, canonical: canonical, exact: exact[$0]) }
        }
        .sorted { ($0.text.count, $0.text) > ($1.text.count, $1.text) }
    }()

    /// Every technology a text names, in the order first named.
    static func mentions(in text: String) -> [Mention] {
        var found: [(String.Index, Mention)] = []
        for alias in aliases {
            var from = text.startIndex
            while from < text.endIndex,
                let range = text.range(of: alias.text, options: .caseInsensitive, range: from..<text.endIndex)
            {
                from = range.upperBound
                let written = String(text[range])
                guard isWholeWord(range, in: text), alias.exact.map({ $0 == written }) ?? true else { continue }
                found.append((range.lowerBound, Mention(canonical: alias.canonical, written: written)))
            }
        }
        var seen: Set<String> = []
        return found.sorted { $0.0 < $1.0 }.map(\.1).filter { seen.insert($0.canonical).inserted }
    }

    /// The canonical technologies a text claims.
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

    /// The broader terms a text names ("cloud", "message queues"), and the technologies each stands for.
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
        while from < text.endIndex,
            let range = text.range(of: phrase, options: .caseInsensitive, range: from..<text.endIndex)
        {
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
        "with", "that", "this", "from", "have", "years", "year", "experience", "strong", "ability", "knowledge",
        "working", "work", "using", "including", "such", "team", "teams", "skills", "skill", "understanding",
        "familiarity", "plus", "required", "preferred", "least", "more", "their", "they", "will", "your", "into",
        "about", "across", "other", "within", "excellent", "good", "great", "proven", "solid", "hands-on",
        "built", "build", "building",
    ]
}

/// The technologies and broader terms a text names, by the vocabulary builds use (`Synonyms.json`),
/// for code outside tailoring: Improve groups job requirements with it, so "K8s" and "Kubernetes"
/// count as one ask.
public enum TechVocabulary {
    /// A technology as a text names it: its canonical name (lowercase) and the words as written.
    public struct Named: Sendable, Equatable {
        public let canonical: String
        public let written: String
    }

    /// In the order first named.
    public static func technologies(in text: String) -> [Named] {
        Keywords.mentions(in: text).map { Named(canonical: $0.canonical, written: $0.written) }
    }

    /// Broader terms ("cloud", "ci/cd") and the canonical technologies each stands for.
    public static func concepts(in text: String) -> [(concept: String, members: [String])] {
        Keywords.concepts(in: text)
    }
}
