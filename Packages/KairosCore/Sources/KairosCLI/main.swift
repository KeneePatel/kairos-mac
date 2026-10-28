import Engine
import Foundation
import Jobs
import KairosKit
import Screening
import Store
import Tailoring

/// `kairos`: Kairos without its windows, over a data folder. For checking a change against live
/// boards and models, for scripts, and for looking inside a database.
let usage = """
    Usage: kairos <command> [--data <folder>] [options]

    Commands:
      status                      What's in the database: jobs, screening, sources, the last runs.
      fetch                       Read every watched source now.
      screen [--everything] [--limit <n>]
                                  Screen new jobs, or judge every job you haven't acted on again;
                                  --limit caps the AI's analyses this run.
      jobs [--list <name>]        List jobs: inbox (default), saved, skipped, filtered, waiting.
      show <job id>               One job: its listings, history, analysis and screening.
      build <job id> [--mode strict|lite|stretch] [--letter]
                                  Build a tailored resume and wait for it.
      sources                     Every source and how its last read went.
      add <system> <slug> [--name <company>]
                                  Watch a company's board: greenhouse, lever, ashby, workable, ...
      set <key> <json>            Save a setting as JSON, such as screening (your search preferences).
      import                      Bring in the first Kairos's data from <folder>/local (read-only).
      backup                      Write a copy of the database to <folder>/Backups.
      doctor                      Check the database's integrity and the PDFs it names.

    Options:
      --data <folder>             The data folder (default: ~/Library/Application Support/Kairos).
      --typst <path>              The typst binary for builds (default: $KAIROS_TYPST, then Vendor/typst/typst).
    """

struct Arguments {
    var command: String
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw CLIError.usage }
        self.command = command
        var rest = arguments.dropFirst()[...]
        while let argument = rest.popFirst() {
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if ["data", "typst", "mode", "list", "name", "limit"].contains(name) {
                    guard let value = rest.popFirst() else { throw CLIError.message("--\(name) needs a value") }
                    options[name] = value
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
        }
    }
}

enum CLIError: Error {
    case usage
    case message(String)
}

func typst(_ given: String?) -> URL? {
    let candidates =
        [given, ProcessInfo.processInfo.environment["KAIROS_TYPST"]].compactMap { $0 }
        + sequence(first: URL(filePath: FileManager.default.currentDirectoryPath)) { url in
            let parent = url.deletingLastPathComponent()
            return parent.path == url.path ? nil : parent
        }.map { $0.appending(path: "Vendor/typst/typst").path }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
}

func line(_ text: String) {
    print(text)
}

func describe(_ stats: RunStats) -> String {
    let mirror = Mirror(reflecting: stats)
    return mirror.children.compactMap { child -> String? in
        guard let label = child.label else { return nil }
        switch child.value {
        case let value as Int?: return value.map { "\(label) \($0)" }
        case let value as Bool?: return value == true ? label : nil
        default: return nil
        }
    }.joined(separator: ", ")
}

