import Foundation
import KairosKit

/// One provider call, as the call log keeps it: counts and codes, never prompt or reply text, and a
/// key's name, never the key.
public struct AICall: Sendable, Equatable {
    public enum Outcome: String, Sendable, Codable, CaseIterable {
        /// It answered and the reply passed its checks.
        case ok
        /// It answered with a reply that failed its checks.
        case invalid
        /// It failed: a server error, a timeout, a refused key.
        case failed
        /// A rate limit for the minute: it never reached the quota.
        case rateLimited = "rate_limited"
        /// Refused for the rest of the quota day.
        case usedUp = "used_up"
        /// Served from the cache: no call was made.
        case cached
    }

    public var at: Date
    public var task: TaskID
    public var provider: String
    public var keyName: String?
    public var model: String
    public var promptVersion: Int
    public var outcome: Outcome
    public var errorCode: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var milliseconds: Int
    /// A later model in the task's chain: an earlier one failed.
    public var fellBack: Bool
    public var jobID: String?
    public var buildID: String?
    /// From a refusal for the day: the limit it named, and when it said the key is back.
    public var dailyLimit: Int?
    public var backAt: Date?

    public init(
        at: Date, task: TaskID, provider: String, keyName: String? = nil, model: String, promptVersion: Int,
        outcome: Outcome, errorCode: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
        milliseconds: Int = 0, fellBack: Bool = false, jobID: String? = nil, buildID: String? = nil,
        dailyLimit: Int? = nil, backAt: Date? = nil
    ) {
        self.at = at
        self.task = task
        self.provider = provider
        self.keyName = keyName
        self.model = model
        self.promptVersion = promptVersion
        self.outcome = outcome
        self.errorCode = errorCode
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.milliseconds = milliseconds
        self.fellBack = fellBack
        self.jobID = jobID
        self.buildID = buildID
        self.dailyLimit = dailyLimit
        self.backAt = backAt
    }

    /// Whether the provider counted it against a key's quota.
    public var reachedProvider: Bool { [.ok, .invalid, .failed, .usedUp].contains(outcome) }
}

/// Where the router writes its calls and reads today's use. The store implements it; losing a row
/// never fails a task.
public protocol AICallLog: Sendable {
    func record(_ call: AICall) async
    /// Calls that reached a provider since `start`, and their tokens: what the daily budget counts.
    func usage(since start: Date) async -> (calls: Int, tokens: Int)
}

/// Validated task outputs, so a step isn't paid for twice: keyed by task, rendered input, prompt
/// version and model.
public protocol AIResultCache: Sendable {
    func output(task: TaskID, inputHash: String, promptVersion: Int, model: String) async -> String?
    func store(_ json: String, task: TaskID, inputHash: String, promptVersion: Int, model: String) async
}

/// One key's use of one model since its quota day began.
public struct KeyModelUse: Sendable, Equatable {
    public var calls: Int
    /// The daily limit the provider last named for this key and model, on any day.
    public var limit: Int?
    public var refused: Bool
    public var back: Date?

    public init(calls: Int = 0, limit: Int? = nil, refused: Bool = false, back: Date? = nil) {
        self.calls = calls
        self.limit = limit
        self.refused = refused
        self.back = back
    }
}

/// One bar under a key in Settings: how much of something is left.
public struct UsageBar: Sendable, Equatable, Identifiable {
    public var id: String { label }
    public let label: String
    /// 0…1 left; nil when only an amount is known.
    public let left: Double?
    public let detail: String
    public let resets: Date?
    public let usedUp: Bool

    public init(label: String, left: Double?, detail: String, resets: Date? = nil, usedUp: Bool = false) {
        self.label = label
        self.left = left
        self.detail = detail
        self.resets = resets
        self.usedUp = usedUp
    }

    /// A key's bar for one model on a provider that caps requests a day: the limit a refusal named,
    /// else the usual one marked "about".
    public static func daily(model: String, use: KeyModelUse, preset: ProviderPreset, dayEnds: Date, now: Date)
        -> UsageBar?
    {
        let named = use.limit
        guard let limit = named ?? preset.dailyLimit(for: model), limit > 0 else { return nil }
        let back = use.back ?? dayEnds
        if use.refused, back > now {
            return UsageBar(
                label: model, left: 0, detail: "Used up, back at \(back.formatted(date: .omitted, time: .shortened))",
                resets: back, usedUp: true)
        }
        let left = max(0, limit - use.calls)
        let about = named == nil ? "about " : ""
        return UsageBar(
            label: model, left: Double(left) / Double(limit), detail: "\(about)\(left) of \(limit) left today",
            resets: dayEnds, usedUp: left == 0)
    }
}

/// When a provider's quota day began and ends (midnight Pacific for Gemini).
public enum QuotaDay {
    public static func bounds(at now: Date, zone identifier: String?) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = identifier.flatMap(TimeZone.init(identifier:)) ?? .current
        let start = calendar.startOfDay(for: now)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }
}

/// What a key's account has left, as Ollama reports it (`GET https://ollama.com/api/balance`,
/// 2026-10-23): credits included for the plan's month and any bought. Older plans report a session
/// and a weekly allowance as percentages instead.
public struct CreditBalance: Sendable, Equatable {
    public struct Window: Sendable, Equatable {
        public let remainingPercent: Double
        public let resets: Date?
    }

    /// In US dollars.
    public var included: Double?
    public var allowance: Double?
    public var periodEnd: Date?
    public var purchased: Double?
    public var session: Window?
    public var weekly: Window?

