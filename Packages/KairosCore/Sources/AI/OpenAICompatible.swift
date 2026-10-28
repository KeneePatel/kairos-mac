import Foundation
import KairosKit

/// One model call, as the adapter sends it.
public struct ChatRequest: Sendable, Equatable {
    public let task: TaskID
    public let model: String
    public let messages: [ChatMessage]
    /// Sent where the provider takes a schema; otherwise JSON mode with the schema in the prompt.
    public let schema: JSONSchema?
    public let temperature: Double
    public let maxOutputTokens: Int
    public let reasoningEffort: ReasoningEffort?
    public let timeoutSeconds: Int

    public init(
        task: TaskID, model: String, messages: [ChatMessage], schema: JSONSchema?, temperature: Double,
        maxOutputTokens: Int, reasoningEffort: ReasoningEffort? = nil, timeoutSeconds: Int = 120
    ) {
        self.task = task
        self.model = model
        self.messages = messages
        self.schema = schema
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.reasoningEffort = reasoningEffort
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ChatResponse: Equatable, Sendable {
    public let text: String
    /// The model that answered, as the provider names it.
    public let model: String
    public let inputTokens: Int?
    /// Includes thinking the provider didn't show (T20: Gemini Flash counts it only in the total).
    public let outputTokens: Int?
    /// "length" when the reply hit the output limit and is probably cut off.
    public let finishReason: String?

    public init(
        text: String, model: String, inputTokens: Int? = nil, outputTokens: Int? = nil, finishReason: String? = nil
    ) {
        self.text = text
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.finishReason = finishReason
    }
}

/// Speaks OpenAI's `chat/completions` to one provider: Gemini, Ollama, Groq, OpenRouter, OpenAI or
/// a custom gateway. It makes one call, plus a resend for each structured-output mode a model
/// refuses. Keys, retries, limits and fallback belong to the router.
public struct OpenAICompatible: Sendable {
    public let preset: ProviderPreset
    let http: any HTTPClient

    public init(preset: ProviderPreset, http: any HTTPClient) {
        self.preset = preset
        self.http = http
    }

    /// The reply, and the mode that worked (lower than `mode` when the model refused it).
    public func complete(_ request: ChatRequest, key: String?, mode: StructuredOutput) async throws(AIError)
        -> (ChatResponse, StructuredOutput)
    {
        var mode = request.schema == nil ? StructuredOutput.promptOnly : mode
        while true {
            let timeout = preset.isLocal ? preset.timeoutSeconds : request.timeoutSeconds
            let response = try await send(
                "chat/completions", key: key, body: body(request, mode: mode), timeout: TimeInterval(timeout))
            if response.status == 200 { return (try Self.parse(response.body, model: request.model), mode) }
            let message = Self.errorMessage(in: response.body) ?? ""
            // A model that doesn't do this kind of structured output: drop a level and resend.
            if let fallback = mode.fallback, Self.refusesStructuredOutput(status: response.status, message: message) {
                mode = fallback
                continue
            }
            throw Self.error(response, message: message, model: request.model, provider: preset.name)
        }
    }

    /// The provider's model ids (`GET /models`), sorted. Gemini prefixes ids with "models/".
    public func listModels(key: String?) async throws(AIError) -> [String] {
        let response = try await send("models", key: key, body: nil, timeout: 30)
        guard response.status == 200 else {
            throw Self.error(
                response, message: Self.errorMessage(in: response.body) ?? "", model: "", provider: preset.name)
        }
        guard let list = (try? JSONValue(parsing: response.body))?["data"]?.arrayValue else {
            throw .invalidJSON("model list")
        }
        return list.compactMap { $0["id"]?.stringValue }.map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }
            .sorted()
    }

    /// Whether the key works, by one tiny chat on `model`, for a provider whose model list needs no
    /// key. A model this account can't use still proves the key: it got that far.
    public func checkKey(_ key: String, model: String) async throws(AIError) {
        let body = Data(
            #"{"model":\#(JSONValue.string(model).text),"messages":[{"role":"user","content":"Reply with: ok"}],"max_tokens":5}"#
                .utf8)
        let response = try await send("chat/completions", key: key, body: body, timeout: 30)
        guard response.status != 200 else { return }
        let error = Self.error(
            response, message: Self.errorMessage(in: response.body) ?? "", model: model, provider: preset.name)
        if case .modelUnavailable = error { return }
        throw error
    }

    /// What this key's account has left, where the provider reports it.
    public func balance(key: String) async throws(AIError) -> CreditBalance {
        guard let address = preset.balanceURL, let url = URL(string: address), url.scheme == "https" else {
            throw .badRequest("\(preset.name) doesn't report a balance")
        }
        let response: HTTPResponse
        do {
            response = try await http.send(
                HTTPRequest(url: url, headers: ["Authorization": "Bearer \(key)"], timeout: 20))
        } catch {
            throw Self.map(error)
        }
        guard response.status == 200 else {
            throw Self.error(
                response, message: Self.errorMessage(in: response.body) ?? "", model: "", provider: preset.name)
        }
        return try CreditBalance.parse(response.body)
    }

    // MARK: - Requests

    private func send(_ path: String, key: String?, body: Data?, timeout: TimeInterval) async throws(AIError)
        -> HTTPResponse
    {
        guard let url = URL(string: preset.baseURL + path), url.scheme == "https" || preset.isLocal else {
            throw .badRequest("\(preset.name): the address must be https, or on this Mac")
        }
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        if let key, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        do {
            return try await http.send(
                HTTPRequest(
                    url: url, method: body == nil ? .get : .post, headers: headers, body: body, timeout: timeout))
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: HTTPError) -> AIError {
        switch error {
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .offline: .network("offline")
        case .network(let detail): .network(detail)
        }
    }

    func body(_ request: ChatRequest, mode: StructuredOutput) -> Data {
        var messages = request.messages
        if let schema = request.schema, mode != .schema {
            // Without schema mode the model only knows the shape from the prompt.
            let contract = "Reply with JSON only, no code fences, matching this JSON Schema:\n\(schema.text)"
            if let index = messages.firstIndex(where: { $0.role == .system }) {
                messages[index] = .system(messages[index].content + "\n\n" + contract)
            } else {
                messages.insert(.system(contract), at: 0)
            }
        }
        func quote(_ text: String) -> String { JSONValue.string(text).text }
        var fields = [
            "\"model\":\(quote(request.model))",
            "\"messages\":["
                + messages.map { "{\"role\":\"\($0.role.rawValue)\",\"content\":\(quote($0.content))}" }
                .joined(separator: ",") + "]",
            "\"temperature\":\(JSONValue.number(request.temperature).text)",
            "\"\(preset.maxTokensField)\":\(request.maxOutputTokens)",
        ]
        switch (mode, request.schema) {
        case (.schema, let schema?):
            // Item counts stay out of strict schemas (Gemini refuses them); replies are still checked.
            fields.append(
                #""response_format":{"type":"json_schema","json_schema":{"name":"\#(request.task.rawValue)","strict":true,"schema":\#(schema.withoutItemCounts.text)}}"#
            )
        case (.jsonMode, _?):
            fields.append(#""response_format":{"type":"json_object"}"#)
        default:
            break
        }
        let effort = ReasoningEffort.fitting(request.reasoningEffort ?? preset.reasoningDefault, model: request.model)
        if let effort, preset.acceptsReasoningEffort {
            fields.append("\"reasoning_effort\":\"\(effort.rawValue)\"")
        }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    // MARK: - Replies

    static func parse(_ data: Data, model: String) throws(AIError) -> ChatResponse {
        guard let reply = try? JSONValue(parsing: data), let choice = reply["choices"]?.arrayValue?.first,
            let message = choice["message"]
        else { throw .invalidJSON("no choices in the reply") }
        guard let text = message["content"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .invalidOutput("the model sent an empty reply") }
        var inputTokens: Int?
        var outputTokens: Int?
        if let usage = reply["usage"] {
            inputTokens = usage["prompt_tokens"]?.numberValue.map { Int($0) }
            let completion = usage["completion_tokens"]?.numberValue.map { Int($0) }
            // Gemini Flash's hidden thinking shows only in the total (T20).
            let hidden = usage["total_tokens"]?.numberValue.flatMap { total in inputTokens.map { Int(total) - $0 } }
            outputTokens = [completion, hidden].compactMap { $0 }.max()
        }
        return ChatResponse(
            text: text, model: reply["model"]?.stringValue ?? model, inputTokens: inputTokens,
            outputTokens: outputTokens, finishReason: choice["finish_reason"]?.stringValue)
    }

    /// `{"error":{"message":…}}`, Gemini's `[{"error":{…}}]` (T20), or `{"error":"…"}`.
    static func errorMessage(in data: Data) -> String? {
        guard var value = try? JSONValue(parsing: data) else { return nil }
        if let first = value.arrayValue?.first { value = first }
        if let message = value["error"]?.stringValue { return message }
        return value["error"]?["message"]?.stringValue
    }

    static func refusesStructuredOutput(status: Int, message: String) -> Bool {
        let lower = message.lowercased()
        return (status == 501 && lower.contains("structured output"))
            || (status == 400
                && (lower.contains("response_format") || lower.contains("json_schema")
                    || lower.contains("structured output")))
    }

    static func error(_ response: HTTPResponse, message: String, model: String, provider: String) -> AIError {
        switch response.status {
        case 400: return .badRequest(message.isEmpty ? "the provider refused the request" : String(message.prefix(300)))
        case 402:
            return .modelUnavailable(
                model: model, reason: message.isEmpty ? "wants payment for this model" : providerWords(message))
        // Ollama answers 403 for a model still rolling out; a 403 about anything else is the key.
        case 403 where message.lowercased().contains("model"):
            return .modelUnavailable(model: model, reason: providerWords(message))
        case 401, 403: return .keyRejected(provider: provider)
        case 404: return .modelNotFound(model)
        case 429:
            // "limit: 0" means the plan has no quota for this model; waiting won't help (T20).
            if message.contains("limit: 0") { return .modelNotOnPlan(model) }
            if let daily = dailyQuota(in: response.body, message: message) {
                return .quotaUsedUp(model: model, limit: daily, retryAfterSeconds: retryAfter(response))
            }
            return .rateLimited(retryAfterSeconds: retryAfter(response))
        default: return .server(status: response.status)
        }
    }

    /// A provider's message as a reason: its first sentence without Ollama's "(ref: …)", at most 200
    /// characters: "said: this model is not included in your free usage".
    static func providerWords(_ message: String) -> String {
        var text = message.replacing(/\s*\(ref: [^)]*\)/, with: "")
        if let end = text.firstRange(of: /[.,:;]\s/)?.lowerBound { text = String(text[..<end]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard let first = text.first else { return "refused this model" }
        return "said: " + String(first).lowercased() + text.dropFirst().prefix(200)
    }

    /// Whether a 429 is for the day, from Gemini's `QuotaFailure`: a violation of a requests-per-day
    /// quota. Its limit is the violation's `quotaValue`, else the message's matching "Quota exceeded
    /// for metric: …, limit: N" line, which lists violations in the same order. Nil for a per-minute
    /// 429; nil inside when the limit isn't named.
    static func dailyQuota(in data: Data, message: String) -> Int?? {
        guard var value = try? JSONValue(parsing: data) else { return nil }
        if let first = value.arrayValue?.first { value = first }
        guard let details = value["error"]?["details"]?.arrayValue else { return nil }
        let violations = details.flatMap { $0["violations"]?.arrayValue ?? [] }
        guard
            let index = violations.firstIndex(where: { $0["quotaId"]?.stringValue?.contains("RequestsPerDay") == true })
        else { return nil }
        if let text = violations[index]["quotaValue"]?.stringValue, let limit = Int(text) { return limit }
        if let number = violations[index]["quotaValue"]?.numberValue { return Int(number) }
        let limits = message.matches(of: /Quota exceeded for metric: [^,\n]+, limit: (\d+)/).compactMap { Int($0.1) }
        return .some(limits.count == violations.count ? limits[index] : nil)
    }

    /// `Retry-After` in seconds, else Gemini's `RetryInfo.retryDelay` ("51s").
    static func retryAfter(_ response: HTTPResponse) -> Int? {
        if let seconds = response.retryAfterSeconds { return seconds }
        let text = String(decoding: response.body, as: UTF8.self)
        guard let match = text.firstMatch(of: /"retryDelay"\s*:\s*"(\d+)(?:\.\d+)?s"/) else { return nil }
        return Int(match.1)
    }
}
