import Foundation

/// The last pass over written text, in code: AI-sounding phrases swapped,
/// opening verbs varied, bullets cut to length and ended cleanly, spelling for the job's country.
/// Running it twice changes nothing more.
public struct Polish: Sendable {
    public static let maxBulletLength = 260

    public let locale: SpellingLocale

    public init(locale: SpellingLocale) {
        self.locale = locale
    }

    /// One piece of text, such as the summary.
    public func text(_ text: String) -> String {
        spell(rephrase(clean(text)))
    }

    /// A section's bullets: each polished, fitted to length and ended with a full stop, with no
    /// two starting on the same verb.
    public func bullets(_ bullets: [String]) -> [String] {
        var used: Set<String> = []
        return bullets.map { raw in
            var bullet = fit(text(raw))
            bullet = capitalized(bullet)
            if let last = bullet.last, !".!?".contains(last) { bullet += "." }
            let verb = String(bullet.prefix { $0.isLetter })
            if used.contains(verb.lowercased()),
                let other = Self.alternatives[verb.lowercased()]?.first(where: { !used.contains($0.lowercased()) })
            {
                bullet = other + bullet.dropFirst(verb.count)
            }
            used.insert(String(bullet.prefix { $0.isLetter }).lowercased())
            return bullet
        }
    }

    // MARK: - Steps

    private func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func rephrase(_ text: String) -> String {
        var result = text
        for (phrase, replacement) in Self.phrases {
            result = replaceWords(phrase, with: replacement, in: result)
        }
        return clean(result)
    }

    private func spell(_ text: String) -> String {
        var result = text
        for (word, spelled) in Self.spelling[locale] ?? [:] {
            result = replaceWords(word, with: spelled, in: result)
        }
        return result
    }

    /// Over the limit: cut at the last "; ", then " — ", then ", " that leaves a full thought.
    private func fit(_ bullet: String) -> String {
        guard bullet.count > Self.maxBulletLength else { return bullet }
        let head = String(bullet.prefix(Self.maxBulletLength))
        for boundary in ["; ", " — ", ", "] {
            if let cut = head.range(of: boundary, options: .backwards),
                head.distance(from: head.startIndex, to: cut.lowerBound) >= 40
            {
                return String(head[..<cut.lowerBound])
            }
        }
        let words = head.split(separator: " ").dropLast()
        return words.joined(separator: " ")
    }

    private func capitalized(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Whole-word, case-insensitive replacement that keeps the case of what it replaces.
    private func replaceWords(_ word: String, with replacement: String, in text: String) -> String {
        var result = ""
        var rest = text[...]
        while let range = rest.range(of: word, options: .caseInsensitive) {
            let before = range.lowerBound > rest.startIndex ? rest[rest.index(before: range.lowerBound)] : nil
            let after = range.upperBound < rest.endIndex ? rest[range.upperBound] : nil
            let whole = !(before?.isLetter ?? false) && !(after?.isLetter ?? false) && !(before?.isNumber ?? false)
            result += rest[..<range.lowerBound]
            result += whole ? matchCase(of: String(rest[range]), replacement) : String(rest[range])
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    private func matchCase(of original: String, _ replacement: String) -> String {
        guard !replacement.isEmpty else { return replacement }
        if original.count > 1, original == original.uppercased() { return replacement.uppercased() }
        if let first = original.first, first.isUppercase {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    // MARK: - Tables

    /// Longest first, so "leveraging" goes before "leverage".
    private static let phrases: [(String, String)] = [
        ("played a pivotal role in", "helped with"), ("played a key role in", "helped with"),
        ("played a crucial role in", "helped with"), ("in order to", "to"), ("state-of-the-art", "modern"),
        ("cutting-edge", "modern"), ("results-driven", ""), ("spearheaded", "led"), ("spearheading", "leading"),
        ("spearhead", "lead"), ("leveraged", "used"), ("leveraging", "using"), ("leverage", "use"),
        ("utilized", "used"), ("utilised", "used"), ("utilizing", "using"), ("utilising", "using"),
        ("utilize", "use"), ("utilise", "use"), ("seamlessly", ""), ("synergies", "collaboration"),
        ("synergy", "collaboration"), ("orchestrated", "coordinated"), ("robust", "reliable"),
    ].sorted { $0.0.count > $1.0.count }

    /// Other ways to start a bullet, for when a verb repeats.
    private static let alternatives: [String: [String]] = [
        "built": ["Developed", "Created", "Implemented"], "developed": ["Built", "Created", "Implemented"],
        "created": ["Built", "Developed", "Set up"], "implemented": ["Built", "Delivered", "Developed"],
        "led": ["Ran", "Headed", "Directed"], "designed": ["Planned", "Drafted", "Shaped"],
        "improved": ["Raised", "Strengthened", "Upgraded"], "reduced": ["Cut", "Lowered", "Trimmed"],
        "cut": ["Reduced", "Lowered", "Trimmed"], "managed": ["Ran", "Oversaw", "Handled"],
        "shipped": ["Delivered", "Launched", "Released"], "migrated": ["Moved", "Ported", "Transferred"],
        "wrote": ["Authored", "Drafted", "Produced"], "automated": ["Scripted", "Streamlined"],
        "increased": ["Raised", "Grew", "Lifted"], "introduced": ["Added", "Brought in", "Launched"],
    ]

    private static let spelling: [SpellingLocale: [String: String]] = {
        var tables: [SpellingLocale: [String: String]] = [:]
        struct Table: Decodable { let words: [String: String] }
        for locale in SpellingLocale.allCases {
            guard
                let url = Bundle.module.url(
                    forResource: locale.rawValue, withExtension: "json", subdirectory: "Resources/Spelling"),
                let data = try? Data(contentsOf: url), let table = try? JSONDecoder().decode(Table.self, from: data)
            else { continue }
            tables[locale] = table.words
        }
        return tables
    }()
}
