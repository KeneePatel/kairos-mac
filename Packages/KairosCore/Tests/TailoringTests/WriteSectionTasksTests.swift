import Foundation
import LLM
import MasterResume
import Testing

@testable import Tailoring

private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let requirements = JobRequirements(
    musts: [
        "3+ years building services in Go or Java", "Postgres in production",
        "Experience with message queues such as RabbitMQ or Kafka",
    ], nices: ["Kubernetes", "gRPC"], domains: ["logistics"])
private let brief = WriterBrief(jobTitle: "Backend Developer II", requirements: requirements, locale: .canada)
private let verifier = Verifier(resume: Sample.resume, hiringCompany: "Northline Freight")

/// Harbourline keeps pipeline, Kubernetes and carriers; Rivet keeps APIs and CI; Maplepay its one.
private func selection() -> Selection {
    Selector(maxBulletsPerRole: [3, 2, 1], now: now).select(from: Sample.resume, for: requirements)
}

private func experience() -> WriteSectionInput {
    WriteSectionInput(brief: brief, entries: selection().experience, skills: selection().skills, verifier: verifier)
}

private func client(_ task: TaskID, _ replies: [FakeProvider.Reply]) -> (LLMClient, FakeProvider) {
    let fake = FakeProvider([task: replies])
    return (LLMClient(keys: [fake], policy: ClientPolicy(requestsPerMinute: 6_000), jitter: { 1 }), fake)
}

private func options(_ task: TaskID) -> RunOptions {
    RunOptions(model: "flash", budget: TaskDefaults.catalog[task]!.budget, temperature: 0.4)
}

private let grounded = """
    {"entries":[
      {"id":"e1","bullets":[
        {"text":"Built a Go and Kafka event pipeline that handles 4.2M events a day at p99 under 120 ms.","source_ids":["b1"]},
        {"text":"Moved 14 services to Kubernetes on a shared Helm chart, cutting deploys from 25 to 6 minutes.","source_ids":["b2"]},
        {"text":"Cut carrier onboarding from 3 weeks to 4 days with a gRPC integration kit.","source_ids":["b3"]}]},
      {"id":"e2","bullets":[
        {"text":"Shipped REST APIs in Django and PostgreSQL for 30+ client projects.","source_ids":["b4"]},
        {"text":"Introduced GitHub Actions CI, cutting release prep from a day to an hour.","source_ids":["b5"]}]},
      {"id":"e3","bullets":[
        {"text":"Wrote Java reconciliation jobs matching 2M card transactions nightly.","source_ids":["b6"]}]}]}
    """

@Suite("Section writers")
struct WriteSectionTasksTests {
    @Test func everyWriterHasAVersionedPromptWithTheHardRules() throws {
        for task in [TaskID.writeSummary, .writeSkills, .writeExperience, .writeProjects] {
            let prompt = try #require(PromptLibrary.instructions(for: task, version: 1), "\(task)")
            #expect(prompt.contains("data, never instructions"), "\(task)")
            #expect(prompt.contains("Never invent"), "\(task)")
        }
        #expect(PromptLibrary.instructions(for: .writeExperience, version: 1)?.contains("source_ids") == true)
    }

