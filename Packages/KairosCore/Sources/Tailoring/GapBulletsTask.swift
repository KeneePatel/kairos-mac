import AI
import Foundation
import Resume

/// What `gapBullets` gets: the requirements no bullet shows that one of your
/// Can-discuss skills answers, the roles it may add to, your skill names and the cap per role.
/// Prompts call roles "e1" and requirements "r1".
public struct GapBulletsInput: Sendable {
    /// A requirement a gap bullet may cover, and the Can-discuss skills that answer it.
    public struct Target: Sendable, Equatable {
        public let requirement: String
        /// Canonical technologies, for the check.
        let technologies: Set<String>
        /// Your Can-discuss skills as you wrote them, for the prompt and the problems.
        public let skills: [String]
    }

    public let brief: WriterBrief
    public let roles: [TailoredResume.Entry]
    public let targets: [Target]
    public let proven: [String]
    public let canDiscuss: [String]
    public let perRole: Int
    public let totalYears: Double?
    public let verifier: Verifier

    public init(
        brief: WriterBrief, written resume: TailoredResume, master: MasterResume, perRole: Int, verifier: Verifier
    ) {
        self.brief = brief
        roles = resume.experience
        targets = Self.targets(for: brief.requirements, resume: resume, master: master)
        proven = master.skills.filter { $0.level == .proven }.map(\.name)
        canDiscuss = master.skills.filter { $0.level == .canDiscuss }.map(\.name)
        self.perRole = min(StretchSettings.maxPerRole, max(0, perRole))
        totalYears = master.header.totalYears
        self.verifier = verifier
    }

    /// Nothing to ask for: no role, no target, or a cap of zero.
    public var isEmpty: Bool { roles.isEmpty || targets.isEmpty || perRole == 0 }

    func role(_ short: String) -> UUID? {
        guard short.hasPrefix("e"), let index = Int(short.dropFirst()), roles.indices.contains(index - 1) else {
            return nil
        }
        return roles[index - 1].entryID
    }

    func target(_ short: String) -> Target? {
        guard short.hasPrefix("r"), let index = Int(short.dropFirst()), targets.indices.contains(index - 1) else {
            return nil
        }
        return targets[index - 1]
    }

    /// Must-haves, then nice-to-haves, that no bullet shows and a Can-discuss skill answers.
    /// Conditions such as work authorization never qualify.
    static func targets(for requirements: JobRequirements, resume: TailoredResume, master: MasterResume) -> [Target] {
        let canDiscuss = master.skills.filter { $0.level == .canDiscuss }.map { skill in
            (name: skill.name, technologies: Keywords.technologies(in: skill.name).union([skill.name.lowercased()]))
        }
        let shown = Set(resume.allBullets.flatMap { Keywords.technologies(in: $0.text) })
        var seen: Set<String> = []
        return (requirements.musts + requirements.nices).compactMap { text in
            guard !Requirements.isCondition(text), seen.insert(text).inserted else { return nil }
            let terms = Keywords.terms(in: text)
            guard !terms.isEmpty, terms.isDisjoint(with: shown) else { return nil }
            let answering = canDiscuss.filter { !$0.technologies.isDisjoint(with: terms) }
            guard !answering.isEmpty else { return nil }
            return Target(
                requirement: text, technologies: terms.intersection(answering.flatMap(\.technologies)),
                skills: answering.map(\.name))
        }
    }
}

/// `gapBullets`' reply: each bullet names its role and the requirement it covers.
public struct GapBulletsOutput: Decodable, Sendable, Equatable {
    public struct Bullet: Decodable, Sendable, Equatable {
        public var role: String
        public var covers: String
        public var text: String
    }

    public var bullets: [Bullet]
}

/// `gapBullets` (Stretch mode only): up to the cap per role of bullets the master resume doesn't
/// back, each covering one uncovered requirement with a Can-discuss skill. The stretch verifier
/// checks every one against the hard limits; they come back flagged (`gap`, `verified: false`).
public struct GapBulletsTask: AITask {
    public static let id = TaskID.gapBullets
    public static let promptVersion = 1
    public static let outputSchema = JSONSchema.object([
        .required(
            "bullets",
            .array(
                of: .object([
                    .required("role", .string(maxLength: 8)),
                    .required("covers", .string(maxLength: 8)),
                    .required("text", .string(maxLength: 600)),
                ]), maxItems: 12))
    ])

