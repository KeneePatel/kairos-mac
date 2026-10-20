import Foundation

/// How many years of experience a posting requires (SPEC §5.2): the largest minimum among its
/// required mentions, in English or French. Mentions in preferred or nice-to-have sentences and
/// sections don't count, nor do years that aren't about experience ("founded 12 years ago"). Nil
/// when it can't tell, which keeps the job.
public enum YearsParser {
    public static func requiredYears(in text: String) -> Int? {
        requiredYears(inSentences: TextScan.requiredSentences(text))
    }

    static func requiredYears(inSentences sentences: [String]) -> Int? {
        sentences.flatMap(mentions).max()
    }

    /// The minimum years each requirement in one folded sentence asks for.
    static func mentions(in sentence: String) -> [Int] {
        let english =
            #/
            (?<prefix>at\ least|minimum(?:\ of)?|min\.?|over|more\ than|no\ less\ than)?\s*
            \b(?<n>\d{1,2}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty)\b
            \s*(?:\(\d{1,2}\)\s*)?
            (?<plus>\+)?\s*
            (?<range>(?:-|–|to)\s*(?:\d{1,2}|[a-z]+)\s*\+?\s*)?
            (?:years?|yrs?)\b
            /#
        let french =
            #/
            (?<prefix>au\ moins|minimum(?:\ de)?|plus\ de)?\s*
            \b(?<n>\d{1,2})\s*(?<plus>\+)?\s*
            (?<range>(?:a|-|–)\s*\d{1,2}\s*)?
            ans\b
            /#
        var found: [Int] = []
        for match in sentence.matches(of: english) {
            let output = match.output
            let before = sentence[..<match.range.lowerBound].suffix(30)
            let after = sentence[match.range.upperBound...].prefix(60)
            guard let years = number(output.n), !isIncidental(before: before, after: after) else { continue }
            let marked = output.prefix != nil || output.plus != nil || output.range != nil
            if marked || after.contains(experienceAfterYears) { found.append(years) }
        }
        for match in sentence.matches(of: french) {
            let output = match.output
            let after = sentence[match.range.upperBound...].prefix(60)
            guard let years = number(output.n) else { continue }
            let marked = output.prefix != nil || output.plus != nil || output.range != nil
            if marked || after.contains(#/^\s*(?:et plus\b|(?:d'|de\s+)(?:\w+\s+){0,2}?experience)/#) {
                found.append(years)
            }
        }
        return found.filter { (1...30).contains($0) }
    }

    /// "of relevant experience", "building …", "or more", "minimum" and the like, right after "years".
    private static var experienceAfterYears: Regex<Substring> {
        #/
        ^\s*'?\s*(?:
            (?:of\s+)?(?:\S+\s+){0,4}?(?:experience|exp\b)
          | (?:of\s+)?(?:\S+\s+){0,2}?(?:building|developing|working|writing|designing|leading|managing|
                programming|coding|shipping|delivering|engineering)\b
          | (?:or\ more|or\ above|and\ above|and\ up|minimum|min\b|required|plus)
        )
        /#
    }

    /// Years about the company, a benefit or a time span rather than your experience.
    private static func isIncidental(before: Substring, after: Substring) -> Bool {
        after.contains(
            #/^\s*,?\s*(?:ago\b|old\b|we\b|we've|we\ have|our\b|in\ business|in\ a\ row|running|of\ service)/#)
            || before.contains(
                #/(?:founded|since|history|anniversary|warranty|vest\w*|after|within|every|per|past|last)(?:\s+\w+){0,2}\s*$/#
            )
    }

    private static func number(_ text: Substring) -> Int? {
        Int(text) ?? words[String(text)]
    }

    private static let words = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20,
    ]
}
