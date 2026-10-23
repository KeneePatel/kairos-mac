import Foundation
import Store

/// One provider call through one key, as the client saw it: what the usage bars count. It names
/// the key as the key store does, never the key itself.
public struct KeyCall: Sendable, Equatable {
    public enum Outcome: String, Sendable {
        /// The provider answered, whatever the answer was worth: it counts against the quota.
        case answered
        /// It reached the provider and failed there (a server error, a timeout): counted too.
        case failed
        /// Refused for the rest of the day (`LLMError.quotaUsedUp`).
        case usedUp = "used_up"
    }

    public let key: String
    public let model: String
    public let outcome: Outcome
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// From a refusal for the day: the limit it named, and how long until the key is back.
    public let dailyLimit: Int?
    public let backInSeconds: Int?

    public init(
        key: String, model: String, outcome: Outcome, inputTokens: Int? = nil, outputTokens: Int? = nil,
        dailyLimit: Int? = nil, backInSeconds: Int? = nil
    ) {
        self.key = key
        self.model = model
        self.outcome = outcome
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.dailyLimit = dailyLimit
        self.backInSeconds = backInSeconds
    }

    /// What a call's result means for the key's quota; nil when it never reached the provider's
    /// count: a rate limit for the minute, a network error, a stop, or a key or model refused.
    init?(key: String, model: String, result: Result<ChatResponse, LLMError>) {
        switch result {
        case .success(let response):
            self.init(
                key: key, model: model, outcome: .answered, inputTokens: response.inputTokens,
                outputTokens: response.outputTokens)
        case .failure(.quotaUsedUp(_, let limit, let back)):
            self.init(key: key, model: model, outcome: .usedUp, dailyLimit: limit, backInSeconds: back)
        case .failure(.rateLimited), .failure(.network), .failure(.cancelled), .failure(.modelNotOnPlan),
            .failure(.keyRejected), .failure(.modelNotFound), .failure(.modelUnavailable):
            return nil
        case .failure:
            self.init(key: key, model: model, outcome: .failed)
        }
    }
}

/// What one key did with one model since its quota day began, and what the provider said.
public struct KeyModelUse: Sendable, Equatable {
    /// Calls that count against the quota: answered or failed at the provider.
    public var calls: Int
    /// The daily limit the provider last named for this key and model, on any day.
    public var limit: Int?
    /// Refused for the day since it began.
    public var refused: Bool
    /// When the refusal said it's back; nil when it didn't say (then: when the day ends).
    public var back: Date?

    public init(calls: Int = 0, limit: Int? = nil, refused: Bool = false, back: Date? = nil) {
        self.calls = calls
        self.limit = limit
        self.refused = refused
        self.back = back
    }
}

