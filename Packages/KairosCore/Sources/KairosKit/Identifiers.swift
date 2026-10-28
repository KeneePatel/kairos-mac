import CryptoKit
import Foundation

/// Generates RFC 9562 version 7 UUIDs: a 48-bit Unix millisecond timestamp, then randomness. Ids
/// sort roughly by creation time and never need a server to hand them out. Within one millisecond
/// the 12-bit `rand_a` field counts up (RFC 9562 §6.2, method 1), so one generator's ids always sort
/// in the order they were made.
public struct UUIDv7Generator: Sendable {
    private var lastMilliseconds: UInt64 = 0
    private var counter: UInt16 = 0

    public init() {}

    public mutating func next(at date: Date = Date()) -> UUID {
        var random = SystemRandomNumberGenerator()
        return next(milliseconds: UInt64(clamping: date.milliseconds), using: &random)
    }

    public mutating func next<R: RandomNumberGenerator>(milliseconds: UInt64, using random: inout R) -> UUID {
        if milliseconds > lastMilliseconds {
            lastMilliseconds = milliseconds
            // Start low in the counter space so many ids fit in one millisecond.
            counter = UInt16.random(in: 0...0x3FF, using: &random)
        } else if counter == 0xFFF {
            lastMilliseconds += 1
            counter = 0
        } else {
            counter += 1
        }
        return Self.make(milliseconds: lastMilliseconds, randA: counter, randB: random.next())
    }

    static func make(milliseconds: UInt64, randA: UInt16, randB: UInt64) -> UUID {
        let ms = milliseconds & 0xFFFF_FFFF_FFFF
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8(truncatingIfNeeded: ms >> (8 * (5 - i))) }
        bytes[6] = 0x70 | UInt8(truncatingIfNeeded: (randA >> 8) & 0x0F)  // version 7
        bytes[7] = UInt8(truncatingIfNeeded: randA)
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: randB >> (8 * (7 - i))) }
        bytes[8] = 0x80 | (bytes[8] & 0x3F)  // variant 10
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}

extension UUID {
    /// The lowercase form stored in `id` columns.
    public var lowercased: String { uuidString.lowercased() }

    /// A fresh UUIDv7. Two calls in the same millisecond aren't guaranteed to sort in order; rows
    /// that need an order keep a `sort` column.
    public static func v7(at date: Date = Date()) -> UUID {
        var generator = UUIDv7Generator()
        return generator.next(at: date)
    }
}

/// Ids derived from content, so every device and every run agree on them without a server: a job
/// is the hash of its canonical URL.
public enum StableID {
    /// The first 16 bytes of SHA-256 over `text`, as 32 lowercase hex digits.
    public static func of(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The whole SHA-256 of `data`, as lowercase hex: file checksums and cache keys.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
