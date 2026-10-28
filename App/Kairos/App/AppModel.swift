import AI
import AppKit
import Engine
import Foundation
import Jobs
import KairosKit
import Observation
import Resume
import Screening
import Secrets
import Store
import Tailoring

/// The app's shared state: the open workspace, what the lists show, the run in progress and the
/// builds in flight. Screens keep their own local state (selection in a table, a form's draft);
/// everything they change goes through the store, then `reload()`.
@Observable @MainActor
final class AppModel {
    enum Phase: Equatable {
        case opening
        case ready
        case failed(String)
    }

    /// What Kairos is doing, for the status footer and the menu bar.
    enum Activity: Equatable {
        case idle
        case fetching(FetchProgress)
        case screening(ScreeningProgress)

        var isRunning: Bool { self != .idle }
    }

    /// An alert to show once.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// A decision ⌘Z puts back.
    struct Undo: Equatable {
        let jobID: String
        let decision: Job.Decision?
        let title: String
    }

    /// A build in flight: its last step and its model calls.
    struct LiveBuild: Equatable {
        var step: BuildStep?
        var calls: [AIEvent] = []
    }

    private(set) var phase = Phase.opening
    private(set) var workspace: Workspace?
    var section = AppSection.inbox
    var settingsPage = SettingsPage.general

    private(set) var jobs: [JobSummary] = []
    private(set) var builds: [BuildRecord] = []
    private(set) var applications: [Application] = []
    private(set) var sources: [Source] = []
    private(set) var preferences = SearchPreferences()
    private(set) var aiSettings = AISettings.defaults()
    private(set) var stretch = StretchSettings()
    private(set) var pages = PageSettings()
    private(set) var workProfile = WorkProfile()
    private(set) var resume = MasterResume()
    private(set) var counts = ScreeningRepository.Counts()
    private(set) var lastFetch: Run?
    private(set) var lastScreen: Run?
    private(set) var preparation: Workspace.Preparation?

    var selectedJob: String?
    var selectedBuild: UUID?
    var selectedApplication: UUID?
    var jobQuery = JobLists.Query()
    /// The job pane takes the whole window (Return), until Esc.
    var fullWidthJob = false

    private(set) var activity = Activity.idle
    private(set) var liveBuilds: [UUID: LiveBuild] = [:]
    var notice: Notice?
    private(set) var undo: Undo?
    /// When you last looked at the Inbox, for "new since you looked" in the menu bar.
    private(set) var lookedAt = Date()

    private var runTask: Task<Void, Never>?
    private var buildEvents: Task<Void, Never>?

    init() {}

    /// A model over an existing workspace: previews and snapshots.
    init(workspace: Workspace) {
        self.workspace = workspace
        phase = .ready
    }

    // MARK: - Opening

    /// Opens the data folder, imports the first Kairos's data once, and loads the lists.
    func open() async {
        guard workspace == nil else { return }
        do {
            let typst = Bundle.main.url(forAuxiliaryExecutable: "typst")
            let workspace = try await Workspace.open(typst: typst)
            self.workspace = workspace
            preparation = await workspace.prepare()
            if let error = preparation?.importError {
                notice = Notice(title: "Your earlier data wasn't imported", message: error)
            }
            listenToBuilds()
            await reload()
            phase = .ready
        } catch {
            phase = .failed("Kairos couldn't open its data: \(error)")
        }
    }

    /// Reads every list again from the store.
    func reload() async {
        guard let store = workspace?.store else { return }
        do {
            jobs = try await store.jobs.summaries()
            builds = try await store.builds.all()
            applications = try await store.applications.all()
            sources = try await store.sources.all()
            preferences = try await store.settings.preferences()
            aiSettings = try await store.settings.aiSettings()
            stretch = try await store.settings.stretch()
            pages = try await store.settings.pages()
            workProfile = try await store.settings.workProfile()
            resume = try await store.resume.load()
            counts = try await store.screening.counts()
            lastFetch = try await store.activity.lastRun(.fetch)
            lastScreen = try await store.activity.lastRun(.screen)
        } catch {
            notice = Notice(title: "Kairos couldn't read its data", message: "\(error)")
        }
    }

    func reloadJobs() async {
        guard let store = workspace?.store else { return }
        jobs = (try? await store.jobs.summaries()) ?? jobs
        counts = (try? await store.screening.counts()) ?? counts
    }

    // MARK: - Lists

