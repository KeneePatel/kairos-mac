import AI
import Foundation
import Jobs
import KairosKit
import Render
import Resume
import Screening
import Store
import Tailoring

/// Why a build couldn't run, in words for the build's pane.
public enum BuildError: Error, Equatable, Sendable {
    case gone
    case jobGone
    case noAI
    case noRenderer
    case resumeNotReady([String])
    case stretchOff
    case notAnalyzed(String)
    case tookTooLong(Duration)

    public var message: String {
        switch self {
        case .gone: "This build is gone."
        case .jobGone: "The job for this build is gone."
        case .noAI: "AI isn't set up yet. Add a key in Settings, AI."
        case .noRenderer: "The PDF maker (typst) is missing from this copy of Kairos."
        case .resumeNotReady(let missing): "Your master resume isn't ready: \(missing.joined(separator: " "))"
        case .stretchOff: "Stretch mode is off. Turn it on in Settings, or build a tailored resume instead."
        case .notAnalyzed(let reason): "The posting couldn't be analysed: \(reason)"
        case .tookTooLong(let limit):
            "This build ran for more than \(Int(limit.components.seconds / 60)) minutes and was stopped. Build again to retry."
        }
    }
}

/// Builds tailored resumes in the background, two at a time. The queue lives in the database: a
/// build is queued, then running, then done, failed or stopped, and one left running by a quit
/// goes back in the queue at launch (the writers' replies come back from the AI cache, so steps
/// already done cost nothing). Each build has a deadline, so none holds a worker forever.
public actor BuildQueue {
    public enum Event: Sendable, Equatable {
        case queued(UUID)
        case started(UUID)
        case step(UUID, BuildStep)
        /// A model call starting, retrying, failing over or answering.
        case call(UUID, AIEvent)
        case finished(UUID)
        case failed(UUID, String)
        case stopped(UUID)
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let store: KairosStore
    private var router: AIRouter?
    private let folder: DataFolder
    private let renderer: ResumeRenderer?
    private let workers: Int
    private let deadline: Duration
    private let clock: any WallClock
    private var running: [UUID: Task<Void, Never>] = [:]

    public init(
        store: KairosStore, router: AIRouter?, folder: DataFolder, renderer: ResumeRenderer?, workers: Int = 2,
        deadline: Duration = .seconds(15 * 60), clock: any WallClock = SystemWallClock()
    ) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.store = store
        self.router = router
        self.folder = folder
        self.renderer = renderer
        self.workers = max(1, workers)
        self.deadline = deadline
        self.clock = clock
    }

    /// The router later builds use: after you add an AI key, say.
    public func setRouter(_ router: AIRouter?) {
        self.router = router
    }

    /// Queues a build for a job and starts it when a worker is free.
    @discardableResult
    public func enqueue(jobID: String, mode: BuildMode = .strict, letter: Bool = false) async throws -> BuildRecord {
        let build = BuildRecord(
            jobID: jobID, mode: mode, resumeVersion: try await store.resume.version(), wantsLetter: letter,
            createdAt: clock.now)
        try await store.builds.save(build)
        continuation.yield(.queued(build.id))
        await pump()
        return build
    }

    /// Puts builds a quit left running back in the queue and starts the queue: call at launch.
    public func resume() async throws {
        try await store.builds.requeueInterrupted()
        await pump()
    }

    /// Stops a queued or running build.
    public func stop(_ id: UUID) async throws {
        guard try await store.builds.stop(id, at: clock.now) else { return }
        running[id]?.cancel()
        continuation.yield(.stopped(id))
    }

    /// Waits until no build is running: for the CLI and tests.
    public func idle() async {
        while let task = running.values.first { await task.value }
    }

    // MARK: - Running

    private func pump() async {
        while running.count < workers {
            guard let next = try? await store.builds.nextQueued(), running[next.id] == nil,
                (try? await store.builds.start(next.id, at: clock.now)) == true
            else { return }
            continuation.yield(.started(next.id))
            running[next.id] = Task { await self.process(next.id) }
        }
    }

    private func process(_ id: UUID) async {
        let started = ContinuousClock.now
        Self.log.info("build \(id.lowercased, privacy: .public) started")
        do {
            let deadline = self.deadline
            let build = try await Deadline.run(deadline, failing: BuildError.tookTooLong(deadline)) {
                try await self.build(id)
            }
            if try await save(build) { continuation.yield(.finished(id)) }
            Self.log.info(
                "build \(id.lowercased, privacy: .public) finished in \(ContinuousClock.now - started, privacy: .public)"
            )
        } catch {
            let message = Self.message(for: error)
            // The reason is Kairos's own words, never a prompt, a reply or a key.
            Self.log.error(
                "build \(id.lowercased, privacy: .public) ended after \(ContinuousClock.now - started, privacy: .public): \(message, privacy: .public)"
            )
            if var build = try? await store.builds.build(id), build.status == .running {
                build.status = .failed
                build.error = message
                build.finishedAt = clock.now
                try? await store.builds.save(build)
                continuation.yield(.failed(id, message))
            }
        }
        running[id] = nil
        await pump()
    }

    /// Writes a finished build back, unless it was stopped meanwhile. Returns whether it was saved.
    private func save(_ build: BuildRecord) async throws -> Bool {
        guard try await store.builds.build(build.id)?.status == .running else { return false }
        try await store.builds.save(build)
        return true
    }

    private func build(_ id: UUID) async throws -> BuildRecord {
        guard var record = try await store.builds.build(id) else { throw BuildError.gone }
        guard let job = try await store.jobs.job(record.jobID) else { throw BuildError.jobGone }
        guard let router else { throw BuildError.noAI }
        guard let renderer else { throw BuildError.noRenderer }
        let master = try await store.resume.load()
        let readiness = Validator.readiness(master, now: YearMonth.containing(clock.now))
        guard readiness.isReady else { throw BuildError.resumeNotReady(readiness.missing.map(\.message)) }
        let stretch = try await store.settings.stretch()
        // Stretch is opt-in: a stretch build queued before you turned it off doesn't run.
        if record.mode == .stretch, !stretch.enabled { throw BuildError.stretchOff }
        let pages = try await store.settings.pages()
        let analysis = try await analysis(of: job, router: router)

        let request = BuildRequest(
            jobTitle: job.title, company: job.company, requirements: JobRequirements(analysis),
            locale: SpellingLocale(country: job.country), mode: record.mode,
            twoPagesWhenNeeded: pages.twoPagesWhenNeeded, lineCharacters: ResumeDocument.lineCharacters,
            gapBulletsPerRole: stretch.limit, coverLetter: record.wantsLetter)
        let continuation = self.continuation
        let tailor = Tailor(
            router: router, master: master,
            context: AIContext(
                jobID: job.id, buildID: id.lowercased,
                events: { event in if !Task.isCancelled { continuation.yield(.call(id, event)) } }))
        let outcome = try await tailor.run(
            request, measure: { try await renderer.measure($0) },
            progress: { step in if !Task.isCancelled { continuation.yield(.step(id, step)) } })
        try Task.checkCancellation()

        let now = clock.now
        let name = Self.fileName(master.header.fullName)
        record.files = [
            try await write(
                try await renderer.render(ResumeDocument(outcome.resume, now: now), createdAt: now).data, kind: .resume,
                name: "\(name) - Resume.pdf", build: id)
        ]
        if record.wantsLetter {
            if let letter = outcome.coverLetter {
                do {
                    let pdf = try await renderer.render(letter: LetterDocument(letter), createdAt: now)
                    record.files.append(
                        try await write(pdf.data, kind: .letter, name: "\(name) - Cover Letter.pdf", build: id))
                    record.letter = letter
                } catch {
                    record.letterError = Self.message(for: error)
                }
            } else {
                record.letterError =
                    outcome.coverLetterProblem?.message ?? "The cover letter couldn't be written. Build again to retry."
            }
        }
        record.resume = outcome.resume
        record.score = outcome.score.total
        record.report = BuildNotes(
            report: BuildReport(outcome, master: master), score: outcome.score,
            fellBack: outcome.fellBack.map(\.rawValue), notes: readiness.warnings)
        record.status = .done
        record.finishedAt = clock.now
        return record
    }

    /// The job's stored analysis, or a new one: a build doesn't wait for screening.
    private func analysis(of job: Job, router: AIRouter) async throws -> JobAnalysis {
        if let stored = try await store.screening.analysis(for: job.id),
            stored.promptVersion == AnalyzeJobTask.promptVersion
        {
            return stored.analysis
        }
        let resume = try await store.resume.load()
        let input = AnalyzeJobTask.Input(job: job, profile: ScreeningProfile(resume))
        do {
            let result = try await router.run(AnalyzeJobTask(), input: input, context: AIContext(jobID: job.id))
            let analysis = JobAnalysis(result.output, input: input)
            try await store.screening.save(
                StoredAnalysis(
                    analysis: analysis, model: result.model.description, promptVersion: AnalyzeJobTask.promptVersion,
                    analyzedAt: clock.now), state: nil, for: job.id)
            return analysis
        } catch {
            throw BuildError.notAnalyzed(Self.message(for: error))
        }
    }

    /// Writes a PDF into the build's own folder and returns its record.
    private func write(_ data: Data, kind: BuildRecord.File.Kind, name: String, build: UUID) async throws
        -> BuildRecord.File
    {
        let directory = folder.builds.appending(path: build.lowercased, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url, options: .atomic)
        return BuildRecord.File(kind: kind, path: folder.relative(url), sha256: StableID.sha256(data))
    }

    /// Your name as a file name: what a recruiter sees when you upload it.
    static func fileName(_ fullName: String) -> String {
        let cleaned = fullName.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Kairos" : String(cleaned.prefix(80))
    }

    static let log = Log.logger("builds")

    static func message(for error: any Error) -> String {
        switch error {
        case let error as BuildError: return error.message
        case AIError.budgetReached: return "Today's AI budget is spent. Build again tomorrow, or raise it in Settings."
        case AIError.noModel, AIError.noKey: return BuildError.noAI.message
        case AIError.cancelled, is CancellationError: return "Stopped."
        case let error as AIError:
            return "The build stopped because the AI model \(error.reason), and no other model was set to take over. "
                + "Build again, or add a fallback model in Settings, AI."
        case let error as RenderError: return "\(error.message) Build again to retry."
        default: return "This build failed: \(error.localizedDescription)"
        }
    }
}

