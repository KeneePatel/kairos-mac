import CryptoKit
import Foundation
import LLM
import MasterResume
import Render
import Screening
import Store
import Tailoring

/// Why a build couldn't run, in words for the Build screen.
public enum BuildError: Error, Equatable, Sendable {
    case notFound
    case noAI
    case jobNotFound
    case notAnalysed
    case resumeNotReady([String])

    public var message: String {
        switch self {
        case .notFound: "This build is gone."
        case .noAI: "AI isn't set up yet. Add a key in Settings, AI providers."
        case .jobNotFound: "The job for this build is gone."
        case .notAnalysed: "This job hasn't been analysed yet. Run screening first."
        case .resumeNotReady(let missing): "Your master resume isn't ready: \(missing.joined(separator: " "))"
        }
    }
}

/// Builds resumes in the background, two at a time (SPEC §5.3). Each build runs the build loop,
/// renders the PDF with page fitting, saves it, and records the result. A build a crash or quit
/// left unfinished starts again with `resumeInterrupted()`; the writers' replies come back from the
/// AI result cache, so steps already done cost no calls.
public actor BuildQueue {
    public enum Event: Sendable, Equatable {
        case queued(UUID)
        case step(UUID, BuildStep)
        case finished(UUID, score: Double, pdf: URL)
        case failed(UUID, String)
    }

    public typealias Render = @Sendable (ResumeDocument) async throws -> RenderedPDF

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let db: Database
    private var router: LLMRouter?
    private let folder: URL
    private let workers: Int
    private let render: Render
    private var pending: [UUID] = []
    private var running: Set<UUID> = []

    /// `folder` is where PDFs go; `render` turns a document into a PDF (a `ResumeRenderer`).
    public init(db: Database, router: LLMRouter?, folder: URL, workers: Int = 2, render: @escaping Render) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.db = db
        self.router = router
        self.folder = folder
        self.workers = max(1, workers)
        self.render = render
    }

    /// The router later builds use, such as after you add an AI key.
    public func setRouter(_ router: LLMRouter?) {
        self.router = router
    }

    /// Records a build for `job` and starts it as soon as a worker is free.
    public func enqueue(job: JobID, mode: BuildMode = .strict) async throws -> UUID {
        let version = try await MasterResumeRepository(db).load().version
        let id = try await BuildRepository(db).create(job: job, mode: mode, masterVersion: version)
        pending.append(id)
        continuation.yield(.queued(id))
        startWorkers()
        return id
    }

    /// Queues again the builds left queued or running, oldest first. Returns their ids.
    @discardableResult
    public func resumeInterrupted() async throws -> [UUID] {
        let left = try await BuildRepository(db).builds(status: [.queued, .running]).map(\.id).filter {
            !pending.contains($0) && !running.contains($0)
        }
        pending += left
        for id in left { continuation.yield(.queued(id)) }
        startWorkers()
        return left
    }

    private func startWorkers() {
        while running.count < workers, !pending.isEmpty {
            let id = pending.removeFirst()
            running.insert(id)
            Task { await self.process(id) }
        }
    }

    private func process(_ id: UUID) async {
        let builds = BuildRepository(db)
        do {
            try await builds.start(id)
            let (outcome, pdf) = try await build(id)
            continuation.yield(.finished(id, score: outcome.score.total, pdf: pdf))
        } catch {
            let message = Self.message(for: error)
            try? await builds.fail(id, error: message)
            continuation.yield(.failed(id, message))
        }
        running.remove(id)
        startWorkers()
    }

    private func build(_ id: UUID) async throws -> (BuildOutcome, URL) {
        let builds = BuildRepository(db)
        guard let record = try await builds.build(id) else { throw BuildError.notFound }
        guard let router else { throw BuildError.noAI }
        guard let job = try await JobRepository(db).job(JobID(rawValue: record.jobID)) else {
            throw BuildError.jobNotFound
        }
        guard
            let analysis = try await AnalysisRepository(db).analysis(
                for: job.id, promptVersion: AnalyzeJobTask.promptVersion)?.analysis
        else { throw BuildError.notAnalysed }
        let master = try await MasterResumeRepository(db).load()
        let readiness = Validator.readiness(master, now: YearMonth.containing(Date()))
        guard readiness.isReady else { throw BuildError.resumeNotReady(readiness.missing.map(\.message)) }

        let request = BuildRequest(
            jobTitle: job.title, company: job.company,
            requirements: JobRequirements(
                musts: analysis.requirements.filter { $0.kind == .must }.map(\.text),
                nices: analysis.requirements.filter { $0.kind == .nice }.map(\.text), domains: analysis.domains),
            locale: SpellingLocale(country: job.country), mode: record.mode)
        let loop = BuildLoop(
            router: router, master: master, context: CallContext(jobID: job.id.rawValue, buildID: id.lowercased))
        let render = self.render
        let continuation = self.continuation
        let outcome = try await loop.run(
            request, measure: { try await render(ResumeDocument($0)).pageCount },
            progress: { continuation.yield(.step(id, $0)) })

        let pdf = try await render(ResumeDocument(outcome.resume))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(id.lowercased).pdf")
        try pdf.data.write(to: url)
        let sha256 = SHA256.hash(data: pdf.data).map { String(format: "%02x", $0) }.joined()
        _ = try await builds.addArtifact(build: id, kind: "resume", sha256: sha256, localPath: url.path)
        try await builds.finish(id, content: outcome.resume, score: outcome.score, iterations: outcome.rewrites)
        return (outcome, url)
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let error as BuildError: return error.message
        case LLMError.budgetReached:
            return "\(Budget.reachedMessage). Build again tomorrow, or raise the budget in Settings."
        case LLMError.noProvider, LLMError.noKey: return BuildError.noAI.message
        case LLMError.cancelled: return "Stopped."
        case let error as LLMError: return "The AI provider couldn't finish this build (\(error.code)). Try again."
        case let error as RenderError: return "The PDF couldn't be made: \(error)"
        default: return "This build failed: \(error.localizedDescription)"
        }
    }
}
