import Foundation
import os

/// Runs at most `limit` operations at once for each key, the rest waiting in order: how fetches
/// stay polite to each job board's host while reading many hosts in parallel, and how AI calls keep
/// to a plan's concurrency.
public actor ConcurrencyGate {
    private let limit: Int
    private var running: [String: Int] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func run<T: Sendable>(_ key: String = "", _ body: @Sendable () async throws -> T) async throws -> T {
        await enter(key)
        defer { leave(key) }
        return try await body()
    }

    private func enter(_ key: String) async {
        if running[key, default: 0] < limit {
            running[key, default: 0] += 1
            return
        }
        await withCheckedContinuation { waiting[key, default: []].append($0) }
    }

    private func leave(_ key: String) {
        if var queue = waiting[key], !queue.isEmpty {
            // The slot passes straight to the next waiter, so the count stays the same.
            let next = queue.removeFirst()
            waiting[key] = queue.isEmpty ? nil : queue
            next.resume()
        } else {
            running[key, default: 1] -= 1
            if running[key] == 0 { running[key] = nil }
        }
    }
}

/// A value shared between tasks behind a lock, for counters and small caches that don't need an actor.
public final class Locked<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ value: Value) {
        lock = OSAllocatedUnfairLock(initialState: value)
    }

    public var value: Value { lock.withLock { $0 } }

    @discardableResult
    public func withLock<T: Sendable>(_ body: @Sendable (inout Value) throws -> T) rethrows -> T {
        try lock.withLock(body)
    }
}

/// The Logger categories Kairos writes to. Lines carry ids and counts, never personal data.
public enum Log {
    public static let subsystem = "com.keneepatel.kairos"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