func run() async throws {
    let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
    let folder =
        arguments.options["data"].map { DataFolder(root: URL(filePath: $0, directoryHint: .isDirectory)) }
        ?? .applicationSupport()
    let workspace = try await Workspace.open(folder: folder, typst: typst(arguments.options["typst"]))
    let store = workspace.store

    switch arguments.command {
    case "status":
        let jobs = try await store.jobs.summaries()
        let counts = try await store.screening.counts()
        let sources = try await store.sources.all()
        line("Data folder: \(folder.root.path)")
        line(
            "Jobs: \(jobs.count) in the lists, \(JobLists.inbox(jobs).count) in the Inbox, \(JobLists.saved(jobs).count) saved"
        )
        line(
            "Screening: \(counts.unscreened) new, \(counts.filtered) filtered, \(counts.waiting) waiting for the AI, "
                + "\(counts.yes) yes, \(counts.maybe) maybe, \(counts.no) no")
        let watched = sources.filter { $0.status == .watching }.count
        line("Sources: \(sources.count) (\(watched) watched)")
        for kind in [Run.Kind.fetch, .screen] {
            if let last = try await store.activity.lastRun(kind) {
                line("Last \(kind.rawValue): \(last.startedAt.formatted()) — \(last.error ?? describe(last.stats))")
            }
        }

    case "fetch":
        let started = Date()
        let run = try await workspace.fetcher().run { progress in
            FileHandle.standardError.write(Data("\r\(progress.phase) \(progress.done)/\(progress.total)   ".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))
        line("Fetched in \(Int(Date().timeIntervalSince(started))) s: \(describe(run.stats))")
        for source in try await store.sources.all() where source.lastError != nil && source.status == .watching {
            line("  \(source.kind.displayName) \(source.displayName): \(source.lastError ?? "")")
        }

    case "screen":
        let run = try await workspace.screener().run(
            arguments.flags.contains("everything") ? .everything : .new,
            analyses: arguments.options["limit"].flatMap(Int.init)
        ) { progress in
            FileHandle.standardError.write(Data("\r\(progress.phase) \(progress.done)/\(progress.total)   ".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))
        line("Screened: \(describe(run.stats))\(run.error.map { " — \($0)" } ?? "")")

    case "jobs":
        let jobs = try await store.jobs.summaries()
        let countries = try await store.settings.preferences().countries
        let list: [JobSummary] =
            switch arguments.options["list"] ?? "inbox" {
            case "saved": JobLists.saved(jobs)
            case "skipped": JobLists.skipped(jobs)
            case "filtered": JobLists.filteredOut(jobs)
            case "waiting": JobLists.waitingForAI(jobs)
            default: JobLists.groups(jobs, query: .init(), countries: countries).flatMap(\.1)
            }
        for job in list {
            let verdict = job.verdict?.rawValue ?? job.screening?.stage.rawValue ?? "new"
            line(
                "\(job.id)  \(verdict.padding(toLength: 8, withPad: " ", startingAt: 0)) \(job.company) — \(job.title) (\(job.placeLine))"
            )
        }
        line("\(list.count) jobs")

    case "show":
        guard let id = arguments.positional.first, let detail = try await store.jobs.detail(id) else {
            throw CLIError.message("No job with that id.")
        }
        let job = detail.job
        line("\(job.title) at \(job.company) — \(job.placeLine)")
        line(job.openURL)
        for listing in detail.listings {
            line(
                "  listed by \(listing.sourceName) since \(listing.firstSeenAt.formatted())\(listing.closedAt == nil ? "" : ", closed")"
            )
        }
        for event in detail.events { line("  \(event.at.formatted()) \(event.kind.rawValue)") }
        if let screening = detail.screening {
            line(
                "Screening: \(screening.stage.rawValue) \(screening.shownVerdict?.rawValue ?? "") \(screening.rule ?? "")"
            )
            for reason in screening.reasons { line("  \(reason)") }
        }
        if let analysis = detail.analysis {
            for requirement in analysis.requirements {
                line("  [\(requirement.kind.rawValue)] \(requirement.text): \(requirement.effectiveMatch.rawValue)")
            }
        }

    case "build":
        guard let id = arguments.positional.first else { throw CLIError.message("Which job? kairos build <job id>") }
        let mode = arguments.options["mode"].flatMap(BuildMode.init) ?? .strict
        let build = try await workspace.builds.enqueue(
            jobID: id, mode: mode, letter: arguments.flags.contains("letter"))
        let watcher = Task {
            for await event in workspace.builds.events {
                if case .step(_, let step) = event { FileHandle.standardError.write(Data("  \(step)\n".utf8)) }
            }
        }
        await workspace.builds.idle()
        watcher.cancel()
        guard let done = try await store.builds.build(build.id) else { throw CLIError.message("The build is gone.") }
        line("Build \(done.status.rawValue)\(done.error.map { ": \($0)" } ?? "")")
        for file in done.files { line("  \(folder.file(file.path).path)") }
        if let error = done.letterError { line("  Letter: \(error)") }

    case "sources":
        let reads = try await store.activity.lastReads()
        for source in try await store.sources.all() {
            let read = reads[source.id]
            line(
                "\(source.status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(source.kind.displayName) \(source.displayName)"
                    + (read.map { " — \($0.outcome.rawValue) \($0.at.formatted())" } ?? "")
                    + (source.lastError.map { " — \($0)" } ?? ""))
        }

    case "add":
        guard arguments.positional.count == 2, let kind = SourceKind(rawValue: arguments.positional[0]), kind.isBoard,
            BoardSlug.isValid(arguments.positional[1])
        else { throw CLIError.message("kairos add <system> <slug>, such as: kairos add greenhouse stripe") }
        let slug = arguments.positional[1]
        let source = try await store.sources.addByYou(
            Board(kind: kind, slug: slug, name: arguments.options["name"] ?? slug), at: Date())
        line("Watching \(source.kind.displayName) \(source.displayName)")

    case "set":
        guard arguments.positional.count == 2, let value = try? JSONValue(parsing: arguments.positional[1]) else {
            throw CLIError.message("kairos set <key> <json>")
        }
        try await store.settings.set(arguments.positional[0], to: value, at: Date())
        line("Saved \(arguments.positional[0])")

    case "import":
        let preparation = await workspace.prepare()
        if let report = preparation.imported {
            let data = try JSONEncoder.pretty.encode(report)
            line(String(decoding: data, as: UTF8.self))
        } else {
            line(preparation.importError ?? "Nothing to import.")
        }

    case "backup":
        line(try await workspace.backUp().path)

    case "doctor":
        let integrity = try await store.db.first("PRAGMA integrity_check")?.string("integrity_check") ?? "?"
        let foreign = try await store.db.query("PRAGMA foreign_key_check").count
        let paths = try await store.builds.filePaths()
        let missing = paths.filter { !FileManager.default.fileExists(atPath: folder.file($0).path) }
        line("Integrity: \(integrity)")
        line("Foreign key problems: \(foreign)")
        line("PDFs: \(paths.count), missing \(missing.count)")
        if integrity != "ok" || foreign > 0 || !missing.isEmpty { exit(1) }

    default:
        throw CLIError.usage
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

do {
    try await run()
} catch CLIError.usage {
    print(usage)
    exit(2)
} catch CLIError.message(let message) {
    FileHandle.standardError.write(Data("kairos: \(message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("kairos: \(error)\n".utf8))
    exit(1)
}
