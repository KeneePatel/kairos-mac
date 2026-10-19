import Foundation
import Synchronization
import TestSupport
import Testing

@testable import LLM

/// Answers each request with the next scripted reply and records what was sent.
final class FakeTransport: LLMTransport {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body: Data
    }

    private let state: Mutex<(replies: [Reply], sent: [URLRequest])>

    init(_ replies: [Reply]) {
        state = Mutex((replies, []))
    }

    var sent: [URLRequest] { state.withLock { $0.sent } }

    func send(_ request: URLRequest) async throws(LLMError) -> (Data, HTTPURLResponse) {
        let reply: Reply? = state.withLock { state in
            state.sent.append(request)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply, let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else { throw .network("unscripted request") }
        return (reply.body, response)
    }
}

private func fixture(_ name: String) throws -> Data { try ScriptedURLProtocol.fixture("llm/\(name)") }

private func reply(_ status: Int, _ json: String, headers: [String: String] = [:]) -> FakeTransport.Reply {
    FakeTransport.Reply(status: status, headers: headers, body: Data(json.utf8))
}

private let schema = JSONSchema.object([.required("echo", .string(maxLength: 20))])

private func request(
    model: String = "gemini-flash-lite-latest", schema: JSONSchema? = schema, effort: ReasoningEffort? = nil
) -> ChatRequest {
    ChatRequest(
        task: .analyzeJob, model: model, messages: [.system("Extract."), .user("<job_posting>x</job_posting>")],
        schema: schema, temperature: 0, maxOutputTokens: 1_500, reasoningEffort: effort)
}

private func sentBody(_ request: URLRequest) throws -> [String: JSONValue] {
    guard case .object(let fields) = try JSONValue(parsing: String(decoding: request.httpBody ?? Data(), as: UTF8.self))
    else {
        throw LLMError.invalidJSON("body")
    }
    return fields
}