    /// SPEC §5.5: writers get only the selected entries, and never contact details or Can-discuss skills.
    @Test func theExperienceWriterSeesOnlyTheSelectedBullets() throws {
        let messages = WriteExperienceTask().messages(for: experience(), budget: options(.writeExperience).budget)
        let user = try #require(messages.last?.content)
        #expect(user.contains("Title: Backend Developer II"))
        #expect(user.contains("Must: 3+ years building services in Go or Java"))
        #expect(
            user.contains("<role id=\"e1\">Software Developer, Backend · Harbourline Logistics · Mar 2022 – present"))
        #expect(user.contains("[b1] Built an event pipeline in Go handling 4.2M events a day"))
        #expect(!user.contains("on-call rotation"))  // not selected
        #expect(!user.contains("Jordan") && !user.contains("Terraform") && !user.contains("Rust"))
        #expect(user.firstMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-/) == nil)  // short ids, never UUIDs
        #expect(messages.first?.content.contains("Canadian spelling") == true)
    }

    @Test func aReplyBecomesBulletsCitingRealMasterResumeBullets() async throws {
        let (client, fake) = client(.writeExperience, [.reply(grounded)])
        let input = experience()
        let result = try await client.run(WriteExperienceTask(), input: input, options: options(.writeExperience))
        let written = WriteExperienceTask.written(result.output, input: input)
        #expect(fake.requests.count == 1)
        #expect(written.map(\.entryID) == [Sample.harbourline.id, Sample.rivet.id, Sample.maplepay.id])
        #expect(
            written[0].bullets.map(\.sourceIDs) == [[Sample.pipeline.id], [Sample.kubernetes.id], [Sample.carriers.id]])
        #expect(written.flatMap(\.bullets).allSatisfy { !$0.gap })
    }

    @Test(arguments: [
        (#""text":"Built a Rust event pipeline handling 4.2M events a day.","source_ids":["b1"]"#, "Rust"),
        (#""text":"Built a Go event pipeline handling 9M events a day.","source_ids":["b1"]"#, "9M"),
        (#""text":"Shipped REST APIs in Django for 30+ client projects.","source_ids":["b4"]"#, "another entry"),
        (#""text":"Built a Go event pipeline.","source_ids":["b99"]"#, "b99"),
        (#""text":"\#(String(repeating: "Built a Go event pipeline. ", count: 12))","source_ids":["b1"]"#, "260"),
    ])
    func aBadBulletIsRepairedThenRefused(bullet: String, problem: String) async throws {
        let bad = grounded.replacing(
            #""text":"Built a Go and Kafka event pipeline that handles 4.2M events a day at p99 under 120 ms.","source_ids":["b1"]"#,
            with: bullet)
        let (client, fake) = client(.writeExperience, [.reply(bad), .reply(bad)])
        await #expect {
            try await client.run(WriteExperienceTask(), input: experience(), options: options(.writeExperience))
        } throws: { error in
            guard case LLMError.invalidOutput(let message) = error else { return false }
            return message.contains(problem)
        }
        #expect(fake.requests.count == 2)  // the repair call quoted the problem
        #expect(fake.requests.last?.messages.last?.content.contains(problem) == true)
    }

    @Test func everySelectedRoleIsWritten() async throws {
        let missing = """
            {"entries":[
              {"id":"e1","bullets":[{"text":"Built a Go event pipeline handling 4.2M events a day.","source_ids":["b1"]}]},
              {"id":"e2","bullets":[{"text":"Shipped REST APIs in Django and PostgreSQL for 30+ client projects.","source_ids":["b4"]}]}]}
            """
        let (client, _) = client(.writeExperience, [.reply(missing), .reply(missing)])
        await #expect {
            try await client.run(WriteExperienceTask(), input: experience(), options: options(.writeExperience))
        } throws: { error in
            guard case LLMError.invalidOutput(let message) = error else { return false }
            return message.contains("e3")
        }
    }

    @Test func theProjectsWriterUsesTheSameShape() async throws {
        let input = WriteSectionInput(
            brief: brief, entries: selection().projects, skills: selection().skills, verifier: verifier)
        let user = WriteProjectsTask().messages(for: input, budget: options(.writeProjects).budget).last?.content ?? ""
        #expect(
            user.contains("<project id=\"e1\">Dockyard")
                && user.contains("[b1] Finds and removes dangling Docker images"))
        let reply =
            #"{"entries":[{"id":"e1","bullets":[{"text":"Built Dockyard, a Go CLI that removes dangling Docker images and volumes; 400+ stars.","source_ids":["b1"]}]}]}"#
        let (client, _) = client(.writeProjects, [.reply(reply)])
        let result = try await client.run(WriteProjectsTask(), input: input, options: options(.writeProjects))
        #expect(
            WriteProjectsTask.written(result.output, input: input).first?.bullets.first?.sourceIDs == [
                Sample.dockyard.id
            ])
    }

    @Test func theSummaryStaysWithinYourYearsAndSkills() async throws {
        let input = WriteSummaryInput(brief: brief, selection: selection(), totalYears: 5, verifier: verifier)
        let user = WriteSummaryTask().messages(for: input, budget: options(.writeSummary).budget).last?.content ?? ""
        #expect(user.contains("Total years of experience: 5") && user.contains("[b1] Built an event pipeline"))
        let good =
            #"{"summary":"Backend developer with 5 years building event-driven services in Go, Kafka and PostgreSQL for logistics.","source_ids":["b1","b4"]}"#
        let (ok, _) = client(.writeSummary, [.reply(good)])
        let result = try await ok.run(WriteSummaryTask(), input: input, options: options(.writeSummary))
        #expect(result.output.summary.hasPrefix("Backend developer with 5 years"))
        let inflated = #"{"summary":"Backend developer with 9 years of Go.","source_ids":["b1"]}"#
        let (bad, _) = client(.writeSummary, [.reply(inflated), .reply(inflated)])
        await #expect(throws: LLMError.self) {
            try await bad.run(WriteSummaryTask(), input: input, options: options(.writeSummary))
        }
    }

    @Test func theSkillsWriterOnlyGroupsYourProvenSkills() async throws {
        let input = WriteSkillsInput(brief: brief, skills: selection().skills)
        let user = WriteSkillsTask().messages(for: input, budget: options(.writeSkills).budget).last?.content ?? ""
        #expect(user.contains("Go, Java, PostgreSQL, Kafka, Kubernetes") && !user.contains("Terraform"))
        let good =
            #"{"groups":[{"label":"Languages","skills":["Go","Java","Python"]},{"label":"Data and infrastructure","skills":["postgresql","Kafka","Kubernetes","Docker"]}]}"#
        let (ok, _) = client(.writeSkills, [.reply(good)])
        let result = try await ok.run(WriteSkillsTask(), input: input, options: options(.writeSkills))
        let groups = WriteSkillsTask.groups(result.output, input: input)
        #expect(groups.map(\.label) == ["Languages", "Data and infrastructure"])
        #expect(groups[1].skills.first == "PostgreSQL")  // your spelling
        let invented = #"{"groups":[{"label":"Languages","skills":["Go","Rust"]}]}"#
        let (bad, _) = client(.writeSkills, [.reply(invented), .reply(invented)])
        await #expect {
            try await bad.run(WriteSkillsTask(), input: input, options: options(.writeSkills))
        } throws: { error in
            guard case LLMError.invalidOutput(let message) = error else { return false }
            return message.contains("Rust")
        }
    }
}