/// The local-only `llm_key_call` table: every provider call by key, for the usage bars.
public struct KeyCallLog: Sendable {
    let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public func record(_ call: KeyCall, provider: String, at date: Date) async throws {
        let back = call.backInSeconds.map { date.addingTimeInterval(TimeInterval($0)) }
        try await db.execute(
            """
            INSERT INTO llm_key_call (at, provider, key_name, model, outcome, input_tokens, output_tokens,
                daily_limit, back_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                SQLValue(date), .text(provider), .text(call.key), .text(call.model), .text(call.outcome.rawValue),
                SQLValue(call.inputTokens), SQLValue(call.outputTokens), SQLValue(call.dailyLimit), SQLValue(back),
            ])
    }

    /// What a client hands each call to: recorded at `now()`, and a lost row never fails the call.
    public func meter(provider: String, now: @escaping @Sendable () -> Date = { Date() }) -> KeyMeter {
        { call in try? await record(call, provider: provider, at: now()) }
    }

    /// Each key's use of each model at `provider` since `start` (its quota day), by key name, then
    /// model. The limit is the last one a refusal named, from any day still in the log.
    public func use(provider: String, since start: Date) async throws -> [String: [String: KeyModelUse]] {
        let rows = try await db.query(
            """
            SELECT key_name, model, outcome, at, daily_limit, back_at FROM llm_key_call
            WHERE provider = ? AND (at >= ? OR daily_limit IS NOT NULL) ORDER BY at, id
            """, [.text(provider), SQLValue(start)])
        var use: [String: [String: KeyModelUse]] = [:]
        for row in rows {
            guard let key = row.string("key_name"), let model = row.string("model"),
                let outcome = row.string("outcome").flatMap(KeyCall.Outcome.init(rawValue:)),
                let at = row.int64("at").map(Date.init(milliseconds:))
            else { continue }
            var entry = use[key]?[model] ?? KeyModelUse()
            if let limit = row.int("daily_limit") { entry.limit = limit }
            if at >= start {
                switch outcome {
                case .answered, .failed: entry.calls += 1
                case .usedUp:
                    entry.refused = true
                    entry.back = row.int64("back_at").map(Date.init(milliseconds:))
                }
            }
            use[key, default: [:]][model] = entry
        }
        return use
    }

    /// Rows older than `date` go, as `llm_call`'s do (SPEC §6.2: 30 days).
    @discardableResult
    public func deleteOlder(than date: Date) async throws -> Int {
        try await db.transaction { connection in
            try connection.execute("DELETE FROM llm_key_call WHERE at < ?", [SQLValue(date)])
            return connection.changes
        }
    }
}

/// Where a client reports each call through each key.
public typealias KeyMeter = @Sendable (KeyCall) async -> Void

/// One bar under a key in AI providers: how much of one limit is left (decided 2026-10-23).
public struct UsageBar: Sendable, Equatable, Identifiable {
    public var id: String { label }
    /// What it measures: a model id, "Credits", "This session".
    public let label: String
    /// How much is left, 0 to 1; nil when the limit isn't known, so there's no bar to draw.
    public let left: Double?
    /// "188 of about 500 left today", "Used up", "$3.20 of $5.00 left", "12 calls today".
    public let detail: String
    /// When it fills again, or when a used-up key is back.
    public let resets: Date?
    /// Nothing left until `resets`.
    public let usedUp: Bool

    public init(label: String, left: Double?, detail: String, resets: Date?, usedUp: Bool = false) {
        self.label = label
        self.left = left
        self.detail = detail
        self.resets = resets
        self.usedUp = usedUp
    }
}

extension ProviderPreset {
    /// The usual free requests a day for `model`, by its family, where the provider caps keys by the day.
    public func usualDailyRequests(for model: String) -> Int? {
        let name = model.lowercased()
        return dailyRequests.first { name.contains($0.family) }?.requests
    }

    /// The quota day `now` falls in: from midnight to midnight in the provider's time zone (Gemini's
    /// reset at midnight Pacific), else this Mac's.
    public func quotaDay(containing now: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = quotaDayZone.flatMap(TimeZone.init(identifier:)) ?? .current
        return calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86_400)
    }

    /// One bar per model a key uses: `models` first in their order (your chains), then any other
    /// model it called today. A model with no limit known shows its calls without a bar.
    public func dailyBars(models: [String], use: [String: KeyModelUse], now: Date) -> [UsageBar] {
        let day = quotaDay(containing: now)
        let others = use.keys.filter { !models.contains($0) && (use[$0]?.calls ?? 0) > 0 }.sorted()
        return (models + others).map { model in
            let entry = use[model] ?? KeyModelUse()
            let back = entry.back ?? day.end
            if entry.refused, back > now {
                return UsageBar(label: model, left: 0, detail: "Used up", resets: back, usedUp: true)
            }
            guard let limit = entry.limit ?? usualDailyRequests(for: model), limit > 0 else {
                return UsageBar(
                    label: model, left: nil, detail: "\(entry.calls) call\(entry.calls == 1 ? "" : "s") today",
                    resets: day.end)
            }
            let left = max(0, limit - entry.calls)
            return UsageBar(
                label: model, left: Double(left) / Double(limit),
                detail: "\(left) of \(entry.limit == nil ? "about " : "")\(limit) left today", resets: day.end,
                usedUp: left == 0)
        }
    }
}
