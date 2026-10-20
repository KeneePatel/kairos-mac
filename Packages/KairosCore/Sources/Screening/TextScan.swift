import Foundation

/// Plain-text helpers for reading postings: folding, whole-word matching, lines, sentences and
/// sections. Postings are untrusted input, so nothing here builds a pattern from their text.
enum TextScan {
    /// Lowercase, accents and curly apostrophes folded: "Français" and "francais" match.
    static func fold(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacing("’", with: "'").replacing("‘", with: "'")
    }

    /// Whether folded `text` contains `phrase` as whole words: "sales" isn't in "salesforce", and
    /// "c++" is in "c++ developer".
    static func containsPhrase(_ text: String, _ phrase: String) -> Bool {
        let phrase = fold(phrase).trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty else { return false }
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: phrase, range: from..<text.endIndex) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            if !isWordCharacter(before) && !isWordCharacter(after) { return true }
            from = text.index(after: range.lowerBound)
        }
        return false
    }

    static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { containsPhrase(text, $0) }
    }

    /// Letters and digits only.
    static func words(_ text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A line's sentences, split after ".", ";", "!" or "?" and a space, except after short
    /// abbreviations such as "min." and "yrs.".
    static func sentences(_ line: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(line)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".;!?".contains(character), index + 1 == characters.count || characters[index + 1].isWhitespace
            else { continue }
            if character == ".", abbreviations.contains(lastWord(of: current.dropLast())) { continue }
            sentences.append(current)
            current = ""
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current) }
        return sentences
    }

    /// A Markdown heading, a bold-only line, or a short line ending in ":" opens a section; returns
    /// its title.
    static func heading(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        if trimmed.count > 4, trimmed.hasPrefix("**"), trimmed.hasSuffix("**") || trimmed.hasSuffix("**:") {
            return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "*: "))
        }
        if trimmed.hasSuffix(":"), trimmed.count <= 60, !trimmed.contains(where: \.isNumber) {
            return String(trimmed.dropLast())
        }
        return nil
    }

    /// Words that make a sentence or section optional rather than required.
    static let preferredMarkers = [
        "preferred", "nice to have", "nice-to-have", "bonus", "asset", "assets", "a plus", "ideally", "desirable",
        "desired", "advantage", "advantageous", "optional", "atout", "atouts", "souhaitable",
    ]

    static func isPreferred(_ text: String) -> Bool {
        containsAny(text, preferredMarkers)
    }

    /// Each required sentence of a posting, folded: sentences and sections marked preferred are left out.
    static func requiredSentences(_ text: String) -> [String] {
        var result: [String] = []
        var preferredSection = false
        for line in text.split(whereSeparator: \.isNewline).map({ fold(String($0)) }) {
            if let heading = heading(line) {
                preferredSection = isPreferred(heading)
                continue
            }
            guard !preferredSection else { continue }
            result += sentences(line).filter { !isPreferred($0) }
        }
        return result
    }

    /// Written in French: French function words clearly outnumber English ones.
    static func isFrench(_ text: String) -> Bool {
        let words = words(fold(text))
        let french = words.filter(frenchWords.contains).count
        let english = words.filter(englishWords.contains).count
        return french >= 12 && french > 2 * english
    }

    private static let frenchWords: Set = [
        "le", "la", "les", "des", "et", "pour", "avec", "vous", "nous", "une", "du", "dans", "est", "sur", "au", "aux",
        "notre", "votre", "qui", "que", "un", "de", "en", "par",
    ]
    private static let englishWords: Set = [
        "the", "and", "for", "with", "you", "we", "to", "of", "in", "is", "on", "our", "your", "who", "that", "an",
        "are", "will",
    ]

    private static let abbreviations: Set = [
        "min", "yrs", "yr", "e.g", "i.e", "etc", "approx", "incl", "sr", "jr", "no", "vs", "u.s", "st", "dept",
    ]

    private static func lastWord(of text: Substring) -> String {
        String(text.reversed().prefix { $0.isLetter || $0 == "." }.reversed())
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        character.map { $0.isLetter || $0.isNumber } ?? false
    }
}
