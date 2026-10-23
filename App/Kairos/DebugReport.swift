#if DEBUG
    import Foundation
    import JobSources
    import LLM
    import MasterResume
    import Screening
    import Store
    import Pipeline
    import Render
    import Secrets
    import Tailoring

    /// `Kairos --screening-report`: why jobs end up where they do, printed from this Mac's database
    /// so a terminal (which macOS keeps out of the app's container) can see it. It prints your
    /// skills, titles, search settings, sources and each job's verdict with the rule behind it.
    /// Never contact details, keys or posting text. Debug builds only.
    enum DebugReport {
        static func runIfRequested() {
            if let filter = CommandLine.arguments.first(where: { $0.hasPrefix("--run-build=") })?.dropFirst(12) {
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    await runBuild(String(filter))
                    done.signal()
                }
                // The main thread keeps its run loop, as in the app, while the build runs.
                while done.wait(timeout: .now()) == .timedOut {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                exit(0)
            }
            if CommandLine.arguments.contains("--fetch-dry") {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await fetchDry()
                    done.signal()
                }
                done.wait()
                exit(0)
            }
            if CommandLine.arguments.contains("--adzuna-probe") {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await adzunaProbe()
                    done.signal()
                }
                done.wait()
                exit(0)
            }
            if CommandLine.arguments.contains("--key-usage") {
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    await keyUsage()
                    done.signal()
                }
                while done.wait(timeout: .now()) == .timedOut {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                exit(0)
            }
            if CommandLine.arguments.contains("--ai-report") {
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    await aiReport()
                    done.signal()
                }
                while done.wait(timeout: .now()) == .timedOut {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                exit(0)
            }
            if CommandLine.arguments.contains("--doctor") {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await doctor()
                    done.signal()
                }
                done.wait()
                exit(0)
            }
            if CommandLine.arguments.contains("--render-letters") {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await renderLetters()
                    done.signal()
                }
                done.wait()
                exit(0)
            }
            guard CommandLine.arguments.contains("--screening-report") else { return }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    print(CommandLine.arguments.contains("--export") ? try await export() : try await report())
                } catch {
                    print("screening-report: \(error)")
                }
                done.signal()
            }
            done.wait()
            exit(0)
        }

        private static func report() async throws -> String {
            let db = try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
            var out = "# Kairos screening report (no contact details, no keys)\n"

            let resume = try await MasterResumeRepository(db).load()
            out += "\n## Master resume (version \(resume.version))\n"
            out += "Headline: \(resume.header.headline)\n"
            out += "Total years: \(resume.header.totalYears.map { $0.formatted() } ?? "not set")\n"
            for entry in resume.entries {
                switch entry.fields {
                case .experience(let role):
                    out +=
                        "Experience: \(role.title) · \(role.employer) · \(entry.start.map { "\($0.year)" } ?? "?")–"
                        + "\(entry.isCurrent ? "now" : entry.end.map { "\($0.year)" } ?? "?") · \(entry.bullets.count) bullets\n"
                case .project(let project):
                    out += "Project: \(project.name) · \(project.tech.joined(separator: ", "))\n"
                case .education(let school):
                    out += "Education: \(school.credential) \(school.field) · \(school.institution)\n"
                case .language(let language):
                    out += "Language: \(language.language) (\(language.proficiency.rawValue))\n"
                default:
                    continue
                }
            }
            for level in SkillLevel.allCases {
                let names = resume.skills.filter { $0.level == level }.map(\.name)
                out += "Skills, \(level.rawValue) (\(names.count)): \(names.joined(separator: ", "))\n"
            }

            let preferences =
                try await SettingsRepository(db).value(SearchPreferences.storageKey, as: SearchPreferences.self)
                ?? SearchPreferences()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            out += "\n## Search settings\n"
            out += String(decoding: try encoder.encode(preferences), as: UTF8.self) + "\n"
            let profile =
                try await PrivateSettingsRepository(db).value(WorkProfile.storageKey, as: WorkProfile.self)
                ?? WorkProfile()
            out +=
                "Work profile: "
                + profile.authorization.map { "\($0.key.rawValue): \($0.value.rawValue)" }.sorted().joined(
                    separator: ", ")
                + " · clearance: \(profile.hasClearance)"
                + " · student status: \(profile.enrolment.map { "\($0)" } ?? "not set")\n"

            out += "\n## Sources\n"
            for source in try await SourceRepository(db).sources() {
                out +=
                    "\(source.kind.rawValue) · \(source.config) · \(source.enabled ? "on" : "off") · \(source.health.rawValue)\n"
            }

            let jobs = try await JobRepository(db).jobs()
            let screenings = try await ScreeningRepository(db).latestByJob()
            out += "\n## Jobs: \(jobs.count)\n"
            let byCountry = Dictionary(grouping: jobs) { $0.country?.rawValue ?? "unknown" }
            out +=
                "By country: " + byCountry.map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ") + "\n"
            let byCompany = Dictionary(grouping: jobs, by: \.company).mapValues(\.count).sorted { $0.value > $1.value }
            out += "By company: " + byCompany.prefix(30).map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n"

            var groups: [String: [(Job, ScreeningRecord)]] = [:]
            var unscreened = 0
            for job in jobs {
                guard let record = screenings[job.id.rawValue] else {
                    unscreened += 1
                    continue
                }
                groups["\(record.stage.rawValue) · \(record.verdict.rawValue) · \(record.ruleID ?? "you")", default: []]
                    .append((job, record))
            }
            out += "Not screened yet: \(unscreened)\n"
            out += "\n## Verdicts by stage and rule\n"
            for (group, members) in groups.sorted(by: { $0.value.count > $1.value.count }) {
                out += "\n### \(group): \(members.count)\n"
                for (job, record) in members.prefix(8) {
                    out +=
                        "- \(job.title) · \(job.company) · \(job.location) [\(job.country?.rawValue ?? "?"), "
                        + "\(job.remoteScope.rawValue)] — \(record.reasons.first ?? "")\n"
                }
            }
            if CommandLine.arguments.contains("--builds") {
                out += "\n## Builds\n"
                let repository = BuildRepository(db)
                for build in try await repository.recent(limit: 30) {
                    let title =
                        jobs.first { $0.id.rawValue == build.jobID }.map { "\($0.title) · \($0.company)" } ?? "?"
                    let ran = (build.finishedAt ?? Date()).timeIntervalSince(build.createdAt)
                    let artifacts = try await repository.artifacts(for: build.id).map { artifact in
                        "\(artifact.kind)\(artifact.localPath.map { FileManager.default.fileExists(atPath: $0) ? "" : " (file missing)" } ?? "")"
                    }
                    out +=
                        "- \(build.createdAt.formatted(date: .abbreviated, time: .standard)) · \(build.status.rawValue)"
                        + " · \(Int(ran)) s · \(build.mode.rawValue) · \(title)\n"
                    out +=
                        "    letter: \(build.coverLetter.map { "\($0.status.rawValue)\($0.error.map { " (\($0))" } ?? "")" } ?? "not asked")"
                        + " · artifacts: \(artifacts.joined(separator: ", ")) · error: \(build.error ?? "none")\n"
                    // Each model call the build made, in order: when, how long, and how it ended.
                    for call in try await db.query(
                        """
                        SELECT at, task_id, model, outcome, error_code, attempt, latency_ms FROM llm_call
                        WHERE build_id = ? ORDER BY at
                        """, [.text(build.id.lowercased)])
                    {
                        let at =
                            call.int64("at").map { Int(Double($0) / 1_000 - build.createdAt.timeIntervalSince1970) }
                            ?? 0
                        out +=
                            "    call +\(at) s · \(call.string("task_id") ?? "?") · \(call.string("model") ?? "?")"
                            + " · \(call.string("outcome") ?? "?")\(call.string("error_code").map { " (\($0))" } ?? "")"
                            + " · \(call.int("attempt") ?? 0) tries · \((call.int("latency_ms") ?? 0) / 1_000) s\n"
                    }
                }
            }
            if CommandLine.arguments.contains("--details") {
                out += try await details(jobs, screenings, db)
            }
            return out
        }

        /// `--run-build=<words> [--stretch] [--report] [--dump] [--writer-model=<model>]`: one build
        /// with a cover letter, strict unless `--stretch`, for the first job whose "title · company"
        /// has those words, run exactly as the app runs it but on a copy of your database (so nothing
        /// of yours changes), printing the routes it uses and each step and render with timings.
        /// `--report` adds its report card and its calls and tokens per task; `--dump` the resume and
        /// letter as JSON and both PDFs as base64, for reviewing a build outside the app (the PDFs
        /// carry your contact line). `--writer-model=<model>` or `<provider>/<model>` puts the writing
        /// tasks on that model in the copy, to compare models.
        @MainActor private static func runBuild(_ filter: String) async {
            let started = Date()
            func say(_ text: String) {
                print("run-build: +\(String(format: "%.1f", Date().timeIntervalSince(started))) s \(text)")
            }
            do {
                let fm = FileManager.default
                let original = try AccountStore.applicationSupport().databaseURL(for: .local)
                let copy = fm.temporaryDirectory.appending(path: "kairos-run-build-\(UUID().uuidString)")
                try fm.createDirectory(at: copy, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: original.path + suffix) {
                    try fm.copyItem(
                        atPath: original.path + suffix, toPath: copy.appending(path: "kairos.sqlite").path + suffix)
                }
                let db = try Database(path: copy.appending(path: "kairos.sqlite").path)
                guard
                    let job = try await JobRepository(db).jobs().first(where: {
                        "\($0.title) · \($0.company)".localizedCaseInsensitiveContains(filter)
                    })
                else {
                    say("no job titled like “\(filter)”")
                    return
                }
                say("job: \(job.title) · \(job.company)")
                let secrets = AppSecrets.store()
                let ai = AISettingsModel(db: db, secrets: secrets)
                await ai.load()
                // How long each key takes to come out of storage, and whether it does. Never the key.
                for provider in ai.settings.providers {
                    for name in provider.keyNames {
                        let asked = Date()
                        let outcome: String
                        do {
                            outcome = try secrets.read(SecretKey(name)) == nil ? "not found" : "read"
                        } catch {
                            outcome = "failed (\(error))"
                        }
                        say(
                            "key \(provider.id) #\(provider.keyNames.firstIndex(of: name) ?? 0): \(outcome) in "
                                + String(format: "%.1f", Date().timeIntervalSince(asked)) + " s")
                    }
                }
                guard let typst = Bundle.main.url(forAuxiliaryExecutable: "typst") else {
                    say("typst isn't in the app bundle")
                    return
                }
                let writing = [
                    TaskID.writeExperience, .writeProjects, .writeSkills, .rewriteSection, .shortenBullets,
                    .coverLetter,
                ]
                // `<model>` is a Gemini model; `<provider>/<model>` names one of your providers, such as
                // `ollama-local/gpt-oss:120b-cloud` for a cloud model through a signed-in Ollama.
                if let choice = CommandLine.arguments.first(where: { $0.hasPrefix("--writer-model=") })?.dropFirst(15) {
                    let parts = choice.split(separator: "/", maxSplits: 1).map(String.init)
                    let ref =
                        parts.count == 2 && ai.settings.provider(parts[0]) != nil
                        ? ModelRef(provider: parts[0], model: parts[1])
                        : ModelRef(provider: "gemini", model: String(choice))
                    for task in writing { await ai.setRoute(task, primary: ref, fallback: nil) }
                }
                // Which model each build task goes to (the router below is built from these). Never a key.
                for task in writing {
                    let route = (ai.settings.routes[task.rawValue] ?? []).map { "\($0.provider)/\($0.model)" }
                    say("route \(task.rawValue): \(route.joined(separator: " > "))")
                }
                let renderer = ResumeRenderer(runner: TypstRunner(executable: typst))
                let queue = BuildQueue(
                    db: db, router: ai.router(), folder: copy.appending(path: "Builds"), template: .standard
                ) {
                    printable in
                    let kind = if case .letter = printable { "letter" } else { "resume" }
                    let renderStarted = Date()
                    print("run-build: render \(kind) start")
                    defer { print("run-build: render \(kind) end after \(Date().timeIntervalSince(renderStarted)) s") }
                    return try await renderer.render(printable)
                }
                let today = try await CallLog(db).usage(since: Calendar.current.startOfDay(for: Date()))
                say("calls today: \(today.calls) of \(ai.settings.budget.dailyCalls)")
                let mode: BuildMode = CommandLine.arguments.contains("--stretch") ? .stretch : .strict
                let id = try await queue.enqueue(job: job.id, mode: mode, coverLetter: true)
                say("queued \(id)")
                let watchdog = Task {
                    guard (try? await Task.sleep(for: .seconds(180))) != nil else { return }
                    say("STILL RUNNING after 180 s (pid \(ProcessInfo.processInfo.processIdentifier))")
                }
                var dropped = 0
                for await event in queue.events {
                    switch event {
                    case .queued: continue
                    case .call(_, let event):
                        switch event {
                        case .asking(let task, let model, let fallback):
                            say("ask \(task.rawValue) · \(model.model)\(fallback ? " (fallback)" : "")")
                        case .retrying(let task, let model, let reason):
                            say("retry \(task.rawValue) · \(model.model) \(reason)")
                        case .failed(let task, let model, let reason, let detail):
                            say(
                                "fail \(task.rawValue) · \(model.model) \(reason)\(detail.map { ": \($0.prefix(400))" } ?? "")"
                            )
                        case .answered(let task, let model, let seconds, let cached):
                            say(
                                "done \(task.rawValue) · \(model.model) \(cached ? "cached" : String(format: "%.1f s", seconds))"
                            )
                        }
                    case .step(_, let step):
                        if case .fitting = step { dropped += 1 }
                        say("step \(step)")
                    case .finished(_, let score, _):
                        say("finished, score \(score)")
                        if CommandLine.arguments.contains("--report") {
                            try await report(id, db: db, renderer: renderer, dropped: dropped)
                        }
                        if CommandLine.arguments.contains("--dump") { try await dump(id, db: db) }
                        // The dates Harvard prints, by section: no names or contact details.
                        if let content = try await BuildRepository(db).build(id)?.content {
                            for section in ResumeDocument(content, for: .standard).sections where !section.items.isEmpty
                            {
                                say(
                                    "dates, \(section.title): \(section.items.map { $0.dates ?? "none" }.joined(separator: "; "))"
                                )
                            }
                        }
                        watchdog.cancel()
                        return
                    case .failed(_, let message):
                        say("failed: \(message)")
                        watchdog.cancel()
                        return
                    }
                }
            } catch {
                say("error \(error)")
            }
        }

        /// `--ai-report`: your AI providers (how many keys each has, found or not), every task's route
        /// and the daily budget, from this Mac's database. Never a key.
        @MainActor private static func aiReport() async {
            do {
                let db = try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
                let secrets = AppSecrets.store()
                let ai = AISettingsModel(db: db, secrets: secrets)
                await ai.load()
                for provider in ai.settings.providers {
                    let found = provider.keyNames.filter { ((try? secrets.read(SecretKey($0))) ?? nil) != nil }.count
                    print(
                        "ai-report: provider \(provider.id) (\(provider.preset.name)) · keys \(found) of "
                            + "\(provider.keyNames.count) found · \(provider.requestsPerMinute.map { "\($0)/min" } ?? "preset rate")"
                    )
                }
                for task in TaskID.catalog {
                    let chain = (ai.settings.routes[task.rawValue] ?? []).map { "\($0.provider)/\($0.model)" }
                    print(
                        "ai-report: route \(task.rawValue): \(chain.isEmpty ? "none" : chain.joined(separator: " > "))")
                }
                print("ai-report: budget \(ai.settings.budget.dailyCalls) calls a day")
            } catch {
                print("ai-report: couldn't read settings (\(error))")
            }
        }

        /// `--fetch-dry`: two real fetches, one after the other, on a migrated copy of your database
        /// (job collection v2): what the migration made, what each fetch added, attached, upgraded,
        /// changed and closed, and which boards answered "unchanged". No screening, so no AI calls;
        /// Adzuna gets its usual searches. Your own database isn't touched.
        private static func fetchDry() async {
            func say(_ text: String) { print("fetch-dry: \(text)") }
            do {
                let fm = FileManager.default
                let original = try AccountStore.applicationSupport().databaseURL(for: .local)
                let copy = fm.temporaryDirectory.appending(path: "kairos-fetch-dry-\(UUID().uuidString)")
                try fm.createDirectory(at: copy, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: original.path + suffix) {
                    try fm.copyItem(
                        atPath: original.path + suffix, toPath: copy.appending(path: "kairos.sqlite").path + suffix)
                }
                let db = try Database(path: copy.appending(path: "kairos.sqlite").path)
                let before = try await db.userVersion()
                try await Migrator.migrate(db, with: Migrator.bundled())
                say("migrated \(before) → \(try await db.userVersion())")
                // `--add=<careers URL>`: a board added to the copy only, to try a reader live.
                for argument in CommandLine.arguments where argument.hasPrefix("--add=") {
                    let address = String(argument.dropFirst(6))
                    guard case .detected(let kind, let slug) = ATSDetector.detect(address) else {
                        say("can't add \(address)")
                        continue
                    }
                    let config = BoardConfig(slug: slug, region: ATSDetector.leverRegion(address)).json
                    let added = try await SourceRepository(db).add(kind: kind, config: config)
                    say("added \(kind.rawValue) \(slug) as \(added.id)")
                }
                for row in try await db.query(
                    "SELECT description_kind, COUNT(*) AS n FROM listing WHERE deleted = 0 GROUP BY description_kind")
                {
                    say("listings \(row.string("description_kind") ?? "?"): \(row.int("n") ?? 0)")
                }
                let preferences =
                    (try? await SettingsRepository(db).value(SearchPreferences.storageKey, as: SearchPreferences.self))
                    ?? SearchPreferences()
                let secrets = AppSecrets.store()
                let adzuna: AdzunaSource.Credentials? =
                    if let id = (try? secrets.read(SecretKey("adzuna.app_id"))) ?? nil,
                        let key = (try? secrets.read(SecretKey("adzuna.app_key"))) ?? nil
                    {
                        AdzunaSource.Credentials(appID: id, appKey: key)
                    } else { nil }
                let search = SearchContext(
                    query: SourceQuery(
                        titles: preferences.roleMatcher.searches, countries: preferences.countries,
                        maxAgeDays: preferences.maxAgeDays),
                    adzuna: adzuna)
                let http = URLSessionHTTPClient()
                for pass in 1...2 {
                    let started = Date()
                    let run = FetchRun(
                        db: db, postedWithinDays: preferences.maxAgeDays, roles: preferences.roleMatcher,
                        makeSource: { try SourceFactory.make($0, http: http, search: search) })
                    var last = FetchRun.Progress()
                    for await progress in run.start() { last = progress }
                    say(
                        "fetch \(pass) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(last.sourcesDone) sources, "
                            + "\(last.found) found, \(last.added) new, \(last.attached) attached, \(last.upgraded) upgraded, "
                            + "\(last.changed) changed, \(last.closed) closed, \(last.reopened) reopened, "
                            + "\(last.unchanged) unchanged, \(last.outside) outside, \(last.tooOld) too old, "
                            + "\(last.otherRoles) other roles, "
                            + "\(last.failures.count) failed")
                    for failure in last.failures { say("  failed: \(failure.message)") }
                }
                for row in try await db.query(
                    "SELECT kind, COUNT(*) AS n FROM job_event WHERE deleted = 0 GROUP BY kind ORDER BY kind")
                {
                    say("events \(row.string("kind") ?? "?"): \(row.int("n") ?? 0)")
                }
                for row in try await db.query(
                    """
                    SELECT job.title, job.company, COUNT(*) AS n FROM listing JOIN job ON job.id = listing.job_id
                    WHERE listing.deleted = 0 GROUP BY listing.job_id HAVING n > 1 LIMIT 10
                    """)
                {
                    say(
                        "  on \(row.int("n") ?? 0) sources: \(row.string("title") ?? "") · \(row.string("company") ?? "")"
                    )
                }
                for row in try await db.query(
                    """
                    SELECT source.kind, job_event.kind AS event, COUNT(*) AS n FROM job_event
                    JOIN source ON source.id = job_event.source_id
                    WHERE job_event.kind IN ('changed', 'closed', 'upgraded') GROUP BY source.kind, job_event.kind
                    """)
                {
                    say("  \(row.string("event") ?? "?") on \(row.string("kind") ?? "?"): \(row.int("n") ?? 0)")
                }
                for row in try await db.query(
                    """
                    SELECT job.title, job.company FROM job_event JOIN job ON job.id = job_event.job_id
                    WHERE job_event.kind = 'changed' LIMIT 5
                    """)
                {
                    say("  edited: \(row.string("title") ?? "") · \(row.string("company") ?? "")")
                }
                for row in try await db.query(
                    """
                    SELECT source.kind, COUNT(listing.id) AS n, SUM(listing.description_kind = 'full') AS full
                    FROM source LEFT JOIN listing ON listing.source_id = source.id AND listing.deleted = 0
                    WHERE source.deleted = 0 GROUP BY source.kind ORDER BY source.kind
                    """)
                {
                    say("  \(row.string("kind") ?? "?"): \(row.int("n") ?? 0) listings, \(row.int("full") ?? 0) full")
                }
                for row in try await db.query(
                    "SELECT source_id, outcome, error FROM fetch_log WHERE outcome = 'failed' LIMIT 10")
                {
                    say("  failed \(row.string("source_id") ?? "?"): \(row.string("error") ?? "")")
                }
                for row in try await db.query(
                    "SELECT outcome, COUNT(*) AS n, SUM(ms) AS ms FROM fetch_log GROUP BY outcome")
                {
                    say(
                        "log \(row.string("outcome") ?? "?"): \(row.int("n") ?? 0) requests, \(row.int("ms") ?? 0) ms in all"
                    )
                }
                try? fm.removeItem(at: copy)
            } catch {
                say("failed: \(error)")
            }
        }

        /// `--adzuna-probe`: how many Canadian postings a few Adzuna searches find, for sizing a
        /// fetch (2026-10-23 research). About 10 calls of the free 250 a day. Never the key.
        private static func adzunaProbe() async {
            let secrets = AppSecrets.store()
            guard let id = (try? secrets.read(SecretKey("adzuna.app_id"))) ?? nil,
                let key = (try? secrets.read(SecretKey("adzuna.app_key"))) ?? nil
            else { return print("adzuna-probe: no Adzuna key saved") }
            let probes: [(String, String, [(String, String)])] = [
                ("categories", "categories", []),
                (
                    "title_only software developer", "search/1",
                    [("title_only", "software developer"), ("max_days_old", "7")]
                ),
                (
                    "title_only software engineer", "search/1",
                    [("title_only", "software engineer"), ("max_days_old", "7")]
                ),
                ("title_only developer", "search/1", [("title_only", "developer"), ("max_days_old", "7")]),
                ("category it-jobs, 7 days", "search/1", [("category", "it-jobs"), ("max_days_old", "7")]),
                ("category it-jobs, 1 day", "search/1", [("category", "it-jobs"), ("max_days_old", "1")]),
                (
                    "it-jobs, what_or developer engineer programmer", "search/1",
                    [("category", "it-jobs"), ("what_or", "developer engineer programmer"), ("max_days_old", "7")]
                ),
                (
                    "it-jobs Halifax", "search/1",
                    [("category", "it-jobs"), ("where", "Halifax"), ("max_days_old", "30")]
                ),
                (
                    "results_per_page 100", "search/1",
                    [("title_only", "software developer"), ("max_days_old", "7"), ("results_per_page", "100")]
                ),
            ]
            for (label, path, items) in probes {
                guard var components = URLComponents(string: "https://api.adzuna.com/v1/api/jobs/ca/\(path)") else {
                    continue
                }
                components.queryItems =
                    [URLQueryItem(name: "app_id", value: id), URLQueryItem(name: "app_key", value: key)]
                    + (items.contains { $0.0 == "results_per_page" } || path == "categories"
                        ? [] : [URLQueryItem(name: "results_per_page", value: "50")])
                    + items.map { URLQueryItem(name: $0.0, value: $0.1) }
                guard let url = components.url, let (data, response) = try? await URLSession.shared.data(from: url)
                else {
                    print("adzuna-probe: \(label): network error")
                    continue
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if path == "categories" {
                    let tags = (json["results"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String }
                    print("adzuna-probe: categories \(status): \(tags.joined(separator: ", "))")
                    continue
                }
                let results = json["results"] as? [[String: Any]] ?? []
                let titles = results.prefix(5).compactMap { $0["title"] as? String }
                print("adzuna-probe: \(label) \(status): count \(json["count"] ?? "?"), returned \(results.count)")
                print("adzuna-probe:   first titles: \(titles.joined(separator: " | "))")
                if label.hasPrefix("title_only software developer"), let first = results.first {
                    print("adzuna-probe:   fields: \(first.keys.sorted().joined(separator: ", "))")
                    print("adzuna-probe:   location: \(first["location"] ?? "")")
                    let text = first["description"] as? String ?? ""
                    print("adzuna-probe:   description length \(text.count)")
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }

        /// `--key-usage [--raw]`: each key's usage bars as AI providers draws them, by its masked hint,
        /// from this Mac's database and each provider's balance. `--raw` adds each balance reply as
        /// sent. Never a key.
        @MainActor private static func keyUsage() async {
            do {
                let db = try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
                let secrets = AppSecrets.store()
                let ai = AISettingsModel(db: db, secrets: secrets)
                await ai.load()
                await ai.refreshBalances()
                for provider in ai.settings.providers {
                    for name in provider.keyNames {
                        let hint = ai.masked[name] ?? "not on this Mac"
                        print("key-usage: \(provider.id) \(hint)")
                        for bar in ai.allowances[name] ?? [] {
                            let left = bar.left.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
                            let resets =
                                bar.resets.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" }
                                ?? ""
                            print(
                                "key-usage:   \(bar.label)\(left) · \(bar.detail)\(resets)\(bar.usedUp ? " · used up" : "")"
                            )
                        }
                        if let problem = ai.allowanceErrors[name] { print("key-usage:   \(problem)") }
                        guard CommandLine.arguments.contains("--raw"), let address = provider.preset.balanceURL,
                            let url = URL(string: address), let key = (try? secrets.read(SecretKey(name))) ?? nil
                        else { continue }
                        var request = URLRequest(url: url)
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        if let (data, response) = try? await URLSession.shared.data(for: request) {
                            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                            print("key-usage:   raw \(status) \(String(decoding: data, as: UTF8.self))")
                        }
                    }
                }
            } catch {
                print("key-usage: couldn't read settings (\(error))")
            }
        }

        /// The report card of a finished build: its resume measured again as the app renders it.
        @MainActor private static func report(_ id: UUID, db: Database, renderer: ResumeRenderer, dropped: Int)
            async throws
        {
            guard let record = try await BuildRepository(db).build(id), let content = record.content,
                let score = record.score
            else { return }
            let layout = try await renderer.render(ResumeDocument(content, for: .standard)).pageLayout
            let master = try await MasterResumeRepository(db).load()
            let card = BuildReport(resume: content, score: score, layout: layout, dropped: dropped, master: master)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print("run-build: report " + String(decoding: try encoder.encode(card), as: UTF8.self))
            let usage = try await CallLog(db).usage(build: id.lowercased).sorted { $0.key.rawValue < $1.key.rawValue }
            for (task, cost) in usage {
                print("run-build: cost \(task.rawValue) \(cost.calls) calls, \(cost.tokens) tokens")
            }
            for call in try await db.query(
                "SELECT task_id, model, outcome, error_code, attempt, latency_ms FROM llm_call WHERE build_id = ? ORDER BY at",
                [.text(id.lowercased)])
            {
                print(
                    "run-build: call \(call.string("task_id") ?? "?") · \(call.string("model") ?? "?") · "
                        + "\(call.string("outcome") ?? "?")\(call.string("error_code").map { " (\($0))" } ?? "") · "
                        + "\(call.int("attempt") ?? 0) tries · \(call.int("latency_ms") ?? 0) ms")
            }
        }

        /// What a build made, one line each, for reading outside the app's container.
        @MainActor private static func dump(_ id: UUID, db: Database) async throws {
            let builds = BuildRepository(db)
            guard let record = try await builds.build(id) else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let content = record.content {
                print("run-build: content " + String(decoding: try encoder.encode(content), as: UTF8.self))
            }
            if let letter = record.coverLetter {
                print("run-build: letter " + String(decoding: try encoder.encode(letter), as: UTF8.self))
            }
            for artifact in try await builds.artifacts(for: id) {
                guard let path = artifact.localPath, let data = FileManager.default.contents(atPath: path) else {
                    continue
                }
                print("run-build: pdf \(artifact.kind) \(data.base64EncodedString())")
            }
        }

        /// `--render-letters`: every cached cover letter, rendered the way the build queue renders
        /// it (bundled typst, the real renderer), with how long each took. For a stuck build.
        /// `--doctor`: the integrity report on this Mac's database (T46), until `kairos doctor` (R3).
        /// Counts only.
        private static func doctor() async {
            do {
                let url = try AccountStore.applicationSupport().databaseURL(for: .local)
                let report = try await Doctor(try Database(path: url.path)).run()
                print(
                    "doctor: database \(ByteCountFormatter.string(fromByteCount: report.databaseBytes, countStyle: .file))"
                )
                if report.isClean { print("doctor: no problems found") }
                for finding in report.findings { print("doctor: \(finding.problem): \(finding.count)") }
            } catch {
                print("doctor: couldn't run (\(error))")
            }
        }

        private static func renderLetters() async {
            do {
                let db = try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
                let header = TailoredResume.Header(try await MasterResumeRepository(db).load().header)
                guard let typst = Bundle.main.url(forAuxiliaryExecutable: "typst") else {
                    print("render-letters: typst isn't in the app bundle")
                    return
                }
                let renderer = ResumeRenderer(runner: TypstRunner(executable: typst))
                let rows = try await db.query(
                    "SELECT output, created_at FROM llm_cache WHERE task_id = 'coverLetter' ORDER BY created_at DESC LIMIT 5"
                )
                print("render-letters: \(rows.count) cached letters")
                for row in rows {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase
                    guard let text = row.string("output"),
                        let output = try? decoder.decode(CoverLetterOutput.self, from: Data(text.utf8))
                    else { continue }
                    let letter = CoverLetter(
                        header: header, date: "October 20, 2026", company: "Test Co", jobTitle: "Software Engineer",
                        greeting: "Dear Test Co hiring team,", paragraphs: output.paragraphs, closing: "Sincerely,",
                        signature: header.name)
                    let started = Date()
                    print("render-letters: rendering \(output.paragraphs.count) paragraphs…")
                    do {
                        let pdf = try await renderer.render(.letter(LetterDocument(letter)))
                        print("render-letters: ok, \(pdf.pageCount) page(s) in \(Date().timeIntervalSince(started)) s")
                    } catch {
                        print("render-letters: failed after \(Date().timeIntervalSince(started)) s: \(error)")
                    }
                }
            } catch {
                print("render-letters: \(error)")
            }
        }

        /// `--export`: JSON for screening experiments: your resume as evidence (skills, education,
        /// experience with bullets, projects, languages, region; never contact details) and every job
        /// the AI analysed, with its posting and today's analysis and verdict.
        private static func export() async throws -> String {
            let db = try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
            let resume = try await MasterResumeRepository(db).load()
            var entries: [[String: Any]] = []
            for entry in resume.entries {
                var item: [String: Any] = [
                    "start": entry.start.map { "\($0.year)-\($0.month)" } ?? "", "current": entry.isCurrent,
                    "end": entry.end.map { "\($0.year)-\($0.month)" } ?? "", "bullets": entry.bullets.map(\.text),
                ]
                switch entry.fields {
                case .experience(let role):
                    item["kind"] = "experience"
                    item["title"] = role.title
                    item["employer"] = role.employer
                case .project(let project):
                    item["kind"] = "project"
                    item["title"] = project.name
                    item["tech"] = project.tech
                case .education(let school):
                    item["kind"] = "education"
                    item["credential"] = school.credential
                    item["field"] = school.field
                case .language(let language):
                    item["kind"] = "language"
                    item["language"] = language.language
                    item["proficiency"] = language.proficiency.rawValue
                default: continue
                }
                entries.append(item)
            }
            let jobs = try await JobRepository(db).jobs()
            let screenings = try await ScreeningRepository(db).latestByJob()
            var analysed: [[String: Any]] = []
            for job in jobs {
                guard let record = screenings[job.id.rawValue], record.stage == .analysis,
                    let analysis = try await AnalysisRepository(db).analysis(
                        for: job.id, promptVersion: AnalyzeJobTask.promptVersion)?.analysis
                else { continue }
                analysed.append([
                    "id": job.id.rawValue, "title": job.title, "company": job.company, "location": job.location,
                    "country": job.country?.rawValue ?? "", "description": job.descriptionMarkdown ?? "",
                    "verdict": record.verdict.rawValue, "rule": record.ruleID ?? "",
                    "requirements": analysis.requirements.map {
                        ["text": $0.text, "kind": $0.kind.rawValue, "matched": $0.effectiveMatch == .yes ? "yes" : ""]
                    },
                ])
            }
            let object: [String: Any] = [
                "resume": [
                    "totalYears": resume.header.totalYears ?? 0, "region": resume.header.region ?? "",
                    "country": resume.header.country ?? "", "headline": resume.header.headline,
                    "skills": resume.skills.map { ["name": $0.name, "level": $0.level.rawValue] }, "entries": entries,
                ],
                "jobs": analysed,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }

        /// `--details`: every job the AI analysed, with each requirement as it was read and matched,
        /// and how code classed it. `--job=<words>` adds the posting text of matching jobs.
        private static func details(_ jobs: [Job], _ screenings: [String: ScreeningRecord], _ db: Database)
            async throws -> String
        {
            var out = "\n## Analysed jobs in detail\n"
            let filter = CommandLine.arguments.first { $0.hasPrefix("--job=") }.map { String($0.dropFirst(6)) }
            for job in jobs {
                guard let record = screenings[job.id.rawValue], record.stage == .analysis,
                    let analysis = try await AnalysisRepository(db).analysis(
                        for: job.id, promptVersion: AnalyzeJobTask.promptVersion)?.analysis
                else { continue }
                let coverage = Coverage(analysis)
                out += "\n### \(job.title) · \(job.company) · \(job.location)\n"
                out +=
                    "Verdict: \(record.verdict.rawValue) (\(record.ruleID ?? "you")) — \(record.reasons.joined(separator: " "))\n"
                out +=
                    "Coverage: must \(coverage.mustCovered)/\(coverage.mustTotal), nice \(coverage.niceCovered)/\(coverage.niceTotal)"
                    + " · years \(analysis.yearsRequired.map(String.init) ?? "–") · level \(analysis.seniority?.rawValue ?? "–")"
                    + " · flags \(analysis.flags.sponsorship.rawValue)/\(analysis.flags.clearance.rawValue)/"
                    + "\(analysis.flags.french.rawValue)/\(analysis.flags.remoteScope.rawValue)\n"
                for requirement in analysis.requirements {
                    let kind =
                        "\(requirement.kind.rawValue)/\(requirement.category?.rawValue ?? (requirement.counts ? "skill" : "condition"))"
                    out +=
                        "- [\(kind)] \(requirement.text) → \(requirement.effectiveMatch.rawValue) \(requirement.evidence ?? [])\n"
                }
                if let filter, job.title.localizedCaseInsensitiveContains(filter) {
                    out += "\nPosting:\n\(job.descriptionMarkdown ?? "")\n"
                }
            }
            return out
        }
    }
#endif
