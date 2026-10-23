import Foundation
import LLM

/// A build's model calls as they happen, for the Build screen: each task's model, how long it has
/// taken, its retries and switches, and the notes worth keeping when a model failed or another
/// took over. Built from `CallEvent`s live, or from the call log for a build already made.
public struct BuildActivity: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case asking
        case retrying(String)
        case answered(cached: Bool)
        /// Every model in its chain failed; the last one's reason.
        case gaveUp(String)
    }

    public struct Failure: Sendable, Equatable {
        public let model: ModelRef
        public let reason: String
    }

    /// One task's run: a writer, the letter, one rewrite pass.
    public struct Run: Sendable, Equatable, Identifiable {
        public let id: Int
        public let task: TaskID
        public var model: ModelRef
        public var started: Date
        public var finished: Date?
        public var state: State
        /// Models that failed before the current one, with why.
        public var failures: [Failure] = []

        /// Seconds so far, or in all when it's over.
        public func seconds(at now: Date) -> Double { (finished ?? now).timeIntervalSince(started) }
    }

    /// Something a build worked around, for its "What happened" list.
    public struct Note: Sendable, Equatable, Hashable {
        public enum Kind: Sendable, Equatable, Hashable {
            /// Another model in the chain took over.
            case fellBack
            /// No model answered: a writer used your words, an optional step was skipped.
            case gaveUp
        }

        public let kind: Kind
        public let task: TaskID
        public let text: String
    }

    public private(set) var runs: [Run] = []

    public init() {}

    /// A finished build's calls from the log, replayed: each failure, and whether the call after it
    /// for the same task took over.
    public init(calls: [CallRecord]) {
        var lastFailed: [TaskID: Bool] = [:]
        for call in calls {
            let model = ModelRef(provider: call.provider, model: call.model)
            let finished = call.at.addingTimeInterval(Double(call.latency.components.seconds))
            switch call.outcome {
            case .failed, .rateLimited:
                apply(.asking(task: call.task, model: model, fallback: lastFailed[call.task] == true), at: call.at)
                let reason = call.errorCode.map(LLMError.reason(code:)) ?? "failed"
                apply(.failed(task: call.task, model: model, reason: reason, detail: nil), at: finished)
                lastFailed[call.task] = true
            case .ok, .repaired, .fellBack, .cached:
                apply(.asking(task: call.task, model: model, fallback: lastFailed[call.task] == true), at: call.at)
                let seconds = Double(call.latency.components.seconds)
                apply(
                    .answered(task: call.task, model: model, seconds: seconds, cached: call.outcome == .cached),
                    at: finished)
                lastFailed[call.task] = false
            }
        }
    }

    public mutating func apply(_ event: CallEvent, at date: Date) {
        switch event {
        case .asking(let task, let model, let fallback):
            if fallback, let index = open(task) {
                runs[index].model = model
                runs[index].state = .asking
                runs[index].finished = nil
            } else {
                runs.append(Run(id: runs.count, task: task, model: model, started: date, state: .asking))
            }
        case .retrying(let task, _, let reason):
            if let index = open(task) { runs[index].state = .retrying(reason) }
        case .failed(let task, let model, let reason, _):
            // A model skipped for failing a moment ago fails before anything was asked.
            let index =
                open(task)
                ?? {
                    runs.append(Run(id: runs.count, task: task, model: model, started: date, state: .asking))
                    return runs.count - 1
                }()
            runs[index].failures.append(Failure(model: model, reason: reason))
            // Given up until the chain's next model is asked; a build's end settles it.
            runs[index].state = .gaveUp(reason)
            runs[index].finished = date
        case .answered(let task, let model, _, let cached):
            if let index = open(task) ?? lastFailed(task) {
                runs[index].model = model
                runs[index].state = .answered(cached: cached)
                runs[index].finished = date
            } else {
                runs.append(
                    Run(
                        id: runs.count, task: task, model: model, started: date, finished: date,
                        state: .answered(cached: cached)))
            }
        }
    }

    /// The task's run still under way, or one whose model just failed and may be followed by the
    /// next in its chain.
    private func open(_ task: TaskID) -> Int? {
        runs.lastIndex { $0.task == task && ($0.finished == nil || isFailedOver($0)) }
    }

    private func lastFailed(_ task: TaskID) -> Int? {
        runs.lastIndex { $0.task == task && isFailedOver($0) }
    }

    private func isFailedOver(_ run: Run) -> Bool {
        if case .gaveUp = run.state { return true }
        return false
    }

    /// What's worth telling: each run another model finished, and each that none could.
    public var notes: [Note] {
        runs.compactMap { run in
            guard let last = run.failures.last else { return nil }
            let name = Self.name(run.task)
            switch run.state {
            case .answered:
                return Note(
                    kind: .fellBack, task: run.task,
                    text: "\(name): \(last.model.model) \(last.reason), so \(run.model.model) wrote it.")
            case .gaveUp(let reason):
                return Note(
                    kind: .gaveUp, task: run.task,
                    text: "\(name): \(Self.outcome(run.task)) \(last.model.model) \(reason).")
            case .asking, .retrying:
                return nil
            }
        }
    }

    /// Whether any run used another model, or none at all.
    public var hasFallbacks: Bool { notes.contains { $0.kind == .fellBack } }
    public var hasGivenUp: Bool { notes.contains { $0.kind == .gaveUp } }

    /// The step's name as the Build screen says it.
    public static func name(_ task: TaskID) -> String {
        switch task {
        case .writeExperience: "Experience"
        case .writeProjects: "Projects"
        case .writeSkills: "Skills"
        case .writeSummary: "Summary"
        case .rewriteSection: "Rewrite"
        case .shortenBullets: "Shortening"
        case .gapBullets: "Stretch bullets"
        case .coverLetter: "Cover letter"
        default: task.rawValue
        }
    }

    /// What a step does without a model.
    static func outcome(_ task: TaskID) -> String {
        switch task {
        case .writeExperience, .writeProjects: "uses your master resume's words because"
        case .writeSkills: "lists your skills ungrouped because"
        case .coverLetter: "was left out because"
        default: "was skipped because"
        }
    }
}
