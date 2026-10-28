import AI
import Foundation
import Jobs
import KairosKit
import Render
import Resume
import Screening
import Store
import Tailoring
import TestKit
import Testing

@testable import Engine

@Suite("Build queue")
struct BuildQueueTests {
    let folder = DataFolder(
        root: FileManager.default.temporaryDirectory.appending(path: "kairos-builds-\(UUID().uuidString)"))

    /// A store with the sample resume and one Toronto job, analysed.
    func store() async throws -> (KairosStore, String) {
        let store = try await softwareStore()
        try await store.resume.replace(with: Sample.resume, reason: "Test", at: now)
        let board = try await store.sources.addByYou(
            Board(kind: .greenhouse, slug: "northline", name: "Northline"), at: now)
        let url = "https://job-boards.greenhouse.io/northline/jobs/1"
        _ = try await store.ledger.record(
            [
                Listing(
                    canonicalURL: url, url: url, company: "Northline Freight", title: "Backend Developer",
                    location: "Toronto, ON", city: "Toronto", region: "ON", country: .canada,
                    description: "Go, PostgreSQL and Kafka for freight.")
            ], from: board, complete: false, at: now)
        let id = try #require(try await store.jobs.summaries().first?.id)
        return (store, id)
    }

    /// Every writer fails: a build still finishes, in your own words.
    func failingWriters() throws -> ScriptedChat {
        let chat = ScriptedChat()
        chat.always(.analyzeJob, .json(try Fixtures.text("screening/analyzeJob-gemini-flash-lite-latest.json")))
        for task in [
            TaskID.writeExperience, .writeProjects, .writeSkills, .writeSummary, .shortenBullets, .gapBullets,
            .coverLetter,
        ] {
            chat.always(task, .error(.badRequest("scripted failure")))
        }
        return chat
    }

    @Test(.enabled(if: TypstBinary.url != nil)) func aBuildMakesItsPDFsEvenWhenEveryWriterFails() async throws {
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let (store, jobID) = try await store()
        let chat = try failingWriters()
        let queue = BuildQueue(
            store: store, router: scriptedRouter(chat), folder: folder,
            renderer: ResumeRenderer(typst: TypstBinary.url),
            clock: ManualWallClock(now))
        let queued = try await queue.enqueue(jobID: jobID, letter: true)
        #expect(queued.resumeVersion == 1)
        await queue.idle()

        let build = try #require(try await store.builds.build(queued.id))
        #expect(build.status == .done, "\(build.error ?? "")")
        #expect(build.resume?.experience.isEmpty == false)
        #expect(build.report?.fellBack.contains("experience") == true)
        #expect(build.letter == nil && build.letterError != nil)
        let file = try #require(build.file(.resume))
        #expect(file.path == "Library/Builds/\(queued.id.lowercased)/Jordan Rivera - Resume.pdf")
        let pdf = try Data(contentsOf: folder.file(file.path))
        #expect(pdf.starts(with: Data("%PDF".utf8)) && StableID.sha256(pdf) == file.sha256)
        // The build analysed the posting itself: screening hadn't.
        #expect(try await store.screening.analysis(for: jobID) != nil)
        #expect(try await store.jobs.summary(jobID)?.build?.status == .done)
    }

    @Test func aBuildThatCantRunFailsWithItsReason() async throws {
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let (store, jobID) = try await store()
        let noAI = BuildQueue(store: store, router: nil, folder: folder, renderer: nil, clock: ManualWallClock(now))
        let first = try await noAI.enqueue(jobID: jobID)
        await noAI.idle()
        #expect(try await store.builds.build(first.id)?.error == BuildError.noAI.message)

        let stretch = BuildQueue(
            store: store, router: scriptedRouter(try failingWriters()), folder: folder, renderer: nil,
            clock: ManualWallClock(now))
        let second = try await stretch.enqueue(jobID: jobID, mode: .stretch)
        await stretch.idle()
        let failed = try #require(try await store.builds.build(second.id))
        #expect(failed.status == .failed && failed.error == BuildError.noRenderer.message)
    }

    @Test func aStoppedBuildStaysStopped() async throws {
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let (store, jobID) = try await store()
        // A build queued while another holds the only worker, then stopped before it starts.
        let queue = BuildQueue(
            store: store, router: nil, folder: folder, renderer: nil, workers: 1, clock: ManualWallClock(now))
        let waiting = BuildRecord(jobID: jobID, mode: .strict, resumeVersion: 1, createdAt: now)
        try await store.builds.save(waiting)
        try await queue.stop(waiting.id)
        try await queue.resume()
        await queue.idle()
        #expect(try await store.builds.build(waiting.id)?.status == .stopped)
    }

    @Test func fileNamesAreYourNameMadeSafe() {
        #expect(BuildQueue.fileName("Jordan Rivera") == "Jordan Rivera")
        #expect(BuildQueue.fileName("  A/B: C  ") == "A B  C")
        #expect(BuildQueue.fileName("") == "Kairos")
    }
}
