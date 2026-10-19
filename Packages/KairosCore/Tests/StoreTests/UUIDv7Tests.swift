import Foundation
import Testing

@testable import Store

@Suite("UUIDv7")
struct UUIDv7Tests {
    @Test func layoutMatchesRFC9562() {
        let id = UUIDv7Generator.make(milliseconds: 0x0123_4567_89AB, randA: 0xCDE, randB: .max)
        let b = id.uuid
        #expect([b.0, b.1, b.2, b.3, b.4, b.5] == [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB])
        #expect(b.6 >> 4 == 7, "version nibble")
        #expect(b.8 >> 6 == 0b10, "variant bits")
        #expect(id.lowercased.hasPrefix("01234567-89ab-7cde-"))
    }

    @Test func idsFromOneGeneratorSortInCreationOrder() {
        var generator = UUIDv7Generator()
        var rng = SplitMix64(seed: 42)
        var ids: [String] = []
        // Several ids per millisecond, then later milliseconds.
        for ms in [UInt64(1_760_000_000_000), 1_760_000_000_000, 1_760_000_000_000, 1_760_000_000_001, 1_760_000_000_500] {
            for _ in 0..<50 { ids.append(generator.next(now: ms, using: &rng).lowercased) }
        }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }

    @Test func aClockGoingBackwardsStillGivesIncreasingIDs() {
        var generator = UUIDv7Generator()
        var rng = SplitMix64(seed: 1)
        let first = generator.next(now: 5_000, using: &rng).lowercased
        let second = generator.next(now: 4_000, using: &rng).lowercased
        #expect(first < second)
    }

    @Test func counterOverflowMovesToTheNextMillisecond() {
        var generator = UUIDv7Generator()
        var rng = SplitMix64(seed: 3)
        var ids: [UUID] = []
        for _ in 0..<5_000 { ids.append(generator.next(now: 9_000, using: &rng)) }
        let strings = ids.map(\.lowercased)
        #expect(strings == strings.sorted())
        let lastMs = ids.last.map { id in
            [id.uuid.0, id.uuid.1, id.uuid.2, id.uuid.3, id.uuid.4, id.uuid.5].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        #expect((lastMs ?? 0) > 9_000)
    }
}
