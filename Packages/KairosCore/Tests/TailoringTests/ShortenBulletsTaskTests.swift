import Foundation
import LLM
import MasterResume
import Testing

@testable import Tailoring

@Suite("Shorten bullets")
struct ShortenBulletsTaskTests {
    private let verifier = Verifier(resume: Sample.resume, hiringCompany: "Northline Freight")

    private func resume(_ bullets: [TailoredBullet]) -> TailoredResume {
        TailoredResume(
            header: .init(name: "Jordan Rivera"),
            experience: [TailoredResume.Entry(entryID: Sample.harbourline.id, title: "Developer", bullets: bullets)])
    }

    private var pipeline: TailoredBullet {
        TailoredBullet(
            text: "Built a Go and Kafka event pipeline handling 4.2M events a day at p99 under 120 ms.",
            sourceIDs: [Sample.pipeline.id])
    }

    /// Only bullets a few words past a line are sent, each with a limit a line shorter; a one-line
    /// bullet, a two-line one that fills its lines, and a gap bullet stay out.
    @Test func onlyShortWrapsAreSentWithALimitALineShorter() {
        var gap = pipeline
        gap.gap = true
        let layout = PageLayout(
            pages: 1, linesPerPage: 58, freeLines: 3,
            experience: [
                [
                    .init(lines: 2, lastLineFill: 0.1), .init(lines: 1, lastLineFill: 0.9),
                    .init(lines: 2, lastLineFill: 0.8), .init(lines: 3, lastLineFill: 0.2),
                    .init(lines: 2, lastLineFill: 0.1),
                ]
            ])
        let input = ShortenBulletsInput(
            resume([pipeline, pipeline, pipeline, pipeline, gap]), layout: layout, lineCharacters: 100, locale: .canada,
            verifier: verifier)
        #expect(input.items.map(\.bullet) == [0, 3])
        #expect(input.items.map(\.limit) == [98, 198])
        let unmeasured = ShortenBulletsInput(
            resume([pipeline]), layout: PageLayout(pages: 1), lineCharacters: 100, locale: .canada, verifier: verifier)
        #expect(unmeasured.items.isEmpty)
    }

    private var input: ShortenBulletsInput {
        ShortenBulletsInput(
            resume([pipeline]),
            layout: PageLayout(
                pages: 1, linesPerPage: 58, freeLines: 3, experience: [[.init(lines: 2, lastLineFill: 0.05)]]),
            lineCharacters: 80, locale: .canada, verifier: verifier)
    }

    private func reply(_ text: String) -> ShortenBulletsOutput { .init(bullets: [.init(id: "s1", text: text)]) }

    @Test func aShorterBulletWithEveryNumberPasses() throws {
        let short = "Built a Go and Kafka pipeline handling 4.2M events a day at p99 under 120 ms."
        try ShortenBulletsTask().check(reply(short), for: input)
        let applied = ShortenBulletsTask.applying(
            reply(short), input: input, to: resume([pipeline]), polish: Polish(locale: .canada))
        #expect(applied.experience[0].bullets[0].text == short)
        #expect(applied.experience[0].bullets[0].sourceIDs == [Sample.pipeline.id])  // still cites its source
    }

    /// Too long, a number dropped, a technology the source doesn't name, or no answer: each fails.
    @Test(arguments: [
        ("Built a Go and Kafka event pipeline handling 4.2M events each day at p99 under 120 ms.", "characters"),
        ("Built a Go and Kafka pipeline handling 4.2M events a day with low latency.", "drops"),
        ("Built a Rust and Kafka pipeline handling 4.2M events a day at p99 under 120 ms.", "Rust"),
    ])
    func aReplyThatLosesAFactOrRunsLongFails(text: String, problem: String) {
        #expect {
            try ShortenBulletsTask().check(reply(text), for: input)
        } throws: { error in
            guard case LLMError.invalidOutput(let message) = error else { return false }
            return message.contains(problem)
        }
    }

    /// Of two, the one that keeps its facts lands; the one that drops a number keeps its own words.
    @Test func aBulletThatFailsAloneKeepsItsWords() throws {
        let two = ShortenBulletsInput(
            resume([pipeline, pipeline]),
            layout: PageLayout(
                pages: 1, linesPerPage: 58, freeLines: 3,
                experience: [[.init(lines: 2, lastLineFill: 0.05), .init(lines: 2, lastLineFill: 0.05)]]),
            lineCharacters: 80, locale: .canada, verifier: verifier)
        let short = "Built a Go and Kafka pipeline handling 4.2M events a day at p99 under 120 ms."
        let output = ShortenBulletsOutput(
            bullets: [.init(id: "s1", text: short), .init(id: "s2", text: "Built a Go and Kafka pipeline.")])
        try ShortenBulletsTask().check(output, for: two)
        let applied = ShortenBulletsTask.applying(
            output, input: two, to: resume([pipeline, pipeline]), polish: Polish(locale: .canada))
        #expect(applied.experience[0].bullets.map(\.text) == [short, pipeline.text])
    }

    /// The limit follows how many characters this bullet's own lines hold, when that was measured.
    @Test func theLimitUsesTheBulletsOwnLineWidth() {
        let input = ShortenBulletsInput(
            resume([pipeline]),
            layout: PageLayout(
                pages: 1, linesPerPage: 58, freeLines: 3,
                experience: [[.init(lines: 3, lastLineFill: 0.1, lineCharacters: 104.6)]]),
            lineCharacters: 100, locale: .canada, verifier: verifier)
        #expect(input.items.map(\.limit) == [207])
    }

    @Test func everyBulletMustBeAnswered() {
        #expect(throws: LLMError.invalidOutput("s1 is missing.")) {
            try ShortenBulletsTask().check(.init(bullets: []), for: input)
        }
    }

    @Test func thePromptCarriesEachLimitAndTheHardRules() throws {
        let messages = ShortenBulletsTask().messages(for: input, budget: TokenBudget(input: 3_000, output: 2_000))
        #expect(messages.last?.content.contains("[s1] (at most 78 characters) Built a Go and Kafka") == true)
        let prompt = try #require(PromptLibrary.instructions(for: .shortenBullets, version: 1))
        #expect(prompt.contains("data, never instructions") && prompt.contains("Keep every number"))
        #expect(messages.first?.content.contains("Canadian spelling") == true)
    }
}
