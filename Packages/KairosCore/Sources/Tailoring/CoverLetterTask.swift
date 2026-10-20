import Foundation
import LLM
import MasterResume

/// A cover letter as a build stores and renders it (SPEC §5.3, Cover letter). The model writes only
/// the paragraphs; code adds the header, date, greeting and sign-off from your master resume.
public struct CoverLetter: Codable, Sendable, Equatable {
    /// Your name and contact line, as on the resume.
    public var header: TailoredResume.Header
    public var date: String
    public var company: String
    public var jobTitle: String
    public var greeting: String
    public var paragraphs: [String]
    public var closing: String
    public var signature: String

    public init(
        header: TailoredResume.Header, date: String, company: String, jobTitle: String, greeting: String,
        paragraphs: [String], closing: String, signature: String
    ) {
        self.header = header
        self.date = date
        self.company = company
        self.jobTitle = jobTitle
        self.greeting = greeting
        self.paragraphs = paragraphs
        self.closing = closing
        self.signature = signature
    }
}

/// The `build.cover_letter` column: asked for when the build was queued, then written or not.
public struct CoverLetterRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case requested, done, failed }

    public var status: Status
    public var letter: CoverLetter?
    /// Why there's no letter, in words.
    public var error: String?

    public init(status: Status, letter: CoverLetter? = nil, error: String? = nil) {
        self.status = status
        self.letter = letter
        self.error = error
    }

    public static let requested = CoverLetterRecord(status: .requested)
}

/// What `coverLetter` gets (SPEC §5.5 catalog): the job's title, company and requirements, the
/// build's selected entries with their bullets, your Proven skill names and total years. Never your
/// name or contact details.
public struct CoverLetterInput: Sendable {
    public let brief: WriterBrief
    public let company: String
    public let entries: [SelectedEntry]
    public let skills: [Skill]
    public let totalYears: Double?
    public let verifier: Verifier

    public init(
        brief: WriterBrief, company: String, entries: [SelectedEntry], skills: [Skill], totalYears: Double?,
        verifier: Verifier
    ) {
        self.brief = brief
        self.company = company
        self.entries = entries
        self.skills = skills
        self.totalYears = totalYears
        self.verifier = verifier
    }
}

public struct CoverLetterOutput: Decodable, Sendable, Equatable {
    public var paragraphs: [String]
}

/// `coverLetter` (optional per build): three to five paragraphs from the selected entries. Every
/// claim goes through the verifier's letter rules; code adds everything around the paragraphs.
public struct CoverLetterTask: LLMTask {
    public static let id = TaskID.coverLetter
    public static let promptVersion = 1
    public static let outputSchema = JSONSchema.object([
        .required("paragraphs", .array(of: .string(maxLength: 1_500), maxItems: 6))
    ])
    /// A one-page letter: about 250 to 350 words, with room either side.
    static let words = 150...450
    static let paragraphCount = 3...5

    public init() {}

    public func messages(for input: CoverLetterInput, budget: TokenBudget) -> [ChatMessage] {
        let instructions = PromptLibrary.instructions(for: Self.id, version: Self.promptVersion) ?? ""
        let entries = input.entries.map { selected in
            let bullets = selected.bullets.map { ranked in
                "- \(ranked.bullet.text)"
                    + (ranked.bullet.metrics.isEmpty
                        ? "" : " (metrics: \(ranked.bullet.metrics.joined(separator: "; ")))")
            }
            return "<entry>\(SectionWriter.heading(selected.entry))\n\(bullets.joined(separator: "\n"))\n</entry>"
        }
        let requirements =
            input.brief.requirements.musts.map { "Must: \($0)" } + input.brief.requirements.nices.map { "Nice: \($0)" }
        let data = """
            <job>
            Title: \(input.brief.jobTitle)
            Company: \(input.company)
            </job>
            <requirements>
            \(requirements.joined(separator: "\n"))
            </requirements>
            <skills>
            \(input.skills.map(\.name).joined(separator: ", "))
            </skills>
            <entries>
            \(entries.joined(separator: "\n"))
            </entries>
            <years>
            \(input.totalYears.map { "Total years of experience: \($0.formatted())." } ?? "Not stated.")
            </years>
            """
        return [.system(instructions + "\n\n" + input.brief.locale.instruction), .user(data)]
    }

    /// Paragraph count and length; no greeting, sign-off, contact details or placeholders, since
    /// code adds those; and every paragraph through the verifier's letter rules.
    public func check(_ output: CoverLetterOutput, for input: CoverLetterInput) throws {
        let paragraphs = Self.cleaned(output)
        var problems: [String] = []
        if !Self.paragraphCount.contains(paragraphs.count) {
            problems.append(
                "Write \(Self.paragraphCount.lowerBound) to \(Self.paragraphCount.upperBound) paragraphs; this has \(paragraphs.count)."
            )
        }
        let words = paragraphs.reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        if !Self.words.contains(words) {
            problems.append("It's \(words) words; keep it between 250 and 350.")
        }
        if let first = paragraphs.first, first.contains(/^(?i)(?:dear|hello|hi|greetings|to whom)\b/) {
            problems.append("Leave out the greeting; it's added for you.")
        }
        let text = paragraphs.joined(separator: "\n")
        if text.contains(/(?i)\b(?:sincerely|best regards|kind regards|warm regards|yours truly|respectfully)\b/) {
            problems.append("Leave out the sign-off; it's added for you.")
        }
        if text.contains(Self.contactDetail) {
            problems.append("Leave out contact details and links; they're added for you.")
        }
        if let placeholder = text.firstMatch(of: /\[[^\]]{1,40}\]/) {
            problems.append("“\(placeholder.output)” is a placeholder; write it out or leave it out.")
        }
        for paragraph in paragraphs {
            for violation in input.verifier.check(letter: paragraph) {
                problems.append("“\(paragraph.prefix(40))…”: \(violation.detail)")
            }
        }
        if !problems.isEmpty {
            throw LLMError.invalidOutput(problems.prefix(6).joined(separator: " "))
        }
    }

    /// The letter: your header, today's date, a greeting to the company's hiring team, the polished
    /// paragraphs, and your name under "Sincerely,".
    public static func letter(
        _ output: CoverLetterOutput, input: CoverLetterInput, header: TailoredResume.Header, date: Date
    ) -> CoverLetter {
        let polish = Polish(locale: input.brief.locale)
        let locale = Locale(identifier: input.brief.locale == .unitedStates ? "en_US" : "en_CA")
        return CoverLetter(
            header: header, date: date.formatted(.dateTime.month(.wide).day().year().locale(locale)),
            company: input.company, jobTitle: input.brief.jobTitle, greeting: "Dear \(input.company) hiring team,",
            paragraphs: cleaned(output).map(polish.text), closing: "Sincerely,", signature: header.name)
    }

    private static func cleaned(_ output: CoverLetterOutput) -> [String] {
        output.paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// An email, a link, or a phone number.
    private static var contactDetail: Regex<Substring> {
        /(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|https?:\/\/|www\.|linkedin\.com|github\.com|\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b/
    }
}
