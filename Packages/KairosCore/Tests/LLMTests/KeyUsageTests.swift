import Foundation
import Secrets
import Store
import Synchronization
import Testing

@testable import LLM

/// Gemini's 429 for a used-up day, in the shape of the recorded one
/// (`gemini-error-429-free-tier-limit-0.json`): a `QuotaFailure` per quota hit, and a message line
/// per violation, in the same order.
private func dailyRefusal(_ violations: [(id: String, limit: Int)], retry: String = "51393s") -> Data {
    let list = violations.map { violation in
        #"{"quotaDimensions":{"location":"global","model":"gemini-3.5-flash"},"quotaId":"\#(violation.id)","quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests"}"#
    }
    let lines = violations.map {
        #"\n* Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: \#($0.limit), model: gemini-3.5-flash"#
    }
    return Data(
        #"[{"error":{"code":429,"details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[\#(list.joined(separator: ","))]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"\#(retry)"}],"message":"You exceeded your current quota. \#(lines.joined())\nPlease retry in 14h16m33s.","status":"RESOURCE_EXHAUSTED"}}]"#
            .utf8)
}

private let perDay = "GenerateRequestsPerDayPerProjectPerModel-FreeTier"
private let perMinute = "GenerateRequestsPerMinutePerProjectPerModel-FreeTier"

private func chat(_ data: Data, status: Int = 429) async -> LLMError? {
    let transport = FakeTransport([FakeTransport.Reply(status: status, body: data)])
    let gemini = OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport)
    let request = ChatRequest(
        task: .analyzeJob, model: "gemini-flash-latest", messages: [.user("x")], schema: nil, temperature: 0,
        maxOutputTokens: 10)
    do {
        _ = try await gemini.complete(request)
        return nil
    } catch {
        return error
    }
}

/// Collects what a client reports.
private final class Meter: Sendable {
    let calls = Mutex<[KeyCall]>([])
    var heard: [KeyCall] { calls.withLock { $0 } }
    var meter: KeyMeter { { call in self.calls.withLock { $0.append(call) } } }
}

