import CryptoKit
import Foundation
import LLM
import MasterResume
import Render
import Screening
import Store
import Synchronization
import Tailoring
import os

/// Why a build couldn't run, in words for the Build screen.
public enum BuildError: Error, Equatable, Sendable {
    case notFound
    case noAI
    case jobNotFound
    case notAnalysed
    case resumeNotReady([String])
    case stretchOff
    case tookTooLong(Duration)

    public var message: String {
        switch self {
        case .notFound: "This build is gone."
        case .noAI: "AI isn't set up yet. Add a key in Settings, AI providers."
        case .jobNotFound: "The job for this build is gone."
        case .notAnalysed: "This job hasn't been analysed yet. Run screening first."
        case .resumeNotReady(let missing): "Your master resume isn't ready: \(missing.joined(separator: " "))"
        case .stretchOff: "Stretch mode is off. Turn it on in Settings, General, or build in Full mode."
        case .tookTooLong(let limit):
            "This build ran for more than \(limit.formatted(.units(allowed: [.minutes, .seconds], width: .wide))) "
                + "and was stopped. Build again to retry."
        }
    }
}

/// Builds resumes in the background, two at a time (SPEC §5.3). Each build runs the build loop,
/// renders the PDF with page fitting, saves it, and records the result. A build a crash or quit
/// left unfinished starts again with `resumeInterrupted()`; the writers' replies come back from the
/// AI result cache, so steps already done cost no calls. A build that runs past `maxDuration` is
/// stopped and failed, so none sits "running" forever and holds a worker.
public actor BuildQueue {
    public enum Event: Sendable, Equatable {
        case queued(UUID)
        case step(UUID, BuildStep)
        case finished(UUID, score: Double, pdf: URL)
        case failed(UUID, String)
    }

    /// Prints a resume or a cover letter (a `ResumeRenderer`).
    public typealias Render = @Sendable (Printable) async throws -> RenderedPDF

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let db: Database
    private var router: LLMRouter?
    private let folder: URL
    private let workers: Int
    private let render: Render
    private let maxDuration: Duration
    private let template: ResumeTemplate
    private let log = Logger(subsystem: "com.keneepatel.kairos", category: "builds")
    private var pending: [UUID] = []
    private var running: Set<UUID> = []

    /// `folder` is where PDFs go; `render` turns a document into a PDF (a `ResumeRenderer`). A build
    /// normally takes a minute or two; `maxDuration` is the most one may take. `template` lays the
    /// resume out and decides whether a summary is written; the app passes `.standard`.
    public init(
        db: Database, router: LLMRouter?, folder: URL, workers: Int = 2, maxDuration: Duration = .seconds(15 * 60),
        template: ResumeTemplate = .classic, render: @escaping Render
    ) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.db = db
        self.router = router
        self.folder = folder
        self.workers = max(1, workers)
        self.render = render
        self.maxDuration = maxDuration
        self.template = template
    }

    /// The router later builds use, such as after you add an AI key.
    public func setRouter(_ router: LLMRouter?) {
        self.router = router
    }

    /// Records a build for `job` and starts it as soon as a worker is free.
    public func enqueue(job: JobID, mode: BuildMode = .strict, coverLetter: Bool = false) async throws -> UUID {
        let version = try await MasterResumeRepository(db).load().version
        let id = try await BuildRepository(db).create(
            job: job, mode: mode, masterVersion: version, coverLetter: coverLetter)
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
        let started = ContinuousClock.now
        log.info("build \(id.lowercased, privacy: .public) started")
        do {
            try await builds.start(id)
            let (outcome, pdf) = try await Self.within(maxDuration) { try await self.build(id) }
            log.info(
                "build \(id.lowercased, privacy: .public) finished in \(ContinuousClock.now - started, privacy: .public)"
            )
            continuation.yield(.finished(id, score: outcome.score.total, pdf: pdf))
        } catch {
            let message = Self.message(for: error)
            log.error(
                "build \(id.lowercased, privacy: .public) failed after \(ContinuousClock.now - started, privacy: .public): \(message, privacy: .public)"
            )
            try? await builds.fail(id, error: message)
            continuation.yield(.failed(id, message))
        }
        running.remove(id)
        startWorkers()
    }

    /// Runs `work`, or gives up after `limit` and cancels it. Unlike a task group, it never waits
    /// for work that ignores cancellation: a stuck step can't keep its build running.
    static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws
        -> T
    {
        try await withCheckedThrowingContinuation { continuation in
            let race = Race(continuation)
            race.hold(
                Task {
                    do {
                        race.end(.success(try await work()))
                    } catch {
                        race.end(.failure(error))
                    }
                },
                Task {
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
                    race.end(.failure(BuildError.tookTooLong(limit)))
                })
        }
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
        let stretch =
            try await SettingsRepository(db).value(StretchSettings.storageKey, as: StretchSettings.self)
            ?? StretchSettings()
        // Stretch is opt-in: a stretch build waiting from before you turned it off doesn't run.
        if record.mode == .stretch, !stretch.enabled { throw BuildError.stretchOff }

        let request = BuildRequest(
            jobTitle: job.title, company: job.company,
            requirements: JobRequirements(
                musts: analysis.requirements.filter { $0.kind == .must }.map(\.text),
                nices: analysis.requirements.filter { $0.kind == .nice }.map(\.text), domains: analysis.domains),
            locale: SpellingLocale(country: job.country), mode: record.mode, gapBulletsPerRole: stretch.limit,
            coverLetter: record.coverLetter != nil, summary: self.template.hasSummary)
        let loop = BuildLoop(
            router: router, master: master, context: CallContext(jobID: job.id.rawValue, buildID: id.lowercased))
        let render = self.render
        let continuation = self.continuation
        let template = self.template
        let outcome = try await loop.run(
            request, measure: { try await render(.resume(ResumeDocument($0, for: template))).pageLayout },
            progress: { step in
                // A build stopped at its deadline reports nothing more.
                if !Task.isCancelled { continuation.yield(.step(id, step)) }
            })

        let url = try await save(
            .resume(ResumeDocument(outcome.resume, for: template)), kind: "resume", name: id.lowercased, for: id)
        var letter: CoverLetterRecord?
        if request.coverLetter {
            letter = await coverLetter(outcome.coverLetter, for: id)
        }
        try Task.checkCancellation()  // stopped at its deadline: it stays failed
        try await builds.finish(
            id, content: outcome.resume, score: outcome.score, iterations: outcome.rewrites, coverLetter: letter)
        return (outcome, url)
    }

    /// The letter's PDF, or why there isn't one. A letter that can't be made never fails the build.
    private func coverLetter(_ letter: CoverLetter?, for id: UUID) async -> CoverLetterRecord {
        guard let letter else {
            return CoverLetterRecord(
                status: .failed,
                error: "The cover letter didn't pass its checks after a second try, so it was left out. "
                    + "Build again to retry."
            )
        }
        do {
            _ = try await save(
                .letter(LetterDocument(letter)), kind: "cover_letter", name: "\(id.lowercased)-cover-letter", for: id)
            return CoverLetterRecord(status: .done, letter: letter)
        } catch {
            return CoverLetterRecord(status: .failed, letter: letter, error: Self.message(for: error))
        }
    }

    /// Renders, writes `<name>.pdf` to the builds folder, and records it with its sha256.
    private func save(_ printable: Printable, kind: String, name: String, for id: UUID) async throws -> URL {
        let pdf = try await render(printable)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).pdf")
        try pdf.data.write(to: url)
        let sha256 = SHA256.hash(data: pdf.data).map { String(format: "%02x", $0) }.joined()
        _ = try await BuildRepository(db).addArtifact(build: id, kind: kind, sha256: sha256, localPath: url.path)
        return url
    }

    static func message(for error: any Error) -> String {
        switch error {
        case let error as BuildError: return error.message
        case LLMError.budgetReached:
            return "\(Budget.reachedMessage). Build again tomorrow, or raise the budget in Settings."
        case LLMError.noProvider, LLMError.noKey: return BuildError.noAI.message
        case LLMError.cancelled: return "Stopped."
        case let error as LLMError: return "The AI provider couldn't finish this build (\(error.code)). Try again."
        case RenderError.timedOut: return "Making the PDF took too long, so it was stopped. Build again to retry."
        case RenderError.compile(let reason): return "The PDF couldn't be made: \(reason)"
        case RenderError.launch(let reason), RenderError.workspace(let reason):
            return "The PDF maker couldn't run (\(reason)). Build again to retry."
        default: return "This build failed: \(error.localizedDescription)"
        }
    }
}

/// A build and its deadline: the first to end resumes the waiting worker, once, and the other is
/// cancelled.
private final class Race<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        state = Mutex(State(continuation: continuation))
    }

    func hold(_ tasks: Task<Void, Never>...) {
        let ended = state.withLock { state in
            guard state.continuation != nil else { return true }
            state.tasks += tasks
            return false
        }
        if ended { for task in tasks { task.cancel() } }
    }

    func end(_ result: Result<T, any Error>) {
        let (continuation, tasks) = state.withLock { state in
            defer {
                state.continuation = nil
                state.tasks = []
            }
            return (state.continuation, state.tasks)
        }
        guard let continuation else { return }
        for task in tasks { task.cancel() }
        continuation.resume(with: result)
    }
}
