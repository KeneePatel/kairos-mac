import AI
import Foundation
import KairosKit
import Resume
import Screening
import TestKit
import Testing

@testable import Tailoring

private let backend = JobRequirements(
    musts: ["Go", "Kafka or another message queue", "PostgreSQL"], nices: ["Kubernetes"], domains: ["logistics"])

private let fixedNow = isoDate("2026-10-28T12:00:00Z")

@Suite("Selection and polish")
struct SelectionTests {
    @Test func bulletsThatAnswerTheJobRankFirstAndRecentRolesLead() {
        let selection = Selector(now: fixedNow).select(from: Sample.resume, for: backend)
        #expect(selection.experience.map(\.entry.id) == [Sample.id(1), Sample.id(2)])
        let first = selection.experience[0].bullets
        #expect(first.first?.bullet.id == Sample.id(11))  // Go and Kafka
        #expect(first.first?.matched == ["go", "kafka"])
        #expect(selection.skills.prefix(3).map(\.name) == ["Go", "Kafka", "PostgreSQL"])
        #expect(!selection.skills.contains { $0.level == .canDiscuss })
    }

    @Test func termsComeThroughSynonymsAndConcepts() {
        #expect(Keywords.isLoaded)
        #expect(Keywords.technologies(in: "Postgres and k8s on Google Cloud") == ["postgresql", "kubernetes", "gcp"])
        #expect(Keywords.technologies(in: "Deployed on GKE and EKS") == ["kubernetes"])  // managed Kubernetes counts
        #expect(Keywords.technologies(in: "We go live weekly").isEmpty)  // "go" only as "Go"
        #expect(Keywords.terms(in: "message queues").contains("kafka"))
        #expect(TechVocabulary.technologies(in: "Golang services").map(\.canonical) == ["go"])
    }

    @Test func polishRewritesBuzzwordsVariesVerbsAndSpellsForTheCountry() {
        let canada = Polish(locale: .canada)
        let bullets = canada.bullets([
            "Leveraged Go to optimize the color pipeline", "built a dashboard", "Built the API",
        ])
        #expect(bullets[0] == "Used Go to optimize the colour pipeline.")
        #expect(bullets[1].hasPrefix("Built") && bullets[2].hasPrefix("Developed"))
        #expect(Polish(locale: .unitedStates).text("The colour centre") == "The color center")
        let long = String(repeating: "Shipped faster releases, ", count: 20)
        #expect(canada.bullets([long])[0].count <= Polish.maxBulletLength + 1)
        #expect(canada.bullets(bullets) == bullets)  // polishing twice changes nothing more
    }

    @Test func requirementsComeFromTheAnalysisSkillsAndExperienceOnly() {
        let analysis = JobAnalysis(
            requirements: [
                .init(text: "Go", kind: .must, category: .skill, match: .yes),
                .init(text: "Shipping backend services", kind: .must, category: .experience, match: .partial),
                .init(text: "Bachelor's in CS", kind: .must, category: .education, match: .yes),
                .init(text: "Fluent English", kind: .must, category: .language, match: .yes),
                .init(text: "AWS certification", kind: .nice, category: .education, match: .no),
                .init(text: "Kafka", kind: .nice, category: .skill, match: .no),
            ], domains: ["logistics"])
        let requirements = JobRequirements(analysis)
        #expect(requirements.musts == ["Go", "Shipping backend services"] && requirements.nices == ["Kafka"])
        #expect(requirements.asksForLanguages && requirements.certificationAsks == ["AWS certification"])
    }
}

@Suite("Writers' checks")
struct WriterCheckTests {
    static func experienceInput() -> WriteSectionInput {
        let selection = Selector(now: fixedNow).select(from: Sample.resume, for: backend)
        let brief = WriterBrief(jobTitle: "Backend Developer", requirements: backend, locale: .canada)
        return WriteSectionInput(
            brief: brief, entries: selection.experience, skills: selection.skills,
            verifier: Verifier(
                resume: Sample.resume, hiringCompany: "Northline Freight", companyProducts: ["FreightOS"]))
    }