/// Runs work against a deadline. Unlike a task group, it never waits for work that ignores
/// cancellation, so a stuck step can't keep a build running.
enum Deadline {
    static func run<T: Sendable>(
        _ limit: Duration, failing error: any Error & Sendable, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    continuation,
                    Task {
                        do {
                            race.end(.success(try await work()))
                        } catch {
                            race.end(.failure(error))
                        }
                    },
                    Task {
                        guard (try? await Task.sleep(for: limit)) != nil else { return }
                        race.end(.failure(error))
                    })
            }
        } onCancel: {
            race.end(.failure(CancellationError()))
        }
    }

    /// The first to end resumes the caller, once, and the rest are cancelled.
    final class Race<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, any Error>?
            var tasks: [Task<Void, Never>] = []
            var ended: Result<T, any Error>?
        }

        private let state = Locked(State())

        func start(_ continuation: CheckedContinuation<T, any Error>, _ tasks: Task<Void, Never>...) {
            let ended = state.withLock { state -> Result<T, any Error>? in
                if let ended = state.ended { return ended }
                state.continuation = continuation
                state.tasks = tasks
                return nil
            }
            if let ended {
                for task in tasks { task.cancel() }
                continuation.resume(with: ended)
            }
        }

        func end(_ result: Result<T, any Error>) {
            let (continuation, tasks) = state.withLock {
                state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
                guard state.ended == nil else { return (nil, []) }
                state.ended = result
                defer {
                    state.continuation = nil
                    state.tasks = []
                }
                return (state.continuation, state.tasks)
            }
            for task in tasks { task.cancel() }
            continuation?.resume(with: result)
        }
    }
}