    var inbox: [JobSummary] { JobLists.inbox(jobs) }
    var saved: [JobSummary] { JobLists.saved(jobs) }
    var skipped: [JobSummary] { JobLists.skipped(jobs) }
    var filteredOut: [JobSummary] { JobLists.filteredOut(jobs) }
    var waitingForAI: Int { JobLists.waitingForAI(jobs).count }

    func jobs(in section: AppSection) -> [JobSummary] {
        switch section {
        case .inbox: inbox
        case .saved: saved
        case .skipped: skipped
        case .filtered: filteredOut
        default: []
        }
    }

    func summary(_ id: String?) -> JobSummary? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    func count(_ section: AppSection) -> Int? {
        switch section {
        case .inbox: inbox.filter { $0.verdict != .no }.count
        case .saved: saved.count
        case .resumes: builds.filter { !$0.status.isFinished }.count
        case .interviews: applications.filter(\.status.isInProgress).count
        case .applied: applications.filter { $0.followUpAt.map { $0 <= Date() } ?? false }.count
        default: nil
        }
    }

    /// New in the Inbox since you last looked.
    var newSinceLooked: Int { inbox.count { $0.firstSeenAt > lookedAt } }

    func markLooked() { lookedAt = Date() }

    // MARK: - Finding and screening jobs

    /// A model is set for analysing jobs, from a provider that has what it needs.
    var canAnalyze: Bool {
        aiSettings.chain(for: .analyzeJob).contains { ref in
            guard let provider = aiSettings.provider(ref.provider) else { return false }
            return !provider.preset.needsKey || !provider.keyNames.isEmpty
        }
    }

    /// The run whose progress the status shows; updates from any other arrive too late to count.
    private var currentRun: UUID?

    /// Reads every source, then screens what's new. ⌘R.
    func findNewJobs() {
        guard let workspace, !activity.isRunning else { return }
        let run = UUID()
        currentRun = run
        activity = .fetching(FetchProgress())
        runTask = Task {
            do {
                try await workspace.fetcher().run { progress in
                    Task { @MainActor in if self.currentRun == run { self.activity = .fetching(progress) } }
                }
                await reload()
                if !Task.isCancelled { try await screen(.new, in: workspace, run: run) }
            } catch {
                notice = Notice(title: "Finding jobs stopped", message: "\(error)")
            }
            finish(run)
        }
    }

    /// Screens the jobs waiting for the AI, or judges every job again (after a settings change).
    func screenNow(_ scope: Screener.Scope = .new) {
        guard let workspace, !activity.isRunning else { return }
        let run = UUID()
        currentRun = run
        runTask = Task {
            do {
                try await screen(scope, in: workspace, run: run)
            } catch {
                notice = Notice(title: "Screening stopped", message: "\(error)")
            }
            finish(run)
        }
    }

    private func screen(_ scope: Screener.Scope, in workspace: Workspace, run: UUID) async throws {
        activity = .screening(ScreeningProgress())
        try await workspace.screener().run(scope) { progress in
            Task { @MainActor in if self.currentRun == run { self.activity = .screening(progress) } }
        }
    }

    private func finish(_ run: UUID) {
        guard currentRun == run else { return }
        currentRun = nil
        activity = .idle
        Task { await reload() }
    }

    func stop() {
        runTask?.cancel()
    }

    // MARK: - Decisions

    func toggleSave(_ id: String) {
        guard let job = summary(id) else { return }
        decide(id, job.decision == .saved ? nil : .saved, title: job.decision == .saved ? "Unsave" : "Save")
    }

    func skip(_ id: String) {
        guard let job = summary(id) else { return }
        decide(id, job.decision == .skipped ? nil : .skipped, title: job.decision == .skipped ? "Bring back" : "Skip")
    }

    private func decide(_ id: String, _ decision: Job.Decision?, title: String) {
        guard let store = workspace?.store, let job = summary(id) else { return }
        let list = jobs(in: section)
        undo = Undo(jobID: id, decision: job.decision, title: title)
        Task {
            try? await store.jobs.setDecision(decision, for: id)
            await reloadJobs()
            // The next job takes the selection when this one leaves the list.
            if section.isJobList, !jobs(in: section).contains(where: { $0.id == id }),
                let index = list.firstIndex(where: { $0.id == id })
            {
                let remaining = list.filter { $0.id != id }
                selectedJob = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
            }
        }
    }

    /// ⌘Z: puts the last save or skip back.
    func undoDecision() {
        guard let store = workspace?.store, let undo else { return }
        self.undo = nil
        Task {
            try? await store.jobs.setDecision(undo.decision, for: undo.jobID)
            await reloadJobs()
            selectedJob = undo.jobID
        }
    }

