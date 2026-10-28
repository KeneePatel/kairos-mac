import AI
import Foundation
import Jobs
import KairosKit
import Render
import Secrets
import Store

/// One Kairos install: its data folder, database, keys and AI, and the runs over them. The app and
/// the `kairos` tool both open one.
public struct Workspace: Sendable {
    public let folder: DataFolder
    public let store: KairosStore
    public let secrets: any SecretStore
    public let http: any HTTPClient
    public let router: AIRouter
    public let renderer: ResumeRenderer?
    public let builds: BuildQueue
    public let clock: any WallClock

    static let log = Log.logger("workspace")

    /// Database backups kept; older ones go.
    public static let backupsKept = 10

    /// Opens (or creates) the install in `folder`. `typst` is the PDF maker: the app passes the one
    /// in its bundle; without it, builds fail with a plain reason.
    public static func open(
        folder: DataFolder = .applicationSupport(), typst: URL? = nil, http: any HTTPClient = URLSessionHTTPClient(),
        clock: any WallClock = SystemWallClock()
    ) async throws -> Workspace {
        let store = try await KairosStore.open(at: folder.database)
        try await store.activity.closeInterruptedRuns(at: clock.now)
        let secrets = FileSecretStore(url: folder.keyFile)
        let router = AIRouter(
            settings: try await store.settings.aiSettings(), secrets: secrets, service: HTTPChatService(http: http),
            log: store.ai, cache: store.ai)
        let renderer = ResumeRenderer(typst: typst)
        let builds = BuildQueue(store: store, router: router, folder: folder, renderer: renderer, clock: clock)
        return Workspace(
            folder: folder, store: store, secrets: secrets, http: http, router: router, renderer: renderer,
            builds: builds, clock: clock)
    }

    /// What `prepare` did at launch.
    public struct Preparation: Sendable, Equatable {
        /// The first Kairos's data, imported this launch.
        public var imported: LegacyImport.Report?
        /// Why it couldn't be imported, if it couldn't: the old data stays where it was.
        public var importError: String?
        /// Builds a quit left running, queued again.
        public var resumedBuilds = false
    }

    /// Run at launch: imports the first Kairos's data once, starts Himalayas on a fresh install,
    /// and puts builds a quit interrupted back in the queue.
    public func prepare() async -> Preparation {
        var preparation = Preparation()
        let importer = LegacyImport(store: store, folder: folder)
        if (try? await importer.isPending()) == true {
            do {
                let report = try await importer.run(at: clock.now)
                preparation.imported = report
                Self.log.info(
                    "imported the first Kairos: \(report.jobs) jobs, \(report.builds) builds, \(report.files) files (\(report.missingFiles) missing), \(report.applications) applications"
                )
            } catch let error as LegacyImport.ImportError {
                preparation.importError = error.message
            } catch {
                preparation.importError = "The first Kairos's data couldn't be imported: \(error)"
            }
            if let failure = preparation.importError {
                Self.log.error("the first Kairos's data wasn't imported: \(failure, privacy: .public)")
            }
        }
        if (try? await store.sources.all().isEmpty) == true {
            _ = try? await store.sources.search(.himalayas, at: clock.now)
        }
        preparation.resumedBuilds = (try? await builds.resume()) != nil
        return preparation
    }

    public func fetcher(options: Fetcher.Options = Fetcher.Options()) -> Fetcher {
        Fetcher(store: store, http: http, keys: Readers.Keys(secrets: secrets), clock: clock, options: options)
    }

    public func screener() -> Screener {
        Screener(store: store, router: router, clock: clock)
    }

    /// AI settings saved and in use at once.
    public func save(_ settings: AISettings) async throws {
        try await store.settings.set(AISettings.storageKey, to: settings, at: clock.now)
        await router.update(settings)
    }

    /// Writes a consistent copy of the database to Backups and keeps the latest ten.
    @discardableResult
    public func backUp() async throws -> URL {
        try FileManager.default.createDirectory(at: folder.backups, withIntermediateDirectories: true)
        let url = folder.backup(at: clock.now)
        if !FileManager.default.fileExists(atPath: url.path) { try await store.db.backUp(to: url) }
        let backups =
            (try? FileManager.default.contentsOfDirectory(at: folder.backups, includingPropertiesForKeys: nil)) ?? []
        // The first Kairos's database ("kairos-v1-…") is never trimmed.
        let ours = backups.filter { $0.pathExtension == "sqlite" && !$0.lastPathComponent.hasPrefix("kairos-v1-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in ours.dropFirst(Self.backupsKept) { try? FileManager.default.removeItem(at: old) }
        return url
    }
}
