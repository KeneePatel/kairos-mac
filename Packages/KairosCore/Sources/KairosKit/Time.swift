import Foundation

/// The wall clock, injected so tests can fix "now". Named apart from the standard library's
/// `Clock`, which measures durations rather than dates.
public protocol WallClock: Sendable {
    var now: Date { get }
}

public struct SystemWallClock: WallClock {
    public init() {}
    public var now: Date { Date() }
}

/// A clock that only moves when told to, for tests.
public final class ManualWallClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_793_000_000)) { current = start }

    public var now: Date { lock.withLock { current } }

    public func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
    public func set(_ date: Date) { lock.withLock { current = date } }
}

extension Date {
    /// Milliseconds since 1970, the form every time column stores.
    public var milliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded(.down)) }

    public init(milliseconds: Int64) {
        self.init(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// Whole days from `self` to `later`, rounded down; negative when `later` is earlier.
    public func days(until later: Date) -> Int {
        Int((later.timeIntervalSince(self) / 86_400).rounded(.down))
    }
}

extension TimeInterval {
    public static func days(_ count: Double) -> TimeInterval { count * 86_400 }
    public static func hours(_ count: Double) -> TimeInterval { count * 3_600 }
    public static func minutes(_ count: Double) -> TimeInterval { count * 60 }
}
