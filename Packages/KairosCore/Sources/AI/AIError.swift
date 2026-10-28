import Foundation

public enum AIError: Error, Equatable, Sendable {
    /// 401 or 403. Never retried.
    case keyRejected(provider: String)
    /// 404. Never retried.
    case modelNotFound(String)
    /// 400. Never retried.
    case badRequest(String)
    case rateLimited(retryAfterSeconds: Int?)
    /// A 429 for the day: this key used up its requests to this model until the quota resets, and
    /// the provider may name the limit (Gemini's per-day quota).
    case quotaUsedUp(model: String, limit: Int?, retryAfterSeconds: Int?)
    /// A 429 whose quota limit is 0: the model isn't on this key's plan, so waiting won't help (T20).
    case modelNotOnPlan(String)
    /// The provider won't serve this model to this account now, in its own words: Ollama's 402
    /// ("add usage credits") and a 403 about the model ("not yet available to you").
    case modelUnavailable(model: String, reason: String)
    case server(status: Int)
    case network(String)
    case timedOut
    case cancelled
    /// The reply wasn't JSON at all.
    case invalidJSON(String)
    /// The reply broke the schema or the task's own check.
    case invalidOutput(String)
    /// Today's AI budget is spent.
    case budgetReached
    case noModel(TaskID)
    /// The provider needs a key and none is saved.
    case noKey(provider: String)

    /// A short code for the call log. Never carries prompt or reply text.
    public var code: String {
        switch self {
        case .keyRejected: "key_rejected"
        case .modelNotFound: "model_not_found"
        case .badRequest: "bad_request"
        case .rateLimited: "rate_limited"
        case .quotaUsedUp: "quota_used_up"
        case .modelNotOnPlan: "model_not_on_plan"
        case .modelUnavailable: "model_unavailable"
        case .server(let status): "server_\(status)"
        case .network: "network"
        case .timedOut: "timed_out"
        case .cancelled: "cancelled"
        case .invalidJSON: "invalid_json"
        case .invalidOutput: "invalid_output"
        case .budgetReached: "budget_reached"
        case .noModel: "no_model"
        case .noKey: "no_key"
        }
    }

    /// What went wrong, in a few plain words after a model's name: "was overloaded (503)".
    public var reason: String {
        switch self {
        case .keyRejected: "rejected the key"
        case .modelNotFound: "doesn't have this model"
        case .badRequest: "refused the request"
        case .rateLimited: "hit its rate limit"
        case .quotaUsedUp: "used up today's requests"
        case .modelNotOnPlan: "isn't on this key's plan"
        case .modelUnavailable(_, let reason): reason
        case .server(let status) where status == 503 || status == 529: "was overloaded (\(status))"
        case .server(let status): "had a server error (\(status))"
        case .network: "couldn't be reached"
        case .timedOut: "didn't answer in time"
        case .cancelled: "was stopped"
        case .invalidJSON: "didn't reply with JSON"
        case .invalidOutput: "replied in a form that failed its checks"
        case .budgetReached: "reached today's AI budget"
        case .noModel: "has no model set"
        case .noKey: "has no key saved"
        }
    }

    /// The reason for a logged code: the log keeps codes, never text.
    public static func reason(code: String) -> String {
        if code.hasPrefix("server_"), let status = Int(code.dropFirst(7)) {
            return AIError.server(status: status).reason
        }
        if code == "model_unavailable" { return "isn't available to this account" }
        let known: [AIError] = [
            .keyRejected(provider: ""), .modelNotFound(""), .badRequest(""), .rateLimited(retryAfterSeconds: nil),
            .quotaUsedUp(model: "", limit: nil, retryAfterSeconds: nil), .modelNotOnPlan(""), .network(""),
            .timedOut, .cancelled, .invalidJSON(""), .invalidOutput(""), .budgetReached, .noKey(provider: ""),
        ]
        return known.first { $0.code == code }?.reason ?? "failed (\(code))"
    }

    /// Ends a run however many models are left to try: you stopped it, or the budget ran out.
    public var stopsEverything: Bool { self == .cancelled || self == .budgetReached }

    /// Network trouble and server errors that may pass. 501 never does (T20).
    var isTemporary: Bool {
        switch self {
        case .network, .timedOut: true
        case .server(let status): status >= 500 && status != 501
        default: false
        }
    }
}
