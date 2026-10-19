import Synchronization

/// Answers from a script, per task id, in order, and records every request. Lets the router, rate
/// limiter, retries, repair, fallback, budget and cache be tested without a network (SPEC §5.5).
public final class FakeProvider: LLMProvider {
    public enum Reply: Sendable {
        case reply(String, inputTokens: Int? = nil, outputTokens: Int? = nil)
        case failure(LLMError)
    }

    public let name: String
    private let state: Mutex<(scripts: [TaskID: [Reply]], requests: [ChatRequest])>

    public init(_ scripts: [TaskID: [Reply]], name: String = "fake") {
        self.name = name
        state = Mutex((scripts, []))
    }

    /// Every request so far, oldest first.
    public var requests: [ChatRequest] {
        state.withLock { $0.requests }
    }

    public func complete(_ request: ChatRequest) async throws(LLMError) -> ChatResponse {
        let next: Reply? = state.withLock { state in
            state.requests.append(request)
            guard var queue = state.scripts[request.task], !queue.isEmpty else { return nil }
            let reply = queue.removeFirst()
            state.scripts[request.task] = queue
            return reply
        }
        switch next {
        case nil:
            // Running past the script is a test bug; fail loudly rather than invent a reply.
            throw .noScriptedReply(request.task)
        case .failure(let error)?:
            throw error
        case .reply(let text, let inputTokens, let outputTokens)?:
            return ChatResponse(text: text, model: request.model, inputTokens: inputTokens, outputTokens: outputTokens)
        }
    }
}
