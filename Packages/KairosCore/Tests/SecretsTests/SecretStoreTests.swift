import Foundation
import Testing

@testable import Secrets

@Suite("Secret store contract")
struct SecretStoreTests {
    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemorySecretStore()
        let key = SecretKey("llm.gemini.1")
        #expect(try store.read(key) == nil)
        try store.write("first", for: key)
        try store.write("second", for: key)  // overwrite, not a duplicate
        #expect(try store.read(key) == "second")
        try store.delete(key)
        try store.delete(key)  // deleting twice is fine
        #expect(try store.read(key) == nil)
    }
}

/// Touches the real login keychain, so it only runs when asked: KAIROS_LIVE_KEYCHAIN=1 swift test.
@Suite(
    "Keychain (live)",
    .enabled(if: ProcessInfo.processInfo.environment["KAIROS_LIVE_KEYCHAIN"] == "1", "Set KAIROS_LIVE_KEYCHAIN=1"))
struct KeychainLiveTests {
    @Test func keychainRoundTripsAndCleansUp() throws {
        let store = KeychainStore(service: "com.keneepatel.kairos.tests")
        let key = SecretKey("live-test-\(UUID().uuidString)")
        defer { try? store.delete(key) }
        try store.write("value-1", for: key)
        try store.write("value-2", for: key)
        #expect(try store.read(key) == "value-2")
        try store.delete(key)
        #expect(try store.read(key) == nil)
    }
}
