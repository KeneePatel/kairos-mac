import Foundation
import Jobs

/// Plain-text helpers for reading postings: folding, whole-word matching, sentences and sections.
/// Postings are untrusted input, so nothing here builds a pattern from their text.
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

    /// A Markdown heading, a bold-only line, or a short line ending in ":" opens a section.
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

    static func isPreferred(_ text: String) -> Bool { containsAny(text, preferredMarkers) }

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

/// What a posting's required sentences say about work authorization, clearance, residency and
/// French. Each reads folded required sentences, so "French is an asset" or "clearance is a plus"
/// never count.
enum Signals {
    struct AuthorizationNeed: Equatable {
        enum Kind { case noSponsorship, authorization, citizenship }
        let kind: Kind
        /// The country the sentence names; nil means the job's own.
        let country: Country?
    }

    enum ClearanceNeed: Equatable {
        /// An active clearance, now.
        case hold
        /// One you'd have to get, in the named country (nil: the job's).
        case obtain(Country?)
    }

    static func authorizationNeeds(_ sentences: [String]) -> [AuthorizationNeed] {
        let noSponsorship = [
            #/\b(?:no|not|unable to|cannot|can't|can not|will not|won't|do not|does not|not able to)\b[^.]{0,40}?\bsponsor/#,
            #/\bsponsorship\b[^.]{0,30}?\b(?:not|unavailable|no longer)\b/#,
            #/\bwithout\b[^.]{0,50}?\bsponsorship\b/#, #/\b(?:aucun|sans|pas de)\s+parrainage\b/#,
        ]
        let authorized =
            #/\b(?:authori[sz]ed|eligible|entitled|permitted|legally able)\s+to\s+work\s+in\s+(?:the\s+)?(?<country>u\.s\.?|usa|us|united states|america|canada)(?![a-z])/#
        let citizen = #/(?<country>u\.s\.?|usa|us|united states|american|canadian)\s+citizen(?:s|ship)?(?![a-z])/#
        var needs: [AuthorizationNeed] = []
        for sentence in sentences {
            if noSponsorship.contains(where: { sentence.contains($0) }) {
                needs.append(AuthorizationNeed(kind: .noSponsorship, country: nil))
            }
            if let match = sentence.firstMatch(of: authorized) {
                needs.append(AuthorizationNeed(kind: .authorization, country: country(match.output.country)))
            } else if sentence.contains(#/autorise(?:e|s|es)?\s+a\s+travailler\s+au\s+canada/#) {
                needs.append(AuthorizationNeed(kind: .authorization, country: .canada))
            }
            if let match = sentence.firstMatch(of: citizen),
                TextScan.containsAny(sentence, ["must", "required", "only"])
            {
                needs.append(AuthorizationNeed(kind: .citizenship, country: country(match.output.country)))
            }
        }
        return needs
    }

    static func clearanceNeeds(_ sentences: [String]) -> [ClearanceNeed] {
        let obtain =
            #/\b(?:able|ability|eligible|eligibility)\s+to\s+(?:obtain|get|acquire|be granted)\b[^.]{0,60}?\b(?:clearance|reliability status|security status)\b/#
        let hold = [
            #/\bts\/sci\b/#, #/\b(?:top secret|secret|public trust)\b[^.]{0,20}?\bclearance\b/#,
            #/\b(?:active|current|existing|valid)\b[^.]{0,30}?\b(?:clearance|reliability status)\b/#,
            #/\bclearance\b[^.]{0,30}?\b(?:required|needed|mandatory)\b/#,
            #/\b(?:must|required to)\s+(?:hold|have|possess|maintain)\b[^.]{0,40}?\b(?:clearance|reliability status)\b/#,
        ]
        var needs: [ClearanceNeed] = []
        for sentence in sentences {
            if TextScan.containsAny(sentence, ["no security clearance", "no clearance", "not require", "not required"])
            {
                continue
            }
            if sentence.contains(obtain) {
                let canadian = TextScan.containsAny(sentence, ["reliability status", "canada", "canadian"])
                let american = TextScan.containsAny(sentence, ["u.s", "united states", "american", "us government"])
                needs.append(.obtain(canadian ? .canada : american ? .unitedStates : nil))
            } else if hold.contains(where: { sentence.contains($0) }) {
                needs.append(.hold)
            }
        }
        return needs
    }

    /// The country a remote posting requires you to live in ("Candidates must reside in the US").
    static func residencyCountry(_ sentences: [String]) -> Country? {
        let patterns = [
            #/\b(?:must|need to|needs to|required to|should|have to)\s+(?:be\s+)?(?:located|based|reside|residing|live|living|a resident)\s+(?:in|of)\s+(?:the\s+)?(?<country>u\.s\.?|usa|us|united states|canada)(?![a-z])/#,
            #/\b(?<country>u\.s\.?|usa|us|united states|canada)[- ]based\s+(?:candidates|applicants|residents)?\s*only\b/#,
            #/\bremote\s*[(-]?\s*(?<country>u\.s\.?|usa|us|united states|canada)\s+only\b/#,
        ]
        for sentence in sentences {
            for pattern in patterns {
                if let match = sentence.firstMatch(of: pattern) { return country(match.output.country) }
            }
        }
        return nil
    }

    /// French asked for: "bilingual" (in Canada, English and French), or French with "required",
    /// "fluent", "maîtrise" and the like.
    static func requiresFrench(_ sentences: [String], country: Country?) -> Bool {
        let otherLanguages = [
            "spanish", "mandarin", "cantonese", "punjabi", "hindi", "portuguese", "german", "japanese", "korean",
            "arabic", "tagalog", "italian", "vietnamese",
        ]
        let required = [
            "required", "requis", "requise", "mandatory", "obligatoire", "essential", "essentiel", "essentielle",
            "exige",
            "exigee", "must", "fluent", "fluency", "proficient", "proficiency", "maitrise", "written and spoken",
            "spoken and written", "parle et ecrit",
        ]
        return sentences.contains { sentence in
            let french = TextScan.containsAny(sentence, ["french", "francais"])
            let bilingual = TextScan.containsAny(sentence, ["bilingual", "bilingue", "bilingualism", "bilinguisme"])
            if bilingual && (french || (country == .canada && !TextScan.containsAny(sentence, otherLanguages))) {
                return true
            }
            return french && TextScan.containsAny(sentence, required)
        }
    }

    private static func country(_ text: Substring) -> Country {
        text.hasPrefix("c") ? .canada : .unitedStates
    }
}
