import Foundation
import Secrets
import TestSupport
import Testing

@testable import LLM

private func request(_ model: String = "flash") -> ChatRequest {
    ChatRequest(
        task: .analyzeJob, model: model, messages: [.user("x")], schema: nil, temperature: 0, maxOutputTokens: 100)
}

private func client(_ keys: [FakeProvider], rests: KeyRests, clock: VirtualClock) -> LLMClient {
    LLMClient(
        keys: keys, keyIDs: keys.map(\.name), rests: rests, policy: ClientPolicy(requestsPerMinute: 600), clock: clock,
        jitter: { 1.0 })
}

/// A key that used up its quota stays out of rotation for every client of its provider, for that
/// model only, until the time the provider gave (SPEC §5.5: a 429 rotates to the next key).
@Suite("Key rotation across operations")
struct KeyRestsTests {
    @Test func aUsedUpKeyIsSkippedByLaterOperationsToo() async throws {
        let rests = KeyRests()
        let clock = VirtualClock()
        let usedUp = FakeProvider(
            [.analyzeJob: [.failure(.rateLimited(retryAfterSeconds: 8 * 3_600))]], name: "primary")
        let backup = FakeProvider([.analyzeJob: [.reply("ok")]], name: "backup")
        #expect(
            try await client([usedUp, backup], rests: rests, clock: clock).complete(request()).response.text == "ok")

        // The next import builds a new client, which goes straight to the backup.
        let primaryAgain = FakeProvider([.analyzeJob: [.reply("not asked")]], name: "primary")
        let backupAgain = FakeProvider([.analyzeJob: [.reply("ok again")]], name: "backup")
        let next = client([primaryAgain, backupAgain], rests: rests, clock: clock)
        #expect(try await next.complete(request()).response.text == "ok again")
        #expect(primaryAgain.requests.isEmpty && clock.sleeps.isEmpty)
    }

    /// Gemini counts quota per model: a key out of Flash requests still has Flash-Lite ones.
    @Test func aKeyUsedUpOnOneModelStillServesTheOthers() async throws {
        let rests = KeyRests()
        let clock = VirtualClock()
        rests.rest(key: "primary", model: "flash", until: clock.now + .seconds(3_600))
        let primary = FakeProvider([.analyzeJob: [.reply("lite ok")]], name: "primary")
        let backup = FakeProvider([.analyzeJob: []], name: "backup")
        let pool = client([primary, backup], rests: rests, clock: clock)
        #expect(try await pool.complete(request("flash-lite")).response.text == "lite ok")
        #expect(primary.requests.map(\.model) == ["flash-lite"])
    }

    @Test func whenEveryKeyIsUsedUpItSaysWhenTheFirstIsBack() async throws {
        let rests = KeyRests()
        let clock = VirtualClock()
        rests.rest(key: "primary", model: "flash", until: clock.now + .seconds(7_200))
        rests.rest(key: "backup", model: "flash", until: clock.now + .seconds(5_400))
        let primary = FakeProvider([.analyzeJob: [.reply("no")]], name: "primary")
        let backup = FakeProvider([.analyzeJob: [.reply("no")]], name: "backup")
        let pool = client([primary, backup], rests: rests, clock: clock)
        await #expect(throws: LLMError.rateLimited(retryAfterSeconds: 5_400)) { try await pool.complete(request()) }
        #expect(primary.requests.isEmpty && backup.requests.isEmpty && clock.sleeps.isEmpty)
    }

    @Test func restsEndWhenTheirTimeComes() {
        let rests = KeyRests()
        rests.rest(key: "primary", model: "flash", until: .seconds(100))
        rests.rest(key: "primary", model: "flash-lite", until: .seconds(30))
        rests.rest(key: "primary", model: "pro", until: .seconds(70))
        #expect(
            rests.resting(key: "primary", at: .seconds(40)) == [
                KeyRests.Rest(model: "pro", remaining: .seconds(30)),
                KeyRests.Rest(model: "flash", remaining: .seconds(60)),
            ])
        #expect(rests.resting(key: "primary", at: .seconds(100)).isEmpty)
        #expect(rests.resting(key: "backup", at: .zero).isEmpty)
    }

    /// Settings' pool names each key by its Keychain account, so a rest follows the key itself.
    @Test func aProviderSetupRestsKeysByTheirKeychainName() async throws {
        let secrets = InMemorySecretStore()
        try secrets.write("key-one", for: SecretKey("llm.gemini.one"))
        try secrets.write("key-two", for: SecretKey("llm.gemini.two"))
        let quota = """
            [{"error":{"code":429,"message":"Quota exceeded for metric: generate_content_free_tier_requests, limit: 20",
              "status":"RESOURCE_EXHAUSTED",
              "details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"29359s"}]}}]
            """
        let ok = try ScriptedURLProtocol.fixture("llm/gemini-json-gemini-flash-latest.json")
        let transport = FakeTransport([.init(status: 429, body: Data(quota.utf8)), .init(body: ok)])
        let rests = KeyRests()
        let clock = VirtualClock()
        let setup = ProviderSetup(
            id: "gemini", preset: .gemini, keyNames: [SecretKey("llm.gemini.one"), SecretKey("llm.gemini.two")])
        let pool = try setup.client(secrets: secrets, rests: rests, transport: transport, clock: clock)
        _ = try await pool.complete(request("gemini-flash-latest"))

        #expect(
            transport.sent.map { $0.value(forHTTPHeaderField: "Authorization") } == [
                "Bearer key-one", "Bearer key-two",
            ])
        #expect(
            rests.resting(key: "llm.gemini.one", at: clock.now) == [
                KeyRests.Rest(model: "gemini-flash-latest", remaining: .seconds(29_359))
            ])
        #expect(rests.resting(key: "llm.gemini.two", at: clock.now).isEmpty)
    }

    /// Every system clock counts from one start, so clients built at different times agree on when
    /// a rest ends.
    @Test func systemClocksShareOneStart() async throws {
        let earlier = SystemClock()
        try await Task.sleep(for: .milliseconds(80))
        let later = SystemClock()
        let (first, second) = (earlier.now, later.now)
        // With a start each, `later` would read about 80 ms behind.
        #expect(second >= first && second - first < .milliseconds(40))
    }
}