@Suite("Key usage")
struct KeyUsageTests {
    /// A used-up day says so with Google's own limit and wait; a minute's limit stays a rate limit,
    /// and a plan without the model stays that.
    @Test func aRefusalForTheDayNamesItsLimit() async {
        let daily = await chat(dailyRefusal([(perDay, 20)]))
        #expect(daily == .quotaUsedUp(model: "gemini-flash-latest", limit: 20, retryAfterSeconds: 51_393))
        // Two quotas hit at once: the day's limit is its own line, not the minute's.
        let both = await chat(dailyRefusal([(perMinute, 5), (perDay, 500)]))
        #expect(both == .quotaUsedUp(model: "gemini-flash-latest", limit: 500, retryAfterSeconds: 51_393))
        #expect(await chat(dailyRefusal([(perMinute, 5)], retry: "12s")) == .rateLimited(retryAfterSeconds: 12))
        #expect(await chat(dailyRefusal([(perDay, 0)])) == .modelNotOnPlan("gemini-flash-latest"))
        // A violation that carries its limit is taken at its word.
        let valued = Data(
            #"{"error":{"details":[{"violations":[{"quotaId":"\#(perDay)","quotaValue":"250"}]}],"message":"quota"}}"#
                .utf8)
        #expect(await chat(valued) == .quotaUsedUp(model: "gemini-flash-latest", limit: 250, retryAfterSeconds: nil))
        #expect(LLMError.quotaUsedUp(model: "m", limit: nil, retryAfterSeconds: nil).code == "quota_used_up")
        #expect(
            LLMError.quotaUsedUp(model: "m", limit: nil, retryAfterSeconds: nil).reason == "used up today's requests")
    }

    /// Every call through every key is reported once; a key used up for the day rests while the
    /// next one answers, and the refusal never leaves the client.
    @Test func theClientReportsEachKeysCalls() async throws {
        let first = FakeProvider([
            .analyzeJob: [
                .reply("ok", inputTokens: 10, outputTokens: 2),
                .failure(.quotaUsedUp(model: "flash", limit: 20, retryAfterSeconds: 3_600)),
            ]
        ])
        let second = FakeProvider([.analyzeJob: [.reply("ok"), .failure(.server(status: 503))]])
        let meter = Meter()
        var policy = ClientPolicy(requestsPerMinute: 600)
        policy.attempts = 1
        let client = LLMClient(
            keys: [first, second], keyIDs: ["k1", "k2"], meter: meter.meter, policy: policy, clock: VirtualClock(),
            jitter: { 1 })
        let request = ChatRequest(
            task: .analyzeJob, model: "flash", messages: [.user("x")], schema: nil, temperature: 0, maxOutputTokens: 10)
        _ = try await client.complete(request)
        _ = try await client.complete(request)
        await #expect(throws: LLMError.server(status: 503)) { try await client.complete(request) }
        #expect(
            meter.heard == [
                KeyCall(key: "k1", model: "flash", outcome: .answered, inputTokens: 10, outputTokens: 2),
                KeyCall(key: "k1", model: "flash", outcome: .usedUp, dailyLimit: 20, backInSeconds: 3_600),
                KeyCall(key: "k2", model: "flash", outcome: .answered),
                KeyCall(key: "k2", model: "flash", outcome: .failed),
            ])
    }

    /// Only what reached the provider's count is a call: not a minute's rate limit, a network
    /// error, a stop, or a refused key or model.
    @Test func onlyCallsThatCountAreCounted() {
        for error: LLMError in [
            .rateLimited(retryAfterSeconds: 5), .network("down"), .cancelled, .modelNotOnPlan("m"),
            .keyRejected(provider: "p"), .modelNotFound("m"), .modelUnavailable(model: "m", reason: "r"),
        ] {
            #expect(KeyCall(key: "k", model: "m", result: .failure(error)) == nil, "\(error)")
        }
        #expect(KeyCall(key: "k", model: "m", result: .failure(.timedOut))?.outcome == .failed)
        #expect(KeyCall(key: "k", model: "m", result: .failure(.invalidJSON("x")))?.outcome == .failed)
    }

    /// The log counts a key's calls since its quota day began and keeps the limit Google last named,
    /// from any day; a refusal holds until it said, or the day's end.
    @Test func theLogCountsTheDayAndKeepsTheLimit() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        let log = KeyCallLog(db)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = start.addingTimeInterval(-3_600)
        try await log.record(
            KeyCall(key: "k1", model: "flash", outcome: .usedUp, dailyLimit: 20, backInSeconds: 600),
            provider: "gemini",
            at: yesterday)
        try await log.record(KeyCall(key: "k1", model: "flash", outcome: .answered), provider: "gemini", at: yesterday)
        for outcome in [KeyCall.Outcome.answered, .answered, .failed] {
            try await log.record(KeyCall(key: "k1", model: "flash", outcome: outcome), provider: "gemini", at: start)
        }
        try await log.record(
            KeyCall(key: "k1", model: "lite", outcome: .usedUp, backInSeconds: 7_200), provider: "gemini", at: start)
        try await log.record(KeyCall(key: "k2", model: "flash", outcome: .answered), provider: "gemini", at: start)
        try await log.record(KeyCall(key: "k9", model: "flash", outcome: .answered), provider: "other", at: start)
        let use = try await log.use(provider: "gemini", since: start)
        #expect(use["k1"]?["flash"] == KeyModelUse(calls: 3, limit: 20))
        #expect(use["k1"]?["lite"] == KeyModelUse(calls: 0, refused: true, back: start.addingTimeInterval(7_200)))
        #expect(use["k2"]?["flash"] == KeyModelUse(calls: 1) && use["k9"] == nil)
        #expect(try await log.deleteOlder(than: start) == 2)
        #expect(try await log.use(provider: "gemini", since: start)["k1"]?["flash"]?.limit == nil)
        // What the router builds reports to the same log: a client's meter records at its own time.
        await log.meter(provider: "gemini", now: { start })(KeyCall(key: "k3", model: "lite", outcome: .answered))
        #expect(try await log.use(provider: "gemini", since: start)["k3"]?["lite"]?.calls == 1)
    }

    /// The router Settings builds logs each call by the key that made it, by the key's name.
    @Test func theRouterLogsCallsByKey() async throws {
        let db = try Database(path: ":memory:")
        try await Migrator.migrate(db, with: Migrator.bundled())
        var settings = LLMSettings.defaults()
        let name = LLMSettings.newKeyName(for: "gemini")
        settings.providers[0].keyNames = [name]
        let answer = #"{"requirements":[{"text":"Go","kind":"must"}],"years_required":3}"#
        let reply = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": answer]]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120],
        ])
        let router = settings.router(
            db: db, secrets: InMemorySecretStore([SecretKey(name): "k"]),
            transport: FakeTransport([FakeTransport.Reply(body: reply)]))
        _ = try await router.run(RequirementsTask(), input: "Go required. 3 years.")
        let model = try #require(settings.routes[TaskID.analyzeJob.rawValue]?.first?.model)
        let use = try await KeyCallLog(db).use(
            provider: "gemini", since: ProviderPreset.gemini.quotaDay(containing: Date()).start)
        #expect(use == [name: [model: KeyModelUse(calls: 1)]])
    }

    /// One bar per model: what's left of Google's limit, or the usual one marked "about"; a refused
    /// model is used up until it's back; a model with no limit known shows only its calls.
    @Test func eachModelGetsABarOfWhatsLeft() throws {
        let gemini = ProviderPreset.gemini
        // 2026-10-23 12:00 UTC is 05:00 in Los Angeles: the day began at 07:00 UTC and ends tomorrow.
        let now = Date(timeIntervalSince1970: 1_792_756_800)
        let day = gemini.quotaDay(containing: now)
        #expect(day.start == Date(timeIntervalSince1970: 1_792_738_800) && day.duration == 86_400)
        #expect(gemini.usualDailyRequests(for: "gemini-flash-lite-latest") == 500)
        #expect(gemini.usualDailyRequests(for: "gemini-3.5-flash") == 20)
        #expect(gemini.usualDailyRequests(for: "gemma-3-27b-it") == nil)
        let back = now.addingTimeInterval(3_600)
        let bars = gemini.dailyBars(
            models: ["gemini-flash-lite-latest", "gemini-flash-latest", "gemini-flash-2"],
            use: [
                "gemini-flash-lite-latest": KeyModelUse(calls: 312),
                "gemini-flash-latest": KeyModelUse(calls: 20, limit: 20, refused: true, back: back),
                "gemini-flash-2": KeyModelUse(calls: 6, limit: 25),
                "gemma-3-27b-it": KeyModelUse(calls: 2),
            ], now: now)
        #expect(
            bars == [
                UsageBar(
                    label: "gemini-flash-lite-latest", left: 188.0 / 500, detail: "188 of about 500 left today",
                    resets: day.end),
                UsageBar(label: "gemini-flash-latest", left: 0, detail: "Used up", resets: back, usedUp: true),
                UsageBar(label: "gemini-flash-2", left: 19.0 / 25, detail: "19 of 25 left today", resets: day.end),
                UsageBar(label: "gemma-3-27b-it", left: nil, detail: "2 calls today", resets: day.end),
            ])
        // A refusal that's over, or from a wait that ended, no longer holds: the count does.
        let over = gemini.dailyBars(
            models: ["gemini-flash-latest"],
            use: ["gemini-flash-latest": KeyModelUse(calls: 20, refused: true, back: now.addingTimeInterval(-1))],
            now: now)
        #expect(over.first?.detail == "0 of about 20 left today" && over.first?.usedUp == true)
        let unsaid = gemini.dailyBars(
            models: ["gemini-flash-latest"], use: ["gemini-flash-latest": KeyModelUse(calls: 3, refused: true)],
            now: now)
        #expect(unsaid.first?.resets == day.end && unsaid.first?.usedUp == true)
    }

    /// Ollama's balance, current plans: included credits of the month's allowance, plus bought ones.
    /// The reply as one of the user's Free-plan keys sent it on 2026-10-23, amounts changed.
    @Test func aBalanceShowsTheCreditsLeft() throws {
        let reply = Data(
            #"{"included":{"balance_usd":2.41181,"allowance_usd":2.5,"period":{"from":"2026-09-29T03:57:54.588324Z","until":"2026-10-29T03:57:54.588324Z"}},"purchased":{"balance_usd":0}}"#
                .utf8)
        let balance = try CreditBalance.parse(reply)
        #expect(balance.included == 2.41181 && balance.allowance == 2.5 && balance.purchased == 0)
        // 2026-10-29T03:57:54.588324Z, its fractional seconds kept.
        #expect(abs((balance.periodEnd ?? .distantPast).timeIntervalSince1970 - 1_793_246_274.588) < 0.01)
        let bar = try #require(balance.bars.first)
        #expect(bar.label == "Credits" && bar.detail == "$2.41 of $2.50 left" && !bar.usedUp)
        #expect(abs((bar.left ?? 0) - 0.964_724) < 0.000_01 && balance.bars.count == 1)
        let spent = CreditBalance(included: 0, allowance: 2.5, purchased: 5)
        #expect(
            spent.bars.first?.detail == "$0.00 of $2.50 left, plus $5.00 bought" && spent.bars.first?.usedUp == false)
        #expect(CreditBalance(included: 0, allowance: 2.5, purchased: 0).bars.first?.usedUp == true)
        #expect(
            CreditBalance(included: 0, allowance: 0, purchased: 0).bars.first?.detail
                == "No credits: only the free models")
        #expect(
            CreditBalance(purchased: 12).bars == [
                UsageBar(label: "Credits", left: nil, detail: "$12.00 left", resets: nil)
            ])
    }

    /// Older plans report a session and a week as percentages left, each with its reset.
    @Test func anOlderPlanShowsItsSessionAndWeek() throws {
        let reply = Data(
            #"{"included":{"session":{"remaining_percent":75,"resets_at":"2026-10-23T20:00:00Z"},"weekly":{"remaining_percent":0,"resets_at":"2026-10-27T00:00:00Z"}}}"#
                .utf8)
        let bars = try CreditBalance.parse(reply).bars
        #expect(bars.map(\.label) == ["This session", "This week"])
        #expect(bars[0].left == 0.75 && bars[0].detail == "75% left" && !bars[0].usedUp)
        #expect(bars[1].left == 0 && bars[1].usedUp && bars[1].resets == Date(timeIntervalSince1970: 1_793_059_200))
        #expect(throws: LLMError.invalidJSON("balance has no amounts")) { try CreditBalance.parse(Data("{}".utf8)) }
        #expect(throws: LLMError.self) { try CreditBalance.parse(Data("[1]".utf8)) }
    }

    /// The balance is one GET with the key; a refused key says so, and a preset without a balance
    /// address sends nothing.
    @Test func aBalanceIsOneRequestWithTheKey() async throws {
        let transport = FakeTransport([
            FakeTransport.Reply(
                body: Data(#"{"included":{"balance_usd":1,"allowance_usd":2.5},"purchased":{"balance_usd":0}}"#.utf8)),
            FakeTransport.Reply(status: 401, body: Data(#"{"error":"invalid credentials"}"#.utf8)),
        ])
        let cloud = OpenAICompatibleProvider(preset: .ollamaCloud, key: "secret-key", transport: transport)
        #expect(try await cloud.balance().included == 1)
        await #expect(throws: LLMError.keyRejected(provider: "Ollama Cloud")) { try await cloud.balance() }
        let sent = try #require(transport.sent.first)
        #expect(sent.url?.absoluteString == "https://ollama.com/api/balance" && sent.httpMethod == "GET")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        let gemini = OpenAICompatibleProvider(preset: .gemini, key: "k", transport: transport)
        await #expect(throws: LLMError.self) { try await gemini.balance() }
        #expect(transport.sent.count == 2)
    }

    /// How far the Free plan's $2.50 a month goes on a model it has: gemma4:31b about 480 resumes.
    @Test func theFreePlanSaysHowManyResumesItCovers() {
        #expect(
            ModelGuide.entry(for: "gemma4:31b")?.freePlanLine == "about 480 resumes a month on the Free plan's $2.50")
        #expect(
            ModelGuide.entry(for: "gpt-oss:120b")?.freePlanLine == "about 370 resumes a month on the Free plan's $2.50")
        #expect(ModelGuide.entry(for: "deepseek-v4.1-flash")?.freePlanLine == nil)
        #expect(ProviderPreset.ollamaCloud.balanceURL == "https://ollama.com/api/balance")
        #expect(ProviderPreset.gemini.balanceURL == nil && ProviderPreset.gemini.quotaDayZone == "America/Los_Angeles")
    }
}