    public init(
        included: Double? = nil, allowance: Double? = nil, periodEnd: Date? = nil, purchased: Double? = nil,
        session: Window? = nil, weekly: Window? = nil
    ) {
        self.included = included
        self.allowance = allowance
        self.periodEnd = periodEnd
        self.purchased = purchased
        self.session = session
        self.weekly = weekly
    }

    public static func parse(_ data: Data) throws(AIError) -> CreditBalance {
        guard let reply = try? JSONValue(parsing: data) else { throw .invalidJSON("balance") }
        var balance = CreditBalance()
        if let included = reply["included"] {
            balance.included = included["balance_usd"]?.numberValue
            balance.allowance = included["allowance_usd"]?.numberValue
            balance.periodEnd = included["period"]?["until"]?.stringValue.flatMap(ISODate.parse)
            balance.session = window(included["session"])
            balance.weekly = window(included["weekly"])
        }
        balance.purchased = reply["purchased"]?["balance_usd"]?.numberValue
        guard balance != CreditBalance() else { throw .invalidJSON("balance has no amounts") }
        return balance
    }

    private static func window(_ value: JSONValue?) -> Window? {
        guard let percent = value?["remaining_percent"]?.numberValue else { return nil }
        return Window(remainingPercent: percent, resets: value?["resets_at"]?.stringValue.flatMap(ISODate.parse))
    }

    /// One bar for the included credits, or one each for an older plan's session and week.
    public var bars: [UsageBar] {
        var bars: [UsageBar] = []
        let bought = purchased ?? 0
        if let allowance, allowance > 0 {
            let left = max(0, included ?? 0)
            bars.append(
                UsageBar(
                    label: "Credits", left: min(1, left / allowance),
                    detail: "\(Self.dollars(left)) of \(Self.dollars(allowance)) left"
                        + (bought > 0 ? ", plus \(Self.dollars(bought)) bought" : ""),
                    resets: periodEnd, usedUp: left <= 0 && bought <= 0))
        } else if included != nil || purchased != nil {
            let left = max(0, included ?? 0) + bought
            bars.append(
                UsageBar(
                    label: "Credits", left: nil,
                    detail: left > 0 ? "\(Self.dollars(left)) left" : "No credits: only free models",
                    resets: periodEnd))
        }
        for (label, window) in [("This session", session), ("This week", weekly)] {
            guard let window else { continue }
            let percent = min(100, max(0, window.remainingPercent))
            bars.append(
                UsageBar(
                    label: label, left: percent / 100, detail: "\(Int(percent.rounded()))% left", resets: window.resets,
                    usedUp: percent <= 0))
        }
        return bars
    }

    /// "$3.20" whatever this Mac's region: Ollama bills in US dollars.
    static func dollars(_ value: Double) -> String { String(format: "$%.2f", value) }
}

/// What Kairos knows about Ollama Cloud models for resume work: price per million tokens
/// (ollama.com/pricing, 2026-10-23), whether the Free plan has it, and how it did in Kairos's eval.
public struct ModelGuide: Sendable, Equatable {
    public enum Advice: String, Sendable, CaseIterable {
        case recommended, fallback, untried, skip
    }

    public let model: String
    public let inputPrice: Double
    public let outputPrice: Double
    public let free: Bool
    public let advice: Advice
    public let note: String

    /// A build's tokens, roughly: 20,000 in and 6,000 out across its calls (2026-10-23).
    public static let tokensPerBuild = (input: 20_000.0, output: 6_000.0)
    /// What the Free plan includes each month, per account; every model spends it.
    public static let freePlanCredits = 2.50

    public var costPerBuild: Double {
        (Self.tokensPerBuild.input * inputPrice + Self.tokensPerBuild.output * outputPrice) / 1_000_000
    }

    public var costLine: String {
        if free {
            let resumes = costPerBuild > 0 ? Int(Self.freePlanCredits / costPerBuild) / 10 * 10 : 0
            return resumes > 0 ? "on the Free plan, about \(resumes) resumes a month" : "on the Free plan"
        }
        return "about \(max(1, Int((costPerBuild * 100).rounded())))¢ a resume, needs credits"
    }

    public static func entry(for model: String) -> ModelGuide? {
        let name = model.lowercased().replacing("-cloud", with: "").replacing(":cloud", with: "")
        return ollamaCloud.first { name == $0.model } ?? ollamaCloud.first { name.hasPrefix($0.model + ":") }
    }

    public static let ollamaCloud: [ModelGuide] = [
        ModelGuide(
            model: "gemma4:31b", inputPrice: 0.14, outputPrice: 0.40, free: true, advice: .recommended,
            note: "The best free writer: every call passed its checks, and all five letters were written."),
        ModelGuide(
            model: "gpt-oss:120b", inputPrice: 0.15, outputPrice: 0.60, free: true, advice: .fallback,
            note: "Free and fast, but 4 of 30 calls failed their checks."),
        ModelGuide(
            model: "nemotron-3-super", inputPrice: 0.015, outputPrice: 0.60, free: true, advice: .untried,
            note: "Free; answered well in a quick test."),
        ModelGuide(
            model: "deepseek-v4.1-flash", inputPrice: 0.30, outputPrice: 1.20, free: false, advice: .untried,
            note: "The value pick with credits."),
        ModelGuide(
            model: "gpt-oss:20b", inputPrice: 0.07, outputPrice: 0.30, free: true, advice: .skip,
            note: "Too small: it spent its whole reply thinking."),
        ModelGuide(
            model: "kimi-k3", inputPrice: 3.00, outputPrice: 15.00, free: false, advice: .skip,
            note: "Far more than resume bullets need."),
    ]
}
