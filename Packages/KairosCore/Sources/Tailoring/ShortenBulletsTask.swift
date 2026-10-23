import Foundation
import LLM
import MasterResume

/// Bullets that run a few words onto another line, each with the most characters it may keep
/// (resume v2 plan, phase 1). Prompts call them "s1", "s2".
public struct ShortenBulletsInput: Sendable {
    public struct Item: Sendable, Equatable {
        /// Where it sits: "experience" or "projects", the entry's place, the bullet's place.
        public let section: MatchScore.Section
        public let entry: Int
        public let bullet: Int
        public let text: String
        public let sourceIDs: [UUID]
        /// A line fewer than it takes now, by the characters its own lines hold.
        public let limit: Int
    }

    public let items: [Item]
    public let locale: SpellingLocale
    public let verifier: Verifier

    /// The resume's short wraps, from its measured layout; empty when none, or when it wasn't
    /// measured. A gap bullet is left alone.
    public init(
        _ resume: TailoredResume, layout: PageLayout, lineCharacters: Int, locale: SpellingLocale, verifier: Verifier
    ) {
        var items: [Item] = []
        for (section, entries, measured) in [
            (MatchScore.Section.experience, resume.experience, layout.experience),
            (.projects, resume.projects, layout.projects),
        ] {
            for (place, entry) in entries.enumerated() where place < measured.count {
                for (index, bullet) in entry.bullets.enumerated() where index < measured[place].count {
                    let lines = measured[place][index]
                    guard lines.isShortWrap, !bullet.gap else { continue }
                    let perLine = lines.lineCharacters ?? Double(lineCharacters)
                    items.append(
                        Item(
                            section: section, entry: place, bullet: index, text: bullet.text,
                            sourceIDs: bullet.sourceIDs, limit: Int(Double(lines.lines - 1) * perLine) - 2))
                }
            }
        }
        self.items = items
        self.locale = locale
        self.verifier = verifier
    }

    func id(_ index: Int) -> String { "s\(index + 1)" }
}

public struct ShortenBulletsOutput: Decodable, Sendable, Equatable {
    public struct Bullet: Decodable, Sendable, Equatable {
        public var id: String
        public var text: String
    }

    public var bullets: [Bullet]
}

/// `shortenBullets`: each short-wrap bullet cut to fit a line fewer, keeping every number and
/// claim. Code checks the lengths, the numbers and the verifier's rules, so a reply that loses a
/// fact never lands.
public struct ShortenBulletsTask: LLMTask {
    public static let id = TaskID.shortenBullets
    public static let promptVersion = 1
    public static let outputSchema = JSONSchema.object([
        .required(
            "bullets",
            .array(
                of: .object([.required("id", .string(maxLength: 8)), .required("text", .string(maxLength: 400))]),
                maxItems: 40))
    ])

    public init() {}

    public func messages(for input: ShortenBulletsInput, budget: TokenBudget) -> [ChatMessage] {
        let instructions = PromptLibrary.instructions(for: Self.id, version: Self.promptVersion) ?? ""
        let bullets = input.items.enumerated().map { index, item in
            "[\(input.id(index))] (at most \(item.limit) characters) \(item.text)"
        }
        let data = """
            <bullets>
            \(bullets.joined(separator: "\n"))
            </bullets>
            """
        return [.system(instructions + "\n\n" + input.locale.instruction), .user(data)]
    }

    /// Every bullet answered, and at least one that passes; a reply that fixes none goes back for
    /// repair. A bullet that fails on its own keeps its original words (`applying`).
    public func check(_ output: ShortenBulletsOutput, for input: ShortenBulletsInput) throws {
        var missing: [String] = []
        var failures: [String] = []
        var passing = 0
        let answered = Dictionary(output.bullets.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        for (index, item) in input.items.enumerated() {
            let id = input.id(index)
            guard let text = answered[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                missing.append("\(id) is missing.")
                continue
            }
            let found = Self.problems(text, for: item, verifier: input.verifier)
            if found.isEmpty { passing += 1 } else { failures += found.map { "\(id) \($0)" } }
        }
        if !missing.isEmpty || passing == 0 {
            throw LLMError.invalidOutput((missing + failures).prefix(6).joined(separator: " "))
        }
    }

    /// Too long, a number dropped, the redaction marker, or a claim its sources don't back.
    static func problems(_ text: String, for item: ShortenBulletsInput.Item, verifier: Verifier) -> [String] {
        var problems: [String] = []
        if text.count > item.limit { problems.append("is \(text.count) characters; keep it to \(item.limit).") }
        let numbers = Set(Numbers.mentions(in: text).map(\.value))
        for number in Numbers.mentions(in: item.text) where !numbers.contains(number.value) {
            problems.append("drops “\(item.text[number.range])”; keep every number.")
        }
        if text.contains(ContactRedactor.marker) {
            problems.append("contains \(ContactRedactor.marker); leave that detail out.")
        }
        for violation in verifier.check(TailoredBullet(text: text, sourceIDs: item.sourceIDs)) {
            problems.append(violation.detail)
        }
        return problems
    }

    /// The resume with each shortened bullet in its place, polished like the writers' bullets.
    public static func applying(
        _ output: ShortenBulletsOutput, input: ShortenBulletsInput, to resume: TailoredResume, polish: Polish
    ) -> TailoredResume {
        let texts = Dictionary(output.bullets.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var resume = resume
        for (index, item) in input.items.enumerated() {
            guard let written = texts[input.id(index)]?.trimmingCharacters(in: .whitespacesAndNewlines),
                problems(written, for: item, verifier: input.verifier).isEmpty
            else { continue }
            let text = polish.text(written)
            if item.section == .experience {
                resume.experience[item.entry].bullets[item.bullet].text = text
            } else {
                resume.projects[item.entry].bullets[item.bullet].text = text
            }
        }
        return resume
    }
}