    /// Your verdict over screening's; nil takes it back.
    func setVerdict(_ verdict: Verdict?, for id: String) {
        guard let store = workspace?.store else { return }
        Task {
            try? await store.screening.setYourVerdict(verdict, for: id)
            await reloadJobs()
        }
    }

    func reevaluate(_ id: String) {
        guard let workspace else { return }
        Task {
            let outcome = try? await workspace.screener().reevaluate(id)
            if case .failed(let reason)? = outcome {
                notice = Notice(title: "The job couldn't be judged again", message: reason)
            }
            await reloadJobs()
        }
    }

    func bringBack(_ id: String) {
        guard let workspace else { return }
        Task {
            let outcome = try? await workspace.screener().bringBack(id)
            if case .failed(let reason)? = outcome, reason != "This job isn't in Filtered out." {
                notice = Notice(title: "Brought back; it waits for the AI", message: reason)
            }
            await reloadJobs()
        }
    }

    func openPosting(_ id: String) {
        guard let store = workspace?.store else { return }
        Task {
            if let job = try? await store.jobs.job(id), let url = URL(string: job.openURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Records that you applied, with the job's latest finished resume, and retires its copies.
    func markApplied(_ id: String, channel: String? = nil) {
        guard let workspace else { return }
        let build = builds.first { $0.jobID == id && $0.status == .done }
        Task {
            let application = Application(jobID: id, buildID: build?.id, appliedAt: Date(), channel: channel)
            _ = try? await workspace.store.applications.apply(application)
            _ = try? await workspace.screener().retireCopies(of: id)
            await reload()
        }
    }

    // MARK: - Builds

    /// Queues a tailored resume for the job and shows it in Resumes.
    func build(_ id: String, mode: BuildMode = .strict, letter: Bool = false, show: Bool = false) {
        guard let workspace else { return }
        Task {
            do {
                let build = try await workspace.builds.enqueue(jobID: id, mode: mode, letter: letter)
                builds = try await workspace.store.builds.all()
                if show {
                    selectedBuild = build.id
                    section = .resumes
                }
            } catch {
                notice = Notice(title: "The build couldn't start", message: "\(error)")
            }
        }
    }

    func stopBuild(_ id: UUID) {
        guard let workspace else { return }
        Task {
            try? await workspace.builds.stop(id)
            builds = (try? await workspace.store.builds.all()) ?? builds
        }
    }

    func deleteBuild(_ id: UUID) {
        guard let workspace else { return }
        Task {
            let files = (try? await workspace.store.builds.delete(id)) ?? []
            for file in files { try? FileManager.default.removeItem(at: workspace.folder.file(file.path)) }
            if selectedBuild == id { selectedBuild = nil }
            await reload()
        }
    }

    func fileURL(_ file: BuildRecord.File) -> URL? {
        workspace?.folder.file(file.path)
    }

    private func listenToBuilds() {
        guard let queue = workspace?.builds else { return }
        buildEvents = Task { [weak self] in
            for await event in queue.events {
                guard let self else { return }
                switch event {
                case .queued, .started:
                    builds = (try? await workspace?.store.builds.all()) ?? builds
                case .step(let id, let step):
                    liveBuilds[id, default: LiveBuild()].step = step
                case .call(let id, let call):
                    liveBuilds[id, default: LiveBuild()].calls.append(call)
                case .finished(let id), .stopped(let id):
                    liveBuilds[id] = nil
                    await reload()
                case .failed(let id, _):
                    liveBuilds[id] = nil
                    await reload()
                }
            }
        }
    }

    // MARK: - Applications

    func save(_ application: Application, note: String?) async {
        guard let store = workspace?.store else { return }
        try? await store.applications.save(application, note: note)
        applications = (try? await store.applications.all()) ?? applications
    }

    // MARK: - Settings

    func savePreferences(_ preferences: SearchPreferences) {
        guard let store = workspace?.store else { return }
        self.preferences = preferences
        Task { try? await store.settings.set(SearchPreferences.storageKey, to: preferences) }
    }

    /// AI settings saved and in use at once; keys are read again on next use.
    func saveAISettings(_ settings: AISettings) {
        guard let workspace else { return }
        aiSettings = settings
        Task {
            try? await workspace.save(settings)
            await workspace.router.forgetKeys()
        }
    }

    func saveSetting<T: Encodable & Sendable>(_ key: String, _ value: T) {
        guard let store = workspace?.store else { return }
        Task { try? await store.settings.set(key, to: value) }
    }
}
