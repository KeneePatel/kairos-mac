import Testing

@testable import Store

@Suite("Hybrid logical clock")
struct HLCTests {
    let device = "1a2b3c4d"

    @Test func textFormIsFixedWidthAndRoundTrips() throws {
        let ts = try HLCTimestamp(milliseconds: 1_760_891_234_567, counter: 42, device: device)
        #expect(ts.description == "1760891234567-002a-1a2b3c4d")
        #expect(try HLCTimestamp(ts.description) == ts)
        let small = try HLCTimestamp(milliseconds: 5, counter: 0, device: device)
        #expect(small.description == "0000000000005-0000-1a2b3c4d")
    }

    @Test func textOrderMatchesTimestampOrder() throws {
        var rng = SplitMix64(seed: 7)
        let devices = ["00000000", "1a2b3c4d", "ffffffff"]
        for _ in 0..<2_000 {
            let a = try HLCTimestamp(
                milliseconds: Int64(rng.next() % 2_000_000_000_000), counter: Int(rng.next() % 0x10000),
                device: devices[Int(rng.next() % 3)])
            let b = try HLCTimestamp(
                milliseconds: Int64(rng.next() % 2_000_000_000_000), counter: Int(rng.next() % 0x10000),
                device: devices[Int(rng.next() % 3)])
            #expect((a < b) == (a.description < b.description))
        }
    }

    @Test func tickNeverGoesBackwardsWhenTheWallClockDoes() throws {
        var clock = try HybridLogicalClock(device: device)
        let first = clock.tick(now: 1_000)
        let second = clock.tick(now: 400)  // wall clock jumped back
        let third = clock.tick(now: 1_000)
        #expect(first < second)
        #expect(second < third)
        #expect(second.milliseconds == 1_000 && second.counter == 1)
    }

    @Test func ticksInTheSameMillisecondCountUp() throws {
        var clock = try HybridLogicalClock(device: device)
        let stamps = (0..<5).map { _ in clock.tick(now: 2_000) }
        #expect(stamps.map(\.counter) == [0, 1, 2, 3, 4])
    }

    @Test func receivingANewerRemoteTimestampMovesTheClockPastIt() throws {
        var clock = try HybridLogicalClock(device: device)
        _ = clock.tick(now: 1_000)
        let remote = try HLCTimestamp(milliseconds: 5_000, counter: 9, device: "ffffffff")
        clock.receive(remote, now: 1_001)
        let next = clock.tick(now: 1_002)
        #expect(next > remote)
    }

    @Test func receivingAnOlderRemoteTimestampKeepsLocalTimeMoving() throws {
        var clock = try HybridLogicalClock(device: device)
        let before = clock.tick(now: 9_000)
        clock.receive(try HLCTimestamp(milliseconds: 100, counter: 0, device: "ffffffff"), now: 9_000)
        #expect(clock.tick(now: 9_000) > before)
    }

    @Test func counterOverflowBorrowsTheNextMillisecond() throws {
        var clock = try HybridLogicalClock(device: device)
        var last = clock.tick(now: 3_000)
        for _ in 0..<HLCTimestamp.maxCounter { last = clock.tick(now: 3_000) }
        #expect(last.milliseconds == 3_000 && last.counter == HLCTimestamp.maxCounter)
        let overflowed = clock.tick(now: 3_000)
        #expect(overflowed.milliseconds == 3_001 && overflowed.counter == 0)
        #expect(overflowed > last)
    }

    @Test(arguments: ["", "1A2B3C4D", "1a2b3c4", "1a2b3c4dd", "zzzzzzzz"])
    func rejectsBadDeviceIDs(_ bad: String) {
        #expect(throws: HLCError.invalidDevice(bad)) { try HybridLogicalClock(device: bad) }
    }

    @Test(arguments: ["", "abc", "1760891234567-2a-1a2b3c4d", "176089123456-002a-1a2b3c4d", "1760891234567-002a"])
    func rejectsMalformedText(_ text: String) {
        #expect(throws: HLCError.self) { try HLCTimestamp(text) }
    }
}

/// Deterministic random numbers for repeatable tests.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
