import Foundation

/// Prepares a posting for `analyzeJob` (SPEC §5.5, "Posting cleanup before sending"): boilerplate
/// sections and paragraphs go (equal-opportunity statements, benefits), and a posting still over
/// the limit keeps its requirements first, then its responsibilities, then the rest.
public enum PostingCleaner {
    public static let shortened = "[posting shortened to fit]"

    /// `limit` is in characters; the result never exceeds it.
    public static func clean(_ markdown: String, limit: Int) -> String {
        let sections = Self.sections(of: markdown).filter { !$0.isBoilerplate }.map { $0.withoutBoilerplateLines() }
            .filter { !$0.isEmpty }
        let whole = sections.flatMap(\.lines).joined(separator: "\n")
        guard whole.count > limit else { return whole }
        let room = limit - shortened.count - 1
        guard room > 0 else { return "" }
        var kept: [String] = []
        var length = 0
        var lastWasHeading = false
        // Requirements first; sections of equal priority keep their order.
        let ordered = sections.enumerated().sorted {
            ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset)
        }
        for section in ordered.map(\.element) {
            for (index, line) in section.lines.enumerated() {
                let added = (kept.isEmpty ? 0 : 1) + line.count
                guard length + added <= room else {
                    if kept.isEmpty { kept = [String(line.prefix(room))] }
                    if lastWasHeading, kept.count > 1 { kept.removeLast() }  // a heading with nothing under it
                    return (kept + [shortened]).joined(separator: "\n")
                }
                kept.append(line)
                length += added
                lastWasHeading = index == 0 && section.heading != nil
            }
        }
        return (kept + [shortened]).joined(separator: "\n")
    }

    struct Section {
        /// Folded, for classifying; nil for the text before the first heading.
        let heading: String?
        var lines: [String]

        var isEmpty: Bool { lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

        var isBoilerplate: Bool {
            heading.map { heading in boilerplateHeadings.contains { heading.contains($0) } } ?? false
        }

        /// 0 for requirements, 1 for responsibilities, 2 for anything else, 3 for "About us".
        var priority: Int {
            guard let heading else { return 2 }
            if requirementHeadings.contains(where: heading.contains) { return 0 }
            if responsibilityHeadings.contains(where: heading.contains) { return 1 }
            if aboutHeadings.contains(where: heading.contains) { return 3 }
            return 2
        }

        func withoutBoilerplateLines() -> Section {
            var copy = self
            copy.lines = lines.filter { line in
                let folded = TextScan.fold(line)
                return !boilerplateLines.contains { folded.contains($0) }
            }
            while let last = copy.lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                copy.lines.removeLast()
            }
            return copy
        }
    }

    static func sections(of markdown: String) -> [Section] {
        var sections: [Section] = []
        var current = Section(heading: nil, lines: [])
        for line in markdown.components(separatedBy: .newlines) {
            if let heading = TextScan.heading(line) {
                sections.append(current)
                current = Section(heading: TextScan.fold(heading), lines: [line])
            } else {
                current.lines.append(line)
            }
        }
        sections.append(current)
        return sections
    }

    private static let boilerplateHeadings = [
        "benefit", "perks", "what we offer", "total rewards", "why join", "why work", "why you'll love",
        "equal opportunity", "eeo", "diversity", "inclusion", "accommodation", "privacy", "pay transparency",
        "e-verify", "how to apply", "avantages", "ce que nous offrons", "pourquoi nous",
    ]
    private static let boilerplateLines = [
        "equal opportunity", "without regard to", "regardless of race", "reasonable accommodation", "e-verify",
        "protected veteran", "applicants with disabilities", "pay transparency", "accessibility for ontarians",
        "egalite des chances", "equite en matiere d'emploi", "mesures d'adaptation",
    ]
    private static let requirementHeadings = [
        "requirement", "qualification", "skill", "experience", "what you bring", "what you'll bring", "who you are",
        "you have", "you bring", "must have", "nice to have", "about you", "looking for", "competenc", "you'll need",
        "what you need", "profil", "exigence", "atout",
    ]
    private static let responsibilityHeadings = [
        "responsibilit", "what you'll do", "what you will do", "the role", "the job", "duties", "day to day",
        "day-to-day", "your impact", "in this role", "you will", "mandat", "responsabilit", "taches",
    ]
    private static let aboutHeadings = [
        "about us", "about the company", "who we are", "our company", "company overview", "our story", "a propos",
    ]
}
