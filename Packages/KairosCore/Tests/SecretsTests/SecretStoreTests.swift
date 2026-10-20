import Foundation
import Synchronization
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

/// Counts reads that reach the store underneath.
private final class CountingStore: SecretStore {
    let base = InMemorySecretStore()
    private let count = Mutex(0)
    var reads: Int { count.withLock { $0 } }

    func read(_ key: SecretKey) throws(SecretsError) -> String? {
        count.withLock { $0 += 1 }
        return try base.read(key)
    }
    func write(_ value: String, for key: SecretKey) throws(SecretsError) { try base.write(value, for: key) }
    func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        try base.write(value, for: key, hint: hint)
    }
    func delete(_ key: SecretKey) throws(SecretsError) { try base.delete(key) }
    func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? { try base.summary(key) }
}

@Suite("Secret hints and the session cache")
struct SecretCacheTests {
    /// Each key is read from the keychain once a session, however many routers ask.
    @Test func eachSecretIsReadOnceASession() throws {
        let counting = CountingStore()
        let key = SecretKey("llm.gemini.1")
        try counting.write("AIza-secret", for: key)
        let store = CachingSecretStore(counting)
        for _ in 0..<5 { #expect(try store.read(key) == "AIza-secret") }
        #expect(counting.reads == 1)

        try store.write("AIza-replaced", for: key)  // a write updates what later reads see
        #expect(try store.read(key) == "AIza-replaced" && counting.reads == 1)
        try store.delete(key)
        #expect(try store.read(key) == nil && counting.reads == 2)

        let missing = SecretKey("llm.gemini.2")  // not found isn't remembered: adding one later works
        #expect(try store.read(missing) == nil)
        try counting.write("added-elsewhere", for: missing)
        #expect(try store.read(missing) == "added-elsewhere")
    }

    /// A hint (the masked key) is there without reading the secret; a later write without one keeps it.
    @Test func hintsAreReadWithoutTheSecret() throws {
        let counting = CountingStore()
        let store = CachingSecretStore(counting)
        let key = SecretKey("llm.gemini.1")
        #expect(try store.summary(key) == nil)
        try store.write("AIza-secret", for: key, hint: "AIza…cret")
        #expect(try store.summary(key) == SecretSummary(hint: "AIza…cret") && counting.reads == 0)
        try counting.base.write("AIza-other", for: key)
        #expect(try counting.base.summary(key)?.hint == "AIza…cret")
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

    /// The hint lives in the item's comment, which comes back without the secret.
    @Test func keychainHintsComeBackWithoutTheSecret() throws {
        let store = KeychainStore(service: "com.keneepatel.kairos.tests")
        let key = SecretKey("live-test-\(UUID().uuidString)")
        defer { try? store.delete(key) }
        #expect(try store.summary(key) == nil)
        try store.write("value-1", for: key, hint: "val…e-1")
        #expect(try store.summary(key) == SecretSummary(hint: "val…e-1"))
        try store.write("value-2", for: key)  // replacing the value keeps the hint
        #expect(try store.summary(key)?.hint == "val…e-1" && (try store.read(key)) == "value-2")
    }
}