@Suite("Provider presets")
struct ProviderPresetTests {
    @Test func everyPresetHasAUsableBaseURL() throws {
        #expect(
            ProviderPreset.all.map(\.id) == ["gemini", "ollama-local", "ollama-cloud", "groq", "openrouter", "openai"])
        for preset in ProviderPreset.all {
            let url = try #require(URL(string: preset.baseURL + "chat/completions"), "\(preset.id)")
            #expect(preset.baseURL.hasSuffix("/"))
            #expect(url.scheme == (preset.isLocal ? "http" : "https"), "\(preset.id)")
            #expect(preset.needsKey == !preset.isLocal)
        }
    }

    @Test func geminiStartsInSchemaModeWithGooglesAliases() {
        #expect(ProviderPreset.gemini.structuredOutput == .schema)
        #expect(
            ProviderPreset.gemini.defaultModels == [
                .flash: "gemini-flash-latest", .flashLite: "gemini-flash-lite-latest",
            ])
        #expect(ProviderPreset.ollamaLocal.structuredOutput == .jsonMode)
        #expect(ProviderPreset.ollamaLocal.timeoutSeconds > ProviderPreset.gemini.timeoutSeconds)
    }

    @Test func aCustomProviderOnThisMacCountsAsLocal() throws {
        let local = ProviderPreset.custom(
            name: "LM Studio", baseURL: try #require(URL(string: "http://localhost:1234/v1")), needsKey: false)
        #expect(local.isLocal && local.baseURL == "http://localhost:1234/v1/" && local.timeoutSeconds == 180)
        let remote = ProviderPreset.custom(
            name: "Gateway", baseURL: try #require(URL(string: "https://llm.example/v1/")), needsKey: true)
        #expect(!remote.isLocal)
    }

    @Test func onlyChatModelsAreOfferedAliasesFirst() throws {
        let ids = try JSONDecoder().decode([String].self, from: ScriptedURLProtocol.fixture("llm/gemini-models.json"))
        let chat = ProviderPreset.gemini.chatModels(from: ids)
        #expect(Array(chat.prefix(2)) == ["gemini-flash-latest", "gemini-flash-lite-latest"])
        #expect(chat.contains("gemini-3.5-flash") && chat.contains("gemini-2.5-flash-lite"))
        #expect(!chat.contains { $0.contains("tts") || $0.contains("image") || $0.contains("embedding") })
        #expect(!chat.contains { $0.hasPrefix("antigravity") || $0.hasPrefix("deep-research") })  // agent products
        let firstPreview = try #require(chat.firstIndex { $0.contains("preview") })
        #expect(chat[firstPreview...].allSatisfy { $0.contains("preview") })  // previews come last
        #expect(ProviderPreset.ollamaLocal.chatModels(from: ["qwen3.5:4B", "nomic-embed-text"]) == ["qwen3.5:4B"])
    }

    @Test func modesFallBackInOrder() {
        #expect(StructuredOutput.schema.fallback == .jsonMode)
        #expect(StructuredOutput.jsonMode.fallback == .promptOnly)
        #expect(StructuredOutput.promptOnly.fallback == nil)
        #expect(StructuredOutput.schema < .jsonMode && StructuredOutput.jsonMode < .promptOnly)
    }
}

@Suite("OpenAI-compatible provider")
struct OpenAICompatibleProviderTests {
    @Test func sendsASchemaModeRequest() async throws {
        let transport = FakeTransport([.init(body: try fixture("gemini-schema-gemini-flash-lite-latest.json"))])
        let provider = OpenAICompatibleProvider(preset: .gemini, key: "test-key", transport: transport)
        _ = try await provider.complete(request(effort: .low))

        let sent = try #require(transport.sent.first)
        #expect(sent.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(sent.timeoutInterval == 120)
        let body = try sentBody(sent)
        #expect(body["model"] == .string("gemini-flash-lite-latest"))
        #expect(body["temperature"] == .number(0) && body["max_tokens"] == .number(1_500))
        #expect(body["reasoning_effort"] == .string("low"))
        guard case .object(let format)? = body["response_format"], case .object(let jsonSchema)? = format["json_schema"]
        else {
            Issue.record("no json_schema response_format")
            return
        }
        #expect(format["type"] == .string("json_schema"))
        #expect(jsonSchema["strict"] == .bool(true) && jsonSchema["name"] == .string("analyzeJob"))
        #expect(jsonSchema["schema"] == (try JSONValue(parsing: schema.jsonString)))
        guard case .array(let messages)? = body["messages"] else { return }
        #expect(messages.count == 2)  // schema mode leaves the prompt alone
    }

    @Test func jsonAndPromptModesPutTheSchemaInTheSystemMessage() async throws {
        let ok = try fixture("gemini-json-gemini-flash-latest.json")
        let transport = FakeTransport([.init(body: ok), .init(body: ok)])
        let local = OpenAICompatibleProvider(preset: .ollamaLocal, key: nil, transport: transport)
        _ = try await local.complete(
            request(model: "llama", effort: ProviderPreset.ollamaLocal.isLocal ? ReasoningEffort.none : nil))
        let groq = OpenAICompatibleProvider(preset: .groq, key: "k", transport: transport)
        _ = try await groq.complete(request(model: "x", schema: nil, effort: .high))

        let jsonMode = try sentBody(transport.sent[0])
        #expect(transport.sent[0].value(forHTTPHeaderField: "Authorization") == nil)  // local, no key
        #expect(transport.sent[0].timeoutInterval == 180)
        guard case .object(let format)? = jsonMode["response_format"],
            case .array(let messages)? = jsonMode["messages"],
            case .object(let system)? = messages.first, case .string(let content)? = system["content"]
        else {
            Issue.record("unexpected JSON-mode body")
            return
        }
        #expect(format == ["type": .string("json_object")])
        #expect(content.hasPrefix("Extract.\n\nReply with JSON only") && content.contains(schema.jsonString))
        #expect(jsonMode["reasoning_effort"] == .string("none"))

        let noSchema = try sentBody(transport.sent[1])
        #expect(noSchema["response_format"] == nil)  // a task without a schema asks for none
        #expect(noSchema["reasoning_effort"] == nil)  // Groq's preset doesn't take it
    }

    /// Gemini answers a strict schema whose lists carry item counts with a bare "Request contains an
    /// invalid argument" (`importResume`, 2026-10-19). The counts are checked on the reply instead.
    @Test func strictSchemasLeaveItemCountsToLocalChecks() async throws {
        let lists = JSONSchema.object([.required("bullets", .array(of: .string(maxLength: 600), maxItems: 40))])
        let ok = try fixture("gemini-json-gemini-flash-latest.json")
        let transport = FakeTransport([.init(body: ok), .init(body: ok)])
        _ = try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport)
            .complete(request(schema: lists))
        _ = try await OpenAICompatibleProvider(preset: .ollamaLocal, key: nil, transport: transport)
            .complete(request(model: "llama", schema: lists))

        let strict = try sentBody(transport.sent[0])
        let prompted = try sentBody(transport.sent[1])
        guard case .object(let format)? = strict["response_format"],
            case .object(let jsonSchema)? = format["json_schema"],
            case .array(let messages)? = prompted["messages"], case .object(let system)? = messages.first,
            case .string(let content)? = system["content"]
        else {
            Issue.record("unexpected request bodies")
            return
        }
        let expected = try JSONValue(
            parsing: #"{"type":"object","additionalProperties":false,"required":["bullets"],"#
                + #""properties":{"bullets":{"type":"array","items":{"type":"string","maxLength":600}}}}"#)
        #expect(jsonSchema["schema"] == expected)
        #expect(content.contains(#""maxItems":40"#))  // a prompt still tells the model the limit
    }

    @Test func cloudCallsUseTheTasksTimeoutAndLocalOnesTheirOwn() async throws {
        let ok = try fixture("gemini-json-gemini-flash-latest.json")
        let transport = FakeTransport([.init(body: ok), .init(body: ok)])
        let timed = ChatRequest(
            task: .analyzeJob, model: "m", messages: [.user("x")], schema: nil, temperature: 0, maxOutputTokens: 10,
            timeoutSeconds: 60)
        _ = try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport).complete(timed)
        _ = try await OpenAICompatibleProvider(preset: .ollamaLocal, key: nil, transport: transport).complete(timed)
        #expect(transport.sent.map(\.timeoutInterval) == [60, 180])
    }

    @Test func openAIUsesItsOwnTokenField() async throws {
        let transport = FakeTransport([.init(body: try fixture("gemini-json-gemini-flash-latest.json"))])
        _ = try await OpenAICompatibleProvider(preset: .openAI, key: "k", transport: transport).complete(request())
        let body = try sentBody(try #require(transport.sent.first))
        #expect(body["max_completion_tokens"] == .number(1_500) && body["max_tokens"] == nil)
    }

    @Test func parsesARecordedGeminiReply() async throws {
        let transport = FakeTransport([.init(body: try fixture("gemini-schema-gemini-flash-lite-latest.json"))])
        let response = try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport).complete(
            request())
        #expect(response.text.hasPrefix(#"{"requirements":[{"text":"3+ years building services in Go or Java""#))
        #expect(response.model == "gemini-flash-lite-latest")
        #expect(response.inputTokens == 145 && response.outputTokens == 100)
        #expect(response.finishReason == "stop")
    }

    @Test func countsGeminiFlashsHiddenThinkingAsOutput() async throws {
        let transport = FakeTransport([.init(body: try fixture("gemini-json-gemini-flash-latest.json"))])
        let response = try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport).complete(
            request())
        #expect(response.inputTokens == 145)
        #expect(response.outputTokens == 600)  // 96 shown + 504 hidden (T20)
    }

    @Test func aModelThatRefusesStructuredOutputDropsToPromptOnlyOnce() async throws {
        let refusal = try fixture("ollama-schema-qwen3.5_4B.json")
        let answer = try fixture("ollama-plain-no-thinking-qwen3.5_4B.json")
        let transport = FakeTransport([
            .init(status: 501, body: refusal), .init(body: answer), .init(body: answer),
        ])
        let capabilities = ModelCapabilities()
        let provider = OpenAICompatibleProvider(
            preset: .ollamaLocal, key: nil, transport: transport, capabilities: capabilities)

        let first = try await provider.complete(request(model: "qwen3.5:4B"))
        #expect(first.text.contains("requirements"))
        #expect(capabilities.mode(for: "qwen3.5:4B", preset: .jsonMode) == .promptOnly)
        _ = try await provider.complete(request(model: "qwen3.5:4B"))

        let formats = try transport.sent.map { try sentBody($0)["response_format"] != nil }
        #expect(formats == [true, false, false])  // the refusal is paid for once
        #expect(capabilities.mode(for: "another-model", preset: .jsonMode) == .jsonMode)
    }

    @Test func aRefusalLearnedWithOneKeyIsSharedWithTheOthers() async throws {
        let capabilities = ModelCapabilities()
        let ok = try fixture("gemini-json-gemini-flash-latest.json")
        let refusal = reply(400, #"{"error":{"message":"response_format json_schema is not supported by this model"}}"#)
        let transport = FakeTransport([refusal, .init(body: ok), .init(body: ok)])
        let first = OpenAICompatibleProvider(
            preset: .groq, key: "key-1", transport: transport, capabilities: capabilities)
        let second = OpenAICompatibleProvider(
            preset: .groq, key: "key-2", transport: transport, capabilities: capabilities)
        _ = try await first.complete(request(model: "m"))
        _ = try await second.complete(request(model: "m"))
        let types = try transport.sent.map { body -> JSONValue? in
            guard case .object(let format)? = try sentBody(body)["response_format"] else { return nil }
            return format["type"]
        }
        #expect(types == [.string("json_schema"), .string("json_object"), .string("json_object")])
    }

    @Test(arguments: [
        (
            400, #"{"error":{"message":"temperature must be at most 2"}}"#,
            LLMError.badRequest("temperature must be at most 2")
        ),
        (401, #"{"error":{"message":"bad key"}}"#, .keyRejected(provider: "Google Gemini")),
        (403, #"[{"error":{"code":403,"message":"API key not valid"}}]"#, .keyRejected(provider: "Google Gemini")),
        (404, #"{"error":"model not found"}"#, .modelNotFound("gemini-flash-lite-latest")),
        (500, "", .server(status: 500)),
        // A 501 that isn't about structured output stays a server error.
        (501, #"{"error":{"message":"not implemented"}}"#, .server(status: 501)),
    ])
    func mapsStatusesToTypedErrors(status: Int, body: String, expected: LLMError) async {
        let transport = FakeTransport([reply(status, body)])
        await #expect(throws: expected) {
            try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport).complete(request())
        }
    }

    @Test func aBusyGeminiModelIsAServerError() async throws {
        let transport = FakeTransport([.init(status: 503, body: try fixture("gemini-error-503-high-demand.json"))])
        await #expect(throws: LLMError.server(status: 503)) {
            try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport).complete(request())
        }
    }

    @Test func aZeroQuotaIsNotARateLimitToWaitOut() async throws {
        let transport = FakeTransport([.init(status: 429, body: try fixture("gemini-error-429-free-tier-limit-0.json"))]
        )
        await #expect(throws: LLMError.modelNotOnPlan("gemini-omni-1.1-flash")) {
            try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport)
                .complete(request(model: "gemini-omni-1.1-flash"))
        }
    }

    @Test func rateLimitsCarryTheirRetryDelay() async throws {
        let headerDelay = FakeTransport([
            reply(429, #"{"error":{"message":"slow down"}}"#, headers: ["Retry-After": "30"])
        ])
        await #expect(throws: LLMError.rateLimited(retryAfterSeconds: 30)) {
            try await OpenAICompatibleProvider(preset: .groq, key: "k", transport: headerDelay).complete(request())
        }
        let geminiDelay = FakeTransport([
            reply(
                429,
                #"[{"error":{"code":429,"message":"Quota exceeded, limit: 15","details":[{"retryDelay":"41.5s"}]}}]"#)
        ])
        await #expect(throws: LLMError.rateLimited(retryAfterSeconds: 41)) {
            try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: geminiDelay).complete(request())
        }
        let none = FakeTransport([reply(429, "")])
        await #expect(throws: LLMError.rateLimited(retryAfterSeconds: nil)) {
            try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: none).complete(request())
        }
    }

    @Test func aCutOffReplySaysSo() async throws {
        let body =
            #"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"{\"requirements\":["}}],"model":"m"}"#
        let response = try await OpenAICompatibleProvider(
            preset: .gemini, key: "k", transport: FakeTransport([reply(200, body)])
        )
        .complete(request())
        #expect(response.finishReason == "length")
        #expect(response.inputTokens == nil && response.outputTokens == nil)
    }

    @Test(arguments: [
        (
            #"{"choices":[{"message":{"role":"assistant","content":"  "}}]}"#,
            LLMError.invalidOutput("the model sent an empty reply")
        ),
        (
            #"{"choices":[{"message":{"role":"assistant","content":null}}]}"#,
            .invalidOutput("the model sent an empty reply")
        ),
        (#"{"choices":[]}"#, .invalidJSON("no choices in the reply")),
        ("<html>", .invalidJSON("<html>")),
    ])
    func unusableRepliesAreErrors(body: String, expected: LLMError) async {
        await #expect(throws: expected) {
            try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: FakeTransport([reply(200, body)]))
                .complete(request())
        }
    }

    @Test func listsModelsWithoutGooglesPrefix() async throws {
        let body =
            #"{"object":"list","data":[{"id":"models/gemini-flash-latest"},{"id":"models/gemini-2.5-flash"},{"id":"llama3"}]}"#
        let transport = FakeTransport([reply(200, body)])
        let models = try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport).listModels()
        #expect(models == ["gemini-2.5-flash", "gemini-flash-latest", "llama3"])
        #expect(transport.sent.first?.httpMethod == "GET")
        #expect(
            transport.sent.first?.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/openai/models")
    }

    @Test func aRejectedKeyFailsTheModelList() async {
        await #expect(throws: LLMError.keyRejected(provider: "Google Gemini")) {
            try await OpenAICompatibleProvider(preset: .gemini, key: "k", transport: FakeTransport([reply(401, "")]))
                .listModels()
        }
    }

    @Test func aCustomBaseURLMustBeHTTPSUnlessLocal() async throws {
        let plain = ProviderPreset.custom(
            name: "Gateway", baseURL: try #require(URL(string: "http://llm.example/v1/")), needsKey: true)
        let transport = FakeTransport([])
        await #expect(throws: LLMError.self) {
            try await OpenAICompatibleProvider(preset: plain, key: "k", transport: transport).complete(request())
        }
        #expect(transport.sent.isEmpty)  // the key never went out over plain http
    }
}

