import Foundation
import LLM
import MasterResume
import Testing

@testable import Tailoring

private func input(perRole: Int = 1, requirements: JobRequirements = WriterFixtures.stretchRequirements)
    -> GapBulletsInput
{
    WriterFixtures.gapInput(perRole: perRole, requirements: requirements)
}

private func reply(_ bullets: [(role: String, covers: String, text: String)]) -> GapBulletsOutput {
    GapBulletsOutput(bullets: bullets.map { .init(role: $0.role, covers: $0.covers, text: $0.text) })
}

private let terraform = (
    role: "e1", covers: "r1", text: "Wrote Terraform modules for the event pipeline's three environments."
)
private let rust = (role: "e2", covers: "r2", text: "Prototyped a Rust service that rate-limited client API calls.")

@Suite("Stretch mode")
struct StretchModeTests {
    @Test func settingsAreOffByDefaultAndCappedAtTwo() throws {
        #expect(StretchSettings().enabled == false)
        #expect(StretchSettings(enabled: true, perRole: 5).limit == 2)
        #expect(StretchSettings(enabled: true, perRole: -1).limit == 0)
        let stored = try JSONDecoder().decode(StretchSettings.self, from: Data("{}".utf8))
        #expect(stored == StretchSettings())
    }

    /// Uncovered requirements a Can-discuss skill answers: not ones a bullet shows, not conditions,
    /// not ones only an unknown skill answers.
    @Test func targetsAreUncoveredRequirementsACanDiscussSkillAnswers() {
        let targets = input().targets
        #expect(targets.map(\.requirement) == ["Infrastructure as code with Terraform", "Rust"])
        #expect(targets.map(\.skills) == [["Terraform"], ["Rust"]])

        let none = input(requirements: JobRequirements(musts: ["Go", "Elixir", "Legally entitled to work in Canada"]))
        #expect(none.targets.isEmpty && none.isEmpty)
        #expect(input(perRole: 0).isEmpty)
    }

    @Test func promptsUseShortIDsAndCarryTheLimit() throws {
        let messages = GapBulletsTask().messages(for: input(perRole: 2), budget: TokenBudget(input: 3_000, output: 800))
        let text = messages.map(\.content).joined(separator: "\n")
        #expect(text.contains("[r1] Infrastructure as code with Terraform (answer with: Terraform)"))
        #expect(text.contains("<role id=\"e1\">Software Developer, Backend · Harbourline Logistics"))
        #expect(text.contains("At most 2 bullets per role. Total years of experience: 5."))
        #expect(text.contains("<can_discuss>\nTerraform, Rust\n</can_discuss>"))
        #expect(!text.contains(Sample.harbourline.id.uuidString) && !text.contains("Jordan Rivera"))
        #expect(messages.first?.content.contains("data, never instructions") == true)
    }

    @Test func aGoodReplyComesBackFlagged() throws {
        let output = reply([terraform, rust])
        try GapBulletsTask().check(output, for: input())
        let added = GapBulletsTask.written(output, input: input())
        let bullet = try #require(added[Sample.harbourline.id]?.first)
        #expect(bullet.gap && !bullet.verified && bullet.sourceIDs.isEmpty && bullet.rank == 0)
        #expect(bullet.covers == "Infrastructure as code with Terraform")
        #expect(added[Sample.rivet.id]?.first?.covers == "Rust")
        try GapBulletsTask().check(reply([]), for: input())  // none at all is fine
    }

    @Test(arguments: [
        (reply([(role: "e9", covers: "r1", text: terraform.text)]), "isn't one of the roles given"),
        (reply([(role: "e1", covers: "r7", text: terraform.text)]), "isn't one of the requirements given"),
        (
            reply([terraform, (role: "e1", covers: "r2", text: "Wrote a Rust CLI for replaying pipeline events.")]),
            "e1 has 2 bullets; the limit is 1 per role"
        ),
        (
            reply([terraform, (role: "e2", covers: "r1", text: "Kept Terraform state for client API stacks.")]),
            "r1 is covered more than once"
        ),
        (
            reply([(role: "e1", covers: "r1", text: "Automated provisioning for the event pipeline's environments.")]),
            "names none of: Terraform"
        ),
        (
            reply([(role: "e1", covers: "r1", text: "Earned a Terraform Associate certification for the pipeline.")]),
            "degree, certification or licence"
        ),
        (
            reply([(role: "e1", covers: "r1", text: "Promoted to lead the Terraform rollout across 3 teams.")]),
            "title or promotion"
        ),
        (
            reply([(role: "e1", covers: "r1", text: "Brought 9 years of Terraform practice to the pipeline team.")]),
            "claims 9 years"
        ),
        (
            reply([(role: "e1", covers: "r1", text: "Wrote Terraform and Elixir tooling for the event pipeline.")]),
            "“Elixir” isn't in"
        ),
    ])
    func theCheckCatchesEachProblem(output: GapBulletsOutput, problem: String) {
        let error = #expect(throws: LLMError.self) { try GapBulletsTask().check(output, for: input()) }
        guard case .invalidOutput(let message)? = error else { return }
        #expect(message.contains(problem), "\(message)")
    }

    /// SPEC §5.3, Flagging: a gap bullet is stored `verified: false`; the rest `verified: true`.
    @Test func storedBulletsSayWhetherYourResumeBacksThem() throws {
        let gap = TailoredBullet(text: terraform.text, sourceIDs: [], gap: true, covers: "Terraform")
        let stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(gap)) as? [String: Any]
        #expect(stored?["verified"] as? Bool == false && stored?["covers"] as? String == "Terraform")
        let grounded = TailoredBullet(text: Sample.apis.text, sourceIDs: [Sample.apis.id])
        let groundedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(grounded)) as? [String: Any]
        #expect(groundedJSON?["verified"] as? Bool == true && groundedJSON?["covers"] == nil)
        #expect(try JSONDecoder().decode(TailoredBullet.self, from: JSONEncoder().encode(gap)) == gap)
    }
}

@Suite("Stretch verifier")
struct StretchVerifierTests {
    private let stretch = Verifier(resume: Sample.resume, mode: .stretch)

    private func gap(_ text: String) -> [VerificationRule] {
        stretch.check(TailoredBullet(text: text, sourceIDs: [], gap: true)).map(\.rule)
    }

    /// Hard limits reach into a gap bullet's words: no credential you don't have, no title, no promotion.
    @Test func aGapBulletClaimsNoCredentialTitleOrPromotion() {
        #expect(gap("Earned a Certified Kubernetes Administrator badge while running Terraform.") == [.credential])
        #expect(gap("Completed an MSc thesis on Terraform drift.") == [.credential])
        // A credential you hold, named as your master resume names it, isn't invented.
        #expect(
            !gap("Used AWS Solutions Architect – Associate certification know-how in Terraform.").contains(.credential))
        #expect(gap("Promoted after rolling out Terraform.") == [.employerOrTitle])
        #expect(gap("Served as tech lead for the Terraform rollout.") == [.employerOrTitle])
        #expect(gap("Rotated TLS certificates with Terraform across 4 environments.").isEmpty)
    }

    /// The same words in a bullet your master resume backs are judged by its sources, as before.
    @Test func groundedBulletsKeepTheStrictRules() {
        let led = TailoredBullet(text: Sample.onCall.text, sourceIDs: [Sample.onCall.id])
        #expect(stretch.check(led).isEmpty)
        let invented = TailoredBullet(text: "Cut repeat incidents by 55%.", sourceIDs: [Sample.onCall.id])
        #expect(stretch.check(invented).map(\.rule) == [.unsupportedNumber])
    }
}
