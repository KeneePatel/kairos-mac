import Foundation

/// Generates RFC 9562 version 7 UUIDs: a 48-bit Unix millisecond timestamp,
/// then randomness. Ids made on any device sort roughly by creation time and
/// never need a server to hand them out.
///
/// Within one millisecond the 12-bit `rand_a` field counts up (RFC 9562
/// §6.2, method 1), so ids from one generator always sort in creation order.
public struct UUIDv7Generator: Sendable {
    private var lastMilliseconds: UInt64 = 0
    private var counter: UInt16 = 0

    public init() {}

    public mutating func next(now milliseconds: UInt64) -> UUID {
        var random = SystemRandomNumberGenerator()
        return next(now: milliseconds, using: &random)
    }

    public mutating func next<R: RandomNumberGenerator>(now milliseconds: UInt64, using random: inout R) -> UUID {
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
}
