import Foundation
import KairosKit

/// Names a typed task. Part of cache keys, call-log rows and the "routes" in AI settings.
public struct TaskID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    public static let importResume = TaskID("importResume")
    public static let importGitHubRepo = TaskID("importGitHubRepo")
    public static let analyzeJob = TaskID("analyzeJob")
    public static let suggestEvidence = TaskID("suggestEvidence")
    public static let writeSummary = TaskID("writeSummary")
    public static let writeSkills = TaskID("writeSkills")
    public static let writeExperience = TaskID("writeExperience")
    public static let writeProjects = TaskID("writeProjects")
    public static let shortenBullets = TaskID("shortenBullets")
    public static let gapBullets = TaskID("gapBullets")
    public static let coverLetter = TaskID("coverLetter")

    /// Every task, in the order Settings lists them.
    public static let catalog: [TaskID] = [
        .analyzeJob, .suggestEvidence, .writeExperience, .writeProjects, .writeSkills, .writeSummary, .shortenBullets,
        .gapBullets, .coverLetter, .importResume, .importGitHubRepo,
    ]
}

/// How many tokens a task may send and receive. Estimates are characters ÷ 4.
public struct TokenBudget: Equatable, Sendable {
    public let input: Int
    public let output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }

    public static func estimate(_ text: String) -> Int { (text.count + 3) / 4 }

    /// The characters of input this budget leaves after `used` characters of fixed text.
    public func characters(after used: Int) -> Int { max(0, input * 4 - used) }
}

/// The two model classes tasks ask for by default: a provider's best fast model and its cheapest.
public enum ModelClass: String, Sendable, CaseIterable, Codable {
    case flash, flashLite
}

/// Each task's limits and defaults.
public struct TaskProfile: Sendable, Equatable {
    public let budget: TokenBudget
    public let temperature: Double
    public let modelClass: ModelClass
    /// 60 s for extraction, 120 s for writing. Local models keep their own, longer limit.
    public let timeoutSeconds: Int

    public init(budget: TokenBudget, temperature: Double, modelClass: ModelClass, timeoutSeconds: Int = 60) {
        self.budget = budget
        self.temperature = temperature
        self.modelClass = modelClass
        self.timeoutSeconds = timeoutSeconds
    }

    public static func of(_ task: TaskID) -> TaskProfile { catalog[task] ?? fallback }

    static let catalog: [TaskID: TaskProfile] = [
        .importResume: TaskProfile(
            budget: TokenBudget(input: 10_000, output: 6_000), temperature: 0, modelClass: .flash, timeoutSeconds: 120),
        .importGitHubRepo: TaskProfile(budget: TokenBudget(input: 3_000, output: 600), temperature: 0.2, modelClass: .flashLite),
        // 6,000 out (1,500 until 2026-10-26): a long posting's 25 requirements took 3,954 tokens, so
        // every model's reply was cut off and the job never got a verdict.
        .analyzeJob: TaskProfile(budget: TokenBudget(input: 7_000, output: 6_000), temperature: 0, modelClass: .flashLite),
        .suggestEvidence: TaskProfile(budget: TokenBudget(input: 4_000, output: 800), temperature: 0.3, modelClass: .flashLite),
        .writeSummary: writer, .writeSkills: writer, .writeExperience: writer, .writeProjects: writer,
        .shortenBullets: TaskProfile(budget: TokenBudget(input: 3_000, output: 2_000), temperature: 0.2, modelClass: .flashLite),
        .gapBullets: TaskProfile(
            budget: TokenBudget(input: 3_000, output: 800), temperature: 0.5, modelClass: .flash, timeoutSeconds: 120),
        .coverLetter: TaskProfile(
            budget: TokenBudget(input: 4_000, output: 1_200), temperature: 0.6, modelClass: .flash, timeoutSeconds: 120),
    ]

    /// Room for six bullets a role and four projects, more than a page holds: the page fitter keeps
    /// what earns its lines.
    static let writer = TaskProfile(
        budget: TokenBudget(input: 6_000, output: 3_000), temperature: 0.4, modelClass: .flash, timeoutSeconds: 120)

    static let fallback = TaskProfile(budget: TokenBudget(input: 4_000, output: 1_000), temperature: 0, modelClass: .flash)
}

public struct ChatMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case system, user, assistant }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    /// Role, rules and the output contract: rarely changes, so providers can cache it as a prefix.
    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: .system, content: content) }
    /// Data in tagged blocks (`<job_posting>`, `<entries>`); the rules say it's data, never instructions.
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: .user, content: content) }
    public static func assistant(_ content: String) -> ChatMessage { ChatMessage(role: .assistant, content: content) }
}

/// Every model use is a typed task, so calling code never handles raw text: the router sends the
/// task's messages, validates the reply against its schema, decodes it and runs its check.
public protocol AITask: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Decodable & Sendable
    static var id: TaskID { get }
    /// Bumped on every prompt change; part of cache keys.
    static var promptVersion: Int { get }
    /// Sent to providers that take schemas; always checked here.
    static var outputSchema: JSONSchema { get }
    func messages(for input: Input, budget: TokenBudget) -> [ChatMessage]
    /// Rules a schema can't express, such as "every source id exists". Throws `AIError.invalidOutput`.
    func check(_ output: Output, for input: Input) throws(AIError)
}

extension AITask {
    public func check(_ output: Output, for input: Input) throws(AIError) {}
}

/// A task's built-in instructions: `<task>.v<N>.md` in the bundle of the module that owns the task.
public enum Prompts {
    public static func text(_ task: TaskID, version: Int, in bundle: Bundle) -> String {
        let name = "\(task.rawValue).v\(version)"
        guard
            let url = bundle.url(forResource: name, withExtension: "md", subdirectory: "Prompts")
                ?? bundle.url(forResource: name, withExtension: "md", subdirectory: "Resources/Prompts")
                ?? bundle.url(forResource: name, withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text placed in a tagged data block, with anything that could close the block defused.
    public static func block(_ tag: String, _ text: String) -> String {
        let safe = text.replacing("</\(tag)>", with: "</ \(tag)>")
        return "<\(tag)>\n\(safe)\n</\(tag)>"
    }
}