    @Test func aWriterMayNotInventCiteAcrossRolesOrNameTheHiringCompany() {
        let input = Self.experienceInput()
        let reply = #"""
            {"entries":[
              {"id":"e1","bullets":[{"text":"Built a Rust pipeline handling 9M events a day","source_ids":["b1"]},
                                    {"text":"Integrated carriers with FreightOS","source_ids":["b2"]},
                                    {"text":"Wrote Go services","source_ids":["b4"]}]}
            ]}
            """#
        guard case .failure(let problem) = OutputCheck.output(from: reply, task: WriteExperienceTask(), input: input)
        else {
            Issue.record("the reply should fail")
            return
        }
        for found in ["Rust", "9M", "FreightOS", "belongs to another entry", "e2 is missing"] {
            #expect(problem.description.contains(found), "\(found) in \(problem)")
        }
    }

    @Test func messagesUseShortIDsNeverUUIDs() {
        let messages = WriteExperienceTask().messages(
            for: Self.experienceInput(), budget: TaskProfile.of(.writeExperience).budget)
        let data = messages[1].content
        #expect(data.contains("<role id=\"e1\">") && data.contains("[b1]") && data.contains("<layout>"))
        #expect(!data.contains(Sample.id(11).uuidString) && !data.contains(Sample.id(11).lowercased))
        #expect(messages[0].content.contains("Canadian spelling"))
    }

    @Test func skillsMayOnlyBeYourProvenOnes() {
        let input = WriteSkillsInput(
            brief: WriterBrief(jobTitle: "Dev", requirements: backend, locale: .canada), skills: Sample.resume.skills)
        guard
            case .failure = OutputCheck.output(
                from: #"{"groups":[{"label":"Languages","skills":["Go","Rust"]}]}"#, task: WriteSkillsTask(),
                input: input)
        else {
            Issue.record("Rust is Can discuss, not Proven")
            return
        }
        guard
            case .success(let output) = OutputCheck.output(
                from: #"{"groups":[{"label":"Languages","skills":["go","Python"]}]}"#, task: WriteSkillsTask(),
                input: input)
        else {
            Issue.record("proven skills in any case pass")
            return
        }
        #expect(
            WriteSkillsTask.groups(output, input: input) == [SkillGroup(label: "Languages", skills: ["Go", "Python"])])
    }

    @Test func aLetterLeavesGreetingsSignOffsAndContactsToCode() {
        let input = CoverLetterInput(
            brief: WriterBrief(jobTitle: "Backend Developer", requirements: backend, locale: .canada),
            company: "Northline Freight",
            entries: [], skills: [], totalYears: 5, verifier: Verifier(resume: Sample.resume))
        let body = String(repeating: "I build reliable services in Go and care about shipping them well. ", count: 6)
        let reply = #"{"paragraphs":["Dear team, \#(body)","\#(body)","Reach me at jordan@example.com. Sincerely"]}"#
        guard case .failure(let problem) = OutputCheck.output(from: reply, task: CoverLetterTask(), input: input) else {
            Issue.record("the letter should fail")
            return
        }
        #expect(problem.description.contains("greeting") && problem.description.contains("sign-off"))
        #expect(problem.description.contains("contact details"))
    }
}

@Suite("Building a resume")
struct TailorTests {
    static let experienceReply = #"""
        {"entries":[
          {"id":"e1","bullets":[{"text":"built an event pipeline in Go and Kafka","source_ids":["b1"]},{"text":"Built a gRPC integration kit for carriers","source_ids":["b2"]}]},
          {"id":"e2","bullets":[{"text":"Wrote a Python reconciliation job","source_ids":["b4"]}]}
        ]}
        """#
    static let projectsReply =
        #"{"entries":[{"id":"e1","bullets":[{"text":"Built a budgeting app in Swift","source_ids":["b1"]}]}]}"#
    static let skillsReply =
        #"{"groups":[{"label":"Languages","skills":["Go","Python","Swift"]},{"label":"Data","skills":["PostgreSQL","Kafka"]}]}"#

    static func request(_ mode: BuildMode = .strict, letter: Bool = false) -> BuildRequest {
        BuildRequest(
            jobTitle: "Backend Developer II", company: "Northline Freight", requirements: backend, locale: .canada,
            mode: mode,
            coverLetter: letter)
    }

    @Test func aBuildCitesYourBulletsAndPolishesThem() async throws {
        let chat = ScriptedChat([
            .writeExperience: [.json(Self.experienceReply)], .writeProjects: [.json(Self.projectsReply)],
            .writeSkills: [.json(Self.skillsReply)],
        ])
        let steps = Locked<[BuildStep]>([])
        let outcome = try await Tailor(
            router: scriptedRouter(chat), master: Sample.resume, selector: Selector(now: fixedNow)
        )
        .run(Self.request(), progress: { step in steps.withLock { $0.append(step) } })
        let resume = outcome.resume
        #expect(steps.value == [.selecting, .writing])
        #expect(
            resume.header.name == "Jordan Rivera" && resume.header.contact.first?.text == "jordan.rivera@example.com")
        #expect(resume.experience.map(\.title) == ["Software Developer, Backend", "Junior Developer"])
        let first = try #require(resume.experience.first?.bullets.first)
        #expect(first.text == "Built an event pipeline in Go and Kafka." && first.verified && first.rank > 0)
        #expect(first.sourceIDs == [Sample.id(11)])
        #expect(resume.experience[0].bullets[1].text.hasPrefix("Developed"))  // no two open on "Built"
        #expect(resume.skills.first == SkillGroup(label: "Languages", skills: ["Go", "Python", "Swift"]))
        #expect(resume.education.first?.title == "BMath, Computer Science, Dean's List")
        #expect(resume.certifications.isEmpty && resume.languages == nil)
        #expect(outcome.fellBack.isEmpty && outcome.score.total > 0)
        // No contact detail reached any prompt.
        for asked in chat.asked {
            let text = asked.request.messages.map(\.content).joined()
            #expect(!text.contains("Jordan") && !text.contains("example.com") && !text.contains("555"))
        }
        // The rewrite loop is gone: four writer calls at most.
        #expect(chat.asked.count == 3)
    }

    @Test func aWriterThatFailsFallsBackToYourWords() async throws {
        let chat = ScriptedChat([.writeProjects: [.json(Self.projectsReply)], .writeSkills: [.json(Self.skillsReply)]])
        chat.always(.writeExperience, .json(#"{"entries":[]}"#))
        let outcome = try await Tailor(
            router: scriptedRouter(chat), master: Sample.resume, selector: Selector(now: fixedNow)
        )
        .run(Self.request())
        #expect(outcome.fellBack == [.experience])
        let bullets = outcome.resume.experience[0].bullets.map(\.text)
        #expect(bullets.contains("Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms."))
    }

    @Test func liteModeCopiesYourBulletsWithoutWriterCalls() async throws {
        let chat = ScriptedChat([.writeSkills: [.json(Self.skillsReply)]])
        let outcome = try await Tailor(
            router: scriptedRouter(chat), master: Sample.resume, selector: Selector(now: fixedNow)
        )
        .run(Self.request(.lite))
        #expect(chat.asked.map(\.request.task) == [.writeSkills])
        #expect(
            outcome.resume.experience[0].bullets.allSatisfy {
                Sample.resume.bulletsByID[$0.sourceIDs[0]]?.bullet.text == $0.text
            })
    }

    @Test func aLetterIsWrittenOrLeftOutWithItsReason() async throws {
        let body = "I build reliable backend services in Go and Kafka, and I would bring that to Northline Freight. "
        let paragraphs = Array(repeating: String(repeating: body, count: 3), count: 3)
        let chat = ScriptedChat([
            .writeExperience: [.json(Self.experienceReply)], .writeProjects: [.json(Self.projectsReply)],
            .writeSkills: [.json(Self.skillsReply)], .coverLetter: [.json(try ["paragraphs": paragraphs].jsonText())],
        ])
        let outcome = try await Tailor(
            router: scriptedRouter(chat), master: Sample.resume, selector: Selector(now: fixedNow)
        )
        .run(Self.request(letter: true))
        let letter = try #require(outcome.coverLetter)
        #expect(letter.greeting == "Dear Northline Freight hiring team," && letter.signature == "Jordan Rivera")
        #expect(letter.paragraphs.count == 3 && letter.date == "October 28, 2026")

        let failing = ScriptedChat([
            .writeExperience: [.json(Self.experienceReply)], .writeProjects: [.json(Self.projectsReply)],
            .writeSkills: [.json(Self.skillsReply)],
        ])
        failing.always(.coverLetter, .error(.server(status: 503)))
        let without = try await Tailor(
            router: scriptedRouter(failing), master: Sample.resume, selector: Selector(now: fixedNow)
        )
        .run(Self.request(letter: true))
        #expect(without.coverLetter == nil && without.coverLetterProblem == .unavailable("was overloaded (503)"))
    }

    @Test func stoppingEndsTheBuild() async throws {
        let chat = ScriptedChat()
        chat.always(.writeExperience, .error(.cancelled))
        chat.always(.writeProjects, .json(Self.projectsReply))
        chat.always(.writeSkills, .json(Self.skillsReply))
        await #expect(throws: AIError.cancelled) {
            _ = try await Tailor(router: scriptedRouter(chat), master: Sample.resume).run(Self.request())
        }
    }

    @Test func theWholeMasterResumeExportsForPrinting() {
        let full = FullResume(Sample.resume)
        #expect(full.experience.count == 2 && full.projects.first?.url == "https://github.com/jrivera/ledger")
        #expect(full.skills.last == SkillGroup(label: FullResume.canDiscussLabel, skills: ["Terraform", "Rust"]))
        #expect(full.languages == "English (native), French (conversational)" && full.version == 12)
    }

    @Test func oldBuildsStillDecode() throws {
        let stored =
            #"{"header":{"name":"Jordan Rivera","contact":[{"text":"jordan@example.com","url":"mailto:jordan@example.com"}]},"skills":[{"label":"Languages","skills":["Go"]}],"experience":[{"entryID":"00000000-0000-7000-8000-000000000001","title":"Developer","bullets":[{"text":"Built X.","sourceIDs":["00000000-0000-7000-8000-000000000011"],"gap":false,"rank":2.25,"verified":true}]}],"projects":[],"education":[],"certifications":[]}"#
        let resume = try TailoredResume.fromJSON(stored)
        #expect(resume.experience[0].bullets[0].sourceIDs == [Sample.id(11)] && resume.experience[0].period == nil)
    }
}
