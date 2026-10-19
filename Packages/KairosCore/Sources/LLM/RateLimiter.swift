import Foundation

/// Time for the LLM layer. Production sleeps for real; tests use a clock where sleeping just moves
/// time on, so every wait is checked without waiting (SPEC §5.5, Testing).
public protocol LLMClock: Sendable {
    /// Time since some fixed start.
    var now: Duration { get }
    /// Throws `.cancelled` if the calling task is cancelled.
    func sleep(for duration: Duration) async throws(LLMError)
}

public struct SystemClock: LLMClock {
    private let start = ContinuousClock.now

    public init() {}

    public var now: Duration { ContinuousClock.now - start }

    public func sleep(for duration: Duration) async throws(LLMError) {
        do {
            try await Task.sleep(for: duration)
        } catch {
            throw .cancelled
        }
    }
}

/// Per-provider limits (SPEC §5.5, Reliability): a token bucket for requests per minute, which
/// allows a burst up to the limit and then one request per 60/limit seconds, plus a cap on calls in
/// flight. Call `release()` after every successful `acquire()`.
public actor RateLimiter {
    private let requestsPerMinute: Int
    private let maxConcurrent: Int
    private let clock: any LLMClock
    private var tokens: Double
    private var refilledAt: Duration
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(requestsPerMinute: Int, maxConcurrent: Int, clock: any LLMClock) {
        self.requestsPerMinute = max(1, requestsPerMinute)
        self.maxConcurrent = max(1, maxConcurrent)
        self.clock = clock
        tokens = Double(max(1, requestsPerMinute))
        refilledAt = clock.now
    }

    public func acquire() async throws(LLMError) {
        try await takeSlot()
        do {
            try await takeToken()
        } catch {
            release()
            throw error
        }
    }

    public func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand the slot straight to the next caller; `active` stays the same.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func takeToken() async throws(LLMError) {
        while true {
            refill()
            if tokens >= 1 {
                tokens -= 1
                return
            }
            // Whole milliseconds, so the waits are exact: 10 a minute is one every 6,000 ms.
            let wait = Int(((1 - tokens) * 60_000 / Double(requestsPerMinute)).rounded(.up))
            try await clock.sleep(for: .milliseconds(wait))
        }
    }

    private func refill() {
        let now = clock.now
        let elapsed = Self.milliseconds(now - refilledAt)
        tokens = min(Double(requestsPerMinute), tokens + Double(elapsed) * Double(requestsPerMinute) / 60_000)
        refilledAt = now
    }

    private func takeSlot() async throws(LLMError) {
        if active < maxConcurrent {
            active += 1
            return
        }
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters.append((id, continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        } catch {
            throw .cancelled
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
