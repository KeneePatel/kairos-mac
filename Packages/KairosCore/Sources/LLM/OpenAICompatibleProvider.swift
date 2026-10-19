import Foundation
import Synchronization

/// What each model has been found to accept, shared by every key of a provider so a refusal is
/// only paid for once (T20: capability is per model, not per preset).
public final class ModelCapabilities: Sendable {
    private let learned = Mutex<[String: StructuredOutput]>([:])

    public init() {}

    /// The best mode `model` may still accept, starting from `preset`'s.
    public func mode(for model: String, preset: StructuredOutput) -> StructuredOutput {
        learned.withLock { $0[model].map { max($0, preset) } ?? preset }
    }

    func remember(_ mode: StructuredOutput, for model: String) {
        learned.withLock { $0[model] = max($0[model] ?? mode, mode) }
    }
}

/// One provider that speaks OpenAI's `chat/completions`: Gemini, Ollama, Groq, OpenRouter, OpenAI.
/// It makes one call, plus at most two resends when a model refuses a structured-output mode.
/// Retries, rate limits, key rotation and repair belong to the client above it.
public struct OpenAICompatibleProvider: LLMProvider {
    public let preset: ProviderPreset
    private let key: String?
    private let transport: any LLMTransport
    private let capabilities: ModelCapabilities

    public var name: String { preset.name }

    public init(
        preset: ProviderPreset, key: String?, transport: any LLMTransport = URLSessionTransport(),
        capabilities: ModelCapabilities = ModelCapabilities()
    ) {
        self.preset = preset
        self.key = key
        self.transport = transport
        self.capabilities = capabilities
    }

    public func complete(_ request: ChatRequest) async throws(LLMError) -> ChatResponse {
        var mode =
            request.schema == nil ? .promptOnly : capabilities.mode(for: request.model, preset: preset.structuredOutput)
        while true {
            let (data, response) = try await transport.send(
                try urlRequest("chat/completions", body: body(request, mode: mode)))
            if response.statusCode == 200 { return try Self.parse(data, model: request.model) }
            let message = Self.errorMessage(in: data) ?? ""
            // A model that doesn't do this kind of structured output: drop a level, remember, resend.
            if let fallback = mode.fallback, Self.refusesStructuredOutput(status: response.statusCode, message: message)
            {
                capabilities.remember(fallback, for: request.model)
                mode = fallback
                continue
            }
            throw Self.error(
                status: response.statusCode, message: message, response: response, data: data, model: request.model,
                provider: preset.name)
        }
    }

    /// The provider's model ids (`GET /models`), sorted. Gemini prefixes ids with "models/".
    public func listModels() async throws(LLMError) -> [String] {
        let (data, response) = try await transport.send(try urlRequest("models", body: nil))
        guard response.statusCode == 200 else {
            throw Self.error(
                status: response.statusCode, message: Self.errorMessage(in: data) ?? "", response: response, data: data,
                model: "", provider: preset.name)
        }
        guard case .object(let fields) = try JSONValue(parsing: String(decoding: data, as: UTF8.self)),
            case .array(let list)? = fields["data"]
        else { throw .invalidJSON("model list") }
        return list.compactMap { item -> String? in
            guard case .object(let model) = item, case .string(let id)? = model["id"] else { return nil }
            return id.hasPrefix("models/") ? String(id.dropFirst(7)) : id
        }
        .sorted()
    }

    // MARK: - Requests

    private func urlRequest(_ path: String, body: Data?) throws(LLMError) -> URLRequest {
        guard let url = URL(string: preset.baseURL + path), url.scheme == "https" || preset.isLocal else {
            throw .badRequest("\(preset.name): base URL must be https (or a local address)")
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(preset.timeoutSeconds))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return request
    }