@Suite("URLSession transport")
struct URLSessionTransportTests {
    @Test(arguments: [
        (URLError.Code.timedOut, LLMError.timedOut),
        (.cancelled, .cancelled),
        (.cannotConnectToHost, .network("can't reach localhost")),
        (.notConnectedToInternet, .network("offline")),
        (.badServerResponse, .network("localhost: URL error -1011")),
    ])
    func mapsTransportFailures(code: URLError.Code, expected: LLMError) async throws {
        let url = "http://localhost:11434/v1/models"
        let (configuration, _) = ScriptedURLProtocol.configuration([url: .failure(code)])
        let transport = URLSessionTransport(configuration: configuration)
        await #expect(throws: expected) { try await transport.send(URLRequest(url: try #require(URL(string: url)))) }
    }

    @Test func passesAnyStatusThrough() async throws {
        let url = "https://api.example.com/v1/models"
        let (configuration, script) = ScriptedURLProtocol.configuration([
            url: .http(status: 418, body: Data("teapot".utf8))
        ])
        let (data, response) = try await URLSessionTransport(configuration: configuration).send(
            URLRequest(url: try #require(URL(string: url))))
        #expect(response.statusCode == 418 && String(decoding: data, as: UTF8.self) == "teapot")
        #expect(script.requests.count == 1)
    }
}
