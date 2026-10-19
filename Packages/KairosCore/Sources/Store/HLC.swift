/// A hybrid logical clock timestamp: wall-clock milliseconds, a counter for
/// events within the same millisecond, and the id of the device that made it.
///
/// Its text form has fixed-width fields, so comparing two strings gives the
/// same order as comparing the timestamps. SQLite and Postgres compare
/// `updated_hlc` columns as plain text and still get last-writer-wins right.
public struct HLCTimestamp: Comparable, Hashable, Sendable, CustomStringConvertible {
    public static let maxCounter = 0xFFFF

    public let milliseconds: Int64
    public let counter: Int
    public let device: String

    /// - Parameter device: exactly 8 lowercase hex characters.
    public init(milliseconds: Int64, counter: Int, device: String) throws(HLCError) {
        guard (0...9_999_999_999_999).contains(milliseconds) else { throw .outOfRange("milliseconds") }
        guard (0...Self.maxCounter).contains(counter) else { throw .outOfRange("counter") }
        guard Self.isDeviceID(device) else { throw .invalidDevice(device) }
        self.milliseconds = milliseconds
        self.counter = counter
        self.device = device
    }

    /// Parses the `description` form, e.g. `1760891234567-002a-1a2b3c4d`.
    public init(_ text: String) throws(HLCError) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 13, parts[1].count == 4,
            let ms = Int64(parts[0]), let counter = Int(parts[1], radix: 16)
        else { throw .malformed(text) }
        try self.init(milliseconds: ms, counter: counter, device: String(parts[2]))
    }

    /// For the clock only: its fields are valid by construction.
    fileprivate init(validMilliseconds: Int64, counter: Int, device: String) {
        self.milliseconds = validMilliseconds
        self.counter = counter
        self.device = device
    }

    public var description: String {
        let ms = String(milliseconds)
        let hex = String(counter, radix: 16)
        return String(repeating: "0", count: 13 - ms.count) + ms + "-"
            + String(repeating: "0", count: 4 - hex.count) + hex + "-" + device
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.milliseconds, lhs.counter, lhs.device) < (rhs.milliseconds, rhs.counter, rhs.device)
    }

    static func isDeviceID(_ text: String) -> Bool {
        text.utf8.count == 8 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public enum HLCError: Error, Equatable {
    case malformed(String)
    case outOfRange(String)
    case invalidDevice(String)
}

/// The clock itself (Kulkarni et al., "Logical Physical Clocks"). A value
/// type with no locking: the store owns one inside its actor.
public struct HybridLogicalClock: Sendable {
    public let device: String
    private var lastMilliseconds: Int64 = 0
    private var lastCounter = 0

    public init(device: String) throws(HLCError) {
        guard HLCTimestamp.isDeviceID(device) else { throw .invalidDevice(device) }
        self.device = device
    }

    /// A timestamp for a local write. Never goes backwards, even if the wall
    /// clock does.
    public mutating func tick(now: Int64) -> HLCTimestamp {
        if now > lastMilliseconds {
            lastMilliseconds = now
            lastCounter = 0
        } else {
            advanceCounter()
        }
        return current
    }

    /// Moves the clock past a timestamp received from another device, so the
    /// next local write orders after everything this device has seen.
    public mutating func receive(_ remote: HLCTimestamp, now: Int64) {
        let newest = max(lastMilliseconds, remote.milliseconds, now)
        if newest == lastMilliseconds && newest == remote.milliseconds {
            lastCounter = max(lastCounter, remote.counter)
            advanceCounter()
        } else if newest == lastMilliseconds {
            advanceCounter()
        } else if newest == remote.milliseconds {
            lastMilliseconds = newest
            lastCounter = remote.counter
            advanceCounter()
        } else {
            lastMilliseconds = newest
            lastCounter = 0
        }
    }

    private mutating func advanceCounter() {
        if lastCounter == HLCTimestamp.maxCounter {
            // 65,536 events in one millisecond: borrow the next millisecond
            // rather than overflow the fixed-width counter.
            lastMilliseconds += 1
            lastCounter = 0
        } else {
            lastCounter += 1
        }
    }

    private var current: HLCTimestamp {
        // The device was checked in init and the counter is kept within range.
        HLCTimestamp(validMilliseconds: lastMilliseconds, counter: lastCounter, device: device)
    }
}