    func body(_ request: ChatRequest, mode: StructuredOutput) -> Data {
        var messages = request.messages
        if let schema = request.schema, mode != .schema {
            // Without schema mode the model only knows the shape from the prompt.
            let contract = "Reply with JSON only, no code fences, matching this JSON Schema:\n\(schema.jsonString)"
            if let index = messages.firstIndex(where: { $0.role == .system }) {
                messages[index] = .system(messages[index].content + "\n\n" + contract)
            } else {
                messages.insert(.system(contract), at: 0)
            }
        }
        var fields: [String] = [
            "\"model\":\(Self.quote(request.model))",
            "\"messages\":["
                + messages.map { "{\"role\":\"\($0.role.rawValue)\",\"content\":\(Self.quote($0.content))}" }
                .joined(separator: ",") + "]",
            "\"temperature\":\(JSONValue.format(request.temperature))",
            "\"\(preset.maxTokensField)\":\(request.maxOutputTokens)",
        ]
        switch (mode, request.schema) {
        case (.schema, let schema?):
            fields.append(
                #""response_format":{"type":"json_schema","json_schema":{"name":"\#(request.task.rawValue)","strict":true,"schema":\#(schema.jsonString)}}"#
            )
        case (.jsonMode, _?):
            fields.append(#""response_format":{"type":"json_object"}"#)
        default:
            break
        }
        if let effort = request.reasoningEffort, preset.acceptsReasoningEffort {
            fields.append("\"reasoning_effort\":\"\(effort.rawValue)\"")
        }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    // MARK: - Responses

    static func parse(_ data: Data, model: String) throws(LLMError) -> ChatResponse {
        guard case .object(let reply) = try JSONValue(parsing: String(decoding: data, as: UTF8.self)),
            case .array(let choices)? = reply["choices"], case .object(let choice)? = choices.first,
            case .object(let message)? = choice["message"]
        else { throw .invalidJSON("no choices in the reply") }
        guard case .string(let text)? = message["content"],
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw .invalidOutput("the model sent an empty reply") }
        var inputTokens: Int?
        var outputTokens: Int?
        if case .object(let usage)? = reply["usage"] {
            inputTokens = int(usage["prompt_tokens"])
            let completion = int(usage["completion_tokens"])
            // Gemini Flash's hidden thinking shows only in the total (T20).
            let hidden = int(usage["total_tokens"]).flatMap { total in inputTokens.map { total - $0 } }
            outputTokens = [completion, hidden].compactMap { $0 }.max()
        }
        var finishReason: String?
        if case .string(let reason)? = choice["finish_reason"] { finishReason = reason }
        var servedBy = model
        if case .string(let name)? = reply["model"] { servedBy = name }
        return ChatResponse(
            text: text, model: servedBy, inputTokens: inputTokens, outputTokens: outputTokens,
            finishReason: finishReason)
    }

    /// `{"error":{"message":…}}`, Gemini's `[{"error":{…}}]` (T20), or `{"error":"…"}`.
    static func errorMessage(in data: Data) -> String? {
        guard var value = try? JSONValue(parsing: String(decoding: data, as: UTF8.self)) else { return nil }
        if case .array(let items) = value, let first = items.first { value = first }
        guard case .object(let fields) = value else { return nil }
        switch fields["error"] {
        case .string(let message)?: return message
        case .object(let error)?:
            if case .string(let message)? = error["message"] { return message }
            return nil
        default: return nil
        }
    }

    static func refusesStructuredOutput(status: Int, message: String) -> Bool {
        let lower = message.lowercased()
        return (status == 501 && lower.contains("structured output"))
            || (status == 400
                && (lower.contains("response_format") || lower.contains("json_schema")
                    || lower.contains("structured output")))
    }

    static func error(
        status: Int, message: String, response: HTTPURLResponse, data: Data, model: String, provider: String
    ) -> LLMError {
        switch status {
        case 400: return .badRequest(message.isEmpty ? "the provider refused the request" : String(message.prefix(300)))
        case 401, 403: return .keyRejected(provider: provider)
        case 404: return .modelNotFound(model)
        case 429:
            // "limit: 0" means the plan has no quota for this model; waiting won't help (T20).
            if message.contains("limit: 0") { return .modelNotOnPlan(model) }
            return .rateLimited(retryAfterSeconds: retryAfter(response, data: data))
        default: return .server(status: status)
        }
    }

    /// `Retry-After` in seconds, else Gemini's `RetryInfo.retryDelay` ("51s").
    static func retryAfter(_ response: HTTPURLResponse, data: Data) -> Int? {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(header) { return seconds }
        let text = String(decoding: data, as: UTF8.self)
        guard let match = text.firstMatch(of: /"retryDelay"\s*:\s*"(\d+)(?:\.\d+)?s"/) else { return nil }
        return Int(match.1)
    }

    private static func int(_ value: JSONValue?) -> Int? {
        if case .number(let number)? = value { return Int(number) }
        return nil
    }

    private static func quote(_ text: String) -> String { JSONValue.string(text).jsonString }
}