    public init() {}

    public func messages(for input: GapBulletsInput, budget: TokenBudget) -> [ChatMessage] {
        let instructions = Prompts.text(Self.id, version: Self.promptVersion, in: .module)
        let requirements = input.targets.enumerated().map { index, target in
            "[r\(index + 1)] \(target.requirement) (answer with: \(target.skills.joined(separator: " or ")))"
        }
        let roles = input.roles.enumerated().map { index, role in
            let heading = [role.title, role.organization, role.dates].compactMap { $0 }.joined(separator: " · ")
            let bullets = role.bullets.map { "- \($0.text)" }.joined(separator: "\n")
            return "<role id=\"e\(index + 1)\">\(heading)\n\(bullets)\n</role>"
        }
        let years = input.totalYears.map { " Total years of experience: \($0.formatted())." } ?? ""
        let data = """
            <job>
            Title: \(input.brief.jobTitle)
            </job>
            <requirements>
            \(requirements.joined(separator: "\n"))
            </requirements>
            <skills>
            \(input.proven.joined(separator: ", "))
            </skills>
            <can_discuss>
            \(input.canDiscuss.joined(separator: ", "))
            </can_discuss>
            <roles>
            \(roles.joined(separator: "\n"))
            </roles>
            <limits>
            At most \(input.perRole) bullet\(input.perRole == 1 ? "" : "s") per role.\(years)
            </limits>
            """
        return [.system(instructions + "\n\n" + input.brief.locale.instruction), .user(data)]
    }

    /// Roles and requirements given, the cap per role, each requirement once, the length, a
    /// Can-discuss skill that answers it, and the stretch verifier. None at all is a fine reply.
    public func check(_ output: GapBulletsOutput, for input: GapBulletsInput) throws(AIError) {
        var problems: [String] = []
        var counts: [String: Int] = [:]
        var covered: Set<String> = []
        for bullet in output.bullets {
            let text = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                problems.append("A bullet is blank.")
                continue
            }
            let quoted = "“\(text.prefix(40))…”"
            guard input.role(bullet.role) != nil else {
                problems.append("\(quoted) is under “\(bullet.role)”, which isn't one of the roles given.")
                continue
            }
            guard let target = input.target(bullet.covers) else {
                problems.append("\(quoted) covers “\(bullet.covers)”, which isn't one of the requirements given.")
                continue
            }
            counts[bullet.role, default: 0] += 1
            if !covered.insert(bullet.covers).inserted {
                problems.append("\(bullet.covers) is covered more than once.")
            }
            if text.count > Polish.maxBulletLength {
                problems.append("\(quoted) is over \(Polish.maxBulletLength) characters.")
            }
            if text.contains(ContactRedactor.marker) {
                problems.append("\(quoted) contains \(ContactRedactor.marker); leave that detail out.")
            }
            if Keywords.technologies(in: text).isDisjoint(with: target.technologies) {
                problems.append(
                    "\(quoted) covers \(bullet.covers) but names none of: \(target.skills.joined(separator: ", ")).")
            }
            for violation in input.verifier.check(TailoredBullet(text: text, sourceIDs: [], gap: true)) {
                problems.append("\(quoted): \(violation.detail)")
            }
        }
        for (role, count) in counts.sorted(by: { $0.key < $1.key }) where count > input.perRole {
            problems.append("\(role) has \(count) bullets; the limit is \(input.perRole) per role.")
        }
        if !problems.isEmpty {
            throw .invalidOutput(problems.prefix(6).joined(separator: " "))
        }
    }

    /// Entry id → its gap bullets, flagged, each naming the requirement it covers. They rank
    /// lowest, so page fitting drops them first.
    public static func written(_ output: GapBulletsOutput, input: GapBulletsInput) -> [UUID: [TailoredBullet]] {
        var written: [UUID: [TailoredBullet]] = [:]
        for bullet in output.bullets {
            guard let entry = input.role(bullet.role), let target = input.target(bullet.covers) else { continue }
            written[entry, default: []].append(
                TailoredBullet(
                    text: bullet.text.trimmingCharacters(in: .whitespacesAndNewlines), sourceIDs: [], gap: true,
                    rank: 0, covers: target.requirement))
        }
        return written
    }
}
