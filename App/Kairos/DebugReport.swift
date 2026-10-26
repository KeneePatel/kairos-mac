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
            if CommandLine.arguments.contains("--coverage-report") {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    do {
                        let db = try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
                        print(try await CoverageReport.load(from: db).text)
                    } catch {
                        print("coverage-report: \(error)")
                    }
                    done.signal()
                }
                done.wait()
                exit(0)
            }
            if CommandLine.arguments.contains("--sources-report") {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    do {
                        // `--on-copy`: a migrated copy of the database, so a migration can be tried
                        // on your data before it runs for real.
                        let db =
                            CommandLine.arguments.contains("--on-copy")
                            ? try await copiedDatabase()
                            : try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
                        print(try await sourcesReport(db))
                    } catch {
                        print("sources-report: \(error)")
                    }
                    done.signal()
                }
                done.wait()
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
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--serpapi-probe") }) {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await serpApiProbe()
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
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--analyze-one") }) {
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    await analyzeOne()
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
            if CommandLine.arguments.contains("--master-resume-pdf") {
                let done = DispatchSemaphore(value: 0)
                Task.detached {
                    await masterResumePDF()
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

        /// `--sources-report`: what each kind of source yields on this Mac (no contact details, no
        /// keys): jobs, snippets, verdicts, what you acted on, link hosts, posting ages, and how the
        /// company lookups and the catalog's boards fared. Research for the collection redesign.
        /// A migrated copy of this Mac's database in a temporary folder: a dry run's playground.
        private static func copiedDatabase() async throws -> Database {
            let fm = FileManager.default
            let original = try AccountStore.applicationSupport().databaseURL(for: .local)
            let copy = fm.temporaryDirectory.appending(path: "kairos-copy-\(UUID().uuidString)")
            try fm.createDirectory(at: copy, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: original.path + suffix) {
                try fm.copyItem(
                    atPath: original.path + suffix, toPath: copy.appending(path: "kairos.sqlite").path + suffix)
            }
            let db = try Database(path: copy.appending(path: "kairos.sqlite").path)
            let before = try await db.userVersion()
            try await Migrator.migrate(db, with: Migrator.bundled())
            print("on a copy: migrated \(before) → \(try await db.userVersion())")
            return db
        }

        private static func sourcesReport(_ db: Database) async throws -> String {
            var out = "# Kairos sources report (schema \(try await db.userVersion()))\n"
            out += "\n## By kind (open and closed jobs still stored)\n"
            out +=
                "kind | jobs | snippets | yes | maybe | no | filtered | waiting | applied | saved | skipped | archived | closed | avg chars | ≤7d | ≤30d | with apply link | with via\n"
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            for row in try await db.query(
                """
                SELECT s.kind AS kind, COUNT(*) AS n, SUM(j.description_kind = 'snippet') AS snippets,
                    SUM(j.verdict = 'yes') AS yes, SUM(j.verdict = 'maybe') AS maybe,
                    SUM(j.verdict = 'no' AND j.verdict_source != 'prefilter') AS no,
                    SUM(j.verdict_source = 'prefilter') AS filtered, SUM(j.verdict IS NULL) AS waiting,
                    SUM(j.state = 'applied') AS applied, SUM(j.state = 'shortlisted') AS saved,
                    SUM(j.state = 'skipped') AS skipped, SUM(j.state = 'archived') AS archived,
                    SUM(j.closed_at IS NOT NULL) AS closed, CAST(AVG(LENGTH(j.description)) AS INTEGER) AS avg_len,
                    SUM(j.posted_at > ?) AS week, SUM(j.posted_at > ?) AS month,
                    SUM(j.apply_url IS NOT NULL) AS apply, SUM(j.via IS NOT NULL) AS via
                FROM job j JOIN source s ON s.id = j.source_id WHERE j.deleted = 0 GROUP BY s.kind ORDER BY n DESC
                """, [.integer(now - 7 * 86_400_000), .integer(now - 30 * 86_400_000)])
            {
                let cols = [
                    "n", "snippets", "yes", "maybe", "no", "filtered", "waiting", "applied", "saved", "skipped",
                    "archived",
                    "closed", "avg_len", "week", "month", "apply", "via",
                ]
                out +=
                    (row.string("kind") ?? "?") + " | " + cols.map { "\(row.int($0) ?? 0)" }.joined(separator: " | ")
                    + "\n"
            }
            out += "\n## Inbox now (judged, open, not acted on)\n"
            for row in try await db.query(
                """
                SELECT verdict, COUNT(*) AS n, SUM(description_kind = 'snippet') AS snippets FROM job
                WHERE deleted = 0 AND state = 'new' AND verdict IS NOT NULL AND verdict_source != 'prefilter'
                    AND closed_at IS NULL GROUP BY verdict
                """)
            {
                out +=
                    "\(row.string("verdict") ?? "?"): \(row.int("n") ?? 0), of which snippets \(row.int("snippets") ?? 0)\n"
            }
            out += "\n## Link hosts by kind (top 6 each)\n"
            var hosts: [String: [String: Int]] = [:]
            var lengths: [String: [Int]] = [:]
            for row in try await db.query(
                "SELECT s.kind AS kind, j.url AS url, LENGTH(j.description) AS len FROM job j JOIN source s ON s.id = j.source_id WHERE j.deleted = 0"
            ) {
                let kind = row.string("kind") ?? "?"
                let host = row.string("url").flatMap(URL.init(string:))?.host() ?? "(none)"
                hosts[kind, default: [:]][host, default: 0] += 1
                lengths[kind, default: []].append(row.int("len") ?? 0)
            }
            for (kind, counts) in hosts.sorted(by: { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }) {
                let top = counts.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }
                let sorted = (lengths[kind] ?? []).sorted()
                func q(_ f: Double) -> Int {
                    sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * f))]
                }
                out +=
                    "\(kind): \(top.joined(separator: ", ")) · description chars p10 \(q(0.1)) p50 \(q(0.5)) p90 \(q(0.9))\n"
            }
            out += "\n## Adzuna's companies (top 15, with how many of their jobs you filtered or judged)\n"
            for row in try await db.query(
                """
                SELECT j.company AS company, COUNT(*) AS n, SUM(j.verdict_source = 'prefilter') AS filtered,
                    SUM(j.verdict IN ('yes', 'maybe')) AS good
                FROM job j JOIN source s ON s.id = j.source_id WHERE j.deleted = 0 AND s.kind = 'adzuna'
                GROUP BY j.company ORDER BY n DESC LIMIT 15
                """)
            {
                out +=
                    "\(row.string("company") ?? "?"): \(row.int("n") ?? 0) (filtered \(row.int("filtered") ?? 0), yes or maybe \(row.int("good") ?? 0))\n"
            }
            out += "\n## Applications (2026-10-26: a job marked applied twice)\n"
            for row in try await db.query(
                """
                SELECT a.job_id AS job, COUNT(*) AS n, j.state AS state, j.title AS title, j.company AS company
                FROM application a LEFT JOIN job j ON j.id = a.job_id WHERE a.deleted = 0
                GROUP BY a.job_id HAVING n > 1 OR j.state IS NULL OR j.state != 'applied'
                """)
            {
                out +=
                    "\(row.string("title") ?? "?") · \(row.string("company") ?? "?"): \(row.int("n") ?? 0) applications, job state \(row.string("state") ?? "missing")\n"
            }
            for row in try await db.query(
                """
                SELECT j.company AS company, j.title AS title, s.kind AS kind, j.state AS state, a.applied_at AS at,
                    j.city AS city
                FROM application a LEFT JOIN job j ON j.id = a.job_id LEFT JOIN source s ON s.id = j.source_id
                WHERE a.deleted = 0 ORDER BY j.company, j.title
                """)
            {
                let at =
                    row.int64("at").map { Date(milliseconds: $0).formatted(.dateTime.month(.abbreviated).day()) } ?? "?"
                out +=
                    "- \(row.string("company") ?? "?") · \(row.string("title") ?? "?") · \(row.string("city") ?? "-") · \(row.string("kind") ?? "?") · \(row.string("state") ?? "?") · \(at)\n"
            }
            for row in try await db.query(
                """
                SELECT a.id AS id, a.deleted AS deleted, a.job_id AS job, j.title AS title, j.company AS company,
                    j.state AS state, a.applied_at AS at, a.status AS status
                FROM application a LEFT JOIN job j ON j.id = a.job_id
                WHERE a.deleted = 1 OR a.applied_at > ? ORDER BY a.applied_at
                """, [.integer(now - 2 * 86_400_000)])
            {
                let at =
                    row.int64("at").map { Date(milliseconds: $0).formatted(date: .abbreviated, time: .shortened) }
                    ?? "?"
                out +=
                    "recent or deleted: \(row.string("company") ?? "?") · \(row.string("title") ?? "?") · job \(row.string("job")?.prefix(8) ?? "?") · state \(row.string("state") ?? "missing") · \(row.string("status") ?? "?") · deleted \(row.int("deleted") ?? 0) · \(at)\n"
            }
            for row in try await db.query(
                """
                SELECT e.kind AS kind, e.at AS at, a.job_id AS job, j.title AS title
                FROM application_event e JOIN application a ON a.id = e.application_id LEFT JOIN job j ON j.id = a.job_id
                WHERE e.at > ? ORDER BY e.at
                """, [.integer(now - 2 * 86_400_000)])
            {
                let at =
                    row.int64("at").map { Date(milliseconds: $0).formatted(date: .omitted, time: .shortened) } ?? "?"
                out +=
                    "event \(at): \(row.string("kind") ?? "?") · \(row.string("title") ?? "?") · job \(row.string("job")?.prefix(8) ?? "?")\n"
            }
            if let row = try await db.query(
                "SELECT COUNT(*) AS n, COUNT(DISTINCT job_id) AS jobs FROM application WHERE deleted = 0"
            ).first {
                out += "\(row.int("n") ?? 0) applications for \(row.int("jobs") ?? 0) jobs\n"
            }
            out += "\n## Company lookups (snippet companies looked up on public boards)\n"
            if let row = try await db.query("SELECT COUNT(*) AS n, SUM(kind IS NOT NULL) AS found FROM company_lookup")
                .first
            {
                out += "looked up \(row.int("n") ?? 0), board found \(row.int("found") ?? 0)\n"
            }
            if let row = try await db.query(
                "SELECT COUNT(*) AS n FROM (SELECT job_id FROM listing WHERE deleted = 0 GROUP BY job_id HAVING COUNT(*) > 1)"
            ).first {
                out += "jobs with more than one listing: \(row.int("n") ?? 0)\n"
            }
            out += "\n## Boards by origin: how many have open jobs for you\n"
            var byOrigin: [String: (boards: Int, withJobs: Int, withGood: Int, jobs: Int)] = [:]
            for row in try await db.query(
                """
                SELECT s.kind AS kind, s.config AS config, s.enabled AS enabled, s.health AS health,
                    COUNT(j.id) AS n, SUM(j.verdict IN ('yes', 'maybe')) AS good
                FROM source s LEFT JOIN job j ON j.source_id = s.id AND j.deleted = 0 AND j.closed_at IS NULL
                WHERE s.deleted = 0 GROUP BY s.id
                """)
            {
                guard let kind = row.string("kind").flatMap(SourceKind.init(rawValue:)),
                    SourceKind.boards.contains(kind)
                else { continue }
                let origin = row.string("config").flatMap(BoardConfig.decode)?.origin ?? "you"
                var entry = byOrigin[origin] ?? (0, 0, 0, 0)
                entry.boards += 1
                let n = row.int("n") ?? 0
                if n > 0 { entry.withJobs += 1 }
                if (row.int("good") ?? 0) > 0 { entry.withGood += 1 }
                entry.jobs += n
                byOrigin[origin] = entry
            }
            for (origin, entry) in byOrigin.sorted(by: { $0.value.boards > $1.value.boards }) {
                out +=
                    "\(origin): \(entry.boards) boards, \(entry.withJobs) with open jobs for you (\(entry.jobs) jobs), \(entry.withGood) with a Yes or Maybe\n"
            }
            return out
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
            // How many applications, where they stand and when they went out: the Applied page's
            // volume (ADR-016).
            let applications = try await ApplicationRepository(db).applications()
            out += "\n## Applications: \(applications.count)\n"
            for status in ApplicationStatus.allCases {
                let count = applications.count { $0.status == status }
                if count > 0 { out += "- \(status.rawValue): \(count)\n" }
            }
            let byDay = Dictionary(grouping: applications) { Calendar.current.startOfDay(for: $0.appliedAt) }
            for (day, sent) in byDay.sorted(by: { $0.key > $1.key }).prefix(14) {
                out += "- applied \(day.formatted(date: .abbreviated, time: .omitted)): \(sent.count)\n"
            }
            out += try await screeningQueue(db)
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

        /// `--analyze-one[=<words>]`: one fresh job analysis, as screening asks for it, on a copy of
        /// your database, for the first job waiting for the AI (or the first whose "title · company"
        /// has those words). Prints each model the chain asks and, when a reply fails its checks,
        /// what the check found. Spends up to two calls per model in the chain. Never a key.
        @MainActor private static func analyzeOne() async {
            func say(_ text: String) { print("analyze-one: \(text)") }
            do {
                let fm = FileManager.default
                let original = try AccountStore.applicationSupport().databaseURL(for: .local)
                let copy = fm.temporaryDirectory.appending(path: "kairos-analyze-one-\(UUID().uuidString)")
                try fm.createDirectory(at: copy, withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: original.path + suffix) {
                    try fm.copyItem(
                        atPath: original.path + suffix, toPath: copy.appending(path: "kairos.sqlite").path + suffix)
                }
                let db = try Database(path: copy.appending(path: "kairos.sqlite").path)
                let words = CommandLine.arguments.first { $0.hasPrefix("--analyze-one=") }.map {
                    String($0.dropFirst(14))
                }
                let jobs = try await JobRepository(db).jobs()
                let job =
                    if let words {
                        jobs.first { "\($0.title) · \($0.company)".localizedCaseInsensitiveContains(words) }
                    } else {
                        jobs.first { $0.verdict == nil && $0.state == .new && $0.isOpen }
                    }
                guard let job else {
                    say("no job to analyse")
                    return
                }
                let context = try await ScreeningContext.load(from: db)
                let input = context.analysisInput(for: job)
                say(
                    "job: \(job.title) · \(job.company) · \(job.descriptionKind.rawValue) · posting \(job.descriptionMarkdown?.count ?? 0) characters"
                )
                let ai = AISettingsModel(db: db, secrets: AppSecrets.store())
                await ai.load()
                let router = ai.router()
                let chain = (ai.settings.routes[TaskID.analyzeJob.rawValue] ?? []).map { "\($0.provider)/\($0.model)" }
                say("route: \(chain.joined(separator: " > "))")
                let events: @Sendable (CallEvent) -> Void = { event in
                    switch event {
                    case .asking(_, let model, _): print("analyze-one: asking \(model.provider)/\(model.model)")
                    case .retrying(_, let model, let reason): print("analyze-one: retrying \(model.model): \(reason)")
                    case .failed(_, let model, let reason, let detail):
                        print("analyze-one: \(model.model) failed: \(reason)\(detail.map { "\n  check: \($0)" } ?? "")")
                    case .answered(_, let model, let seconds, _):
                        print("analyze-one: \(model.model) answered in \(Int(seconds)) s")
                    }
                }
                do {
                    let result = try await router.run(
                        AnalyzeJobTask(), input: input,
                        context: CallContext(jobID: job.id.rawValue, fresh: true, events: events))
                    say(
                        "ok: \(result.output.requirements.count) requirements from \(result.model) · \(result.outputTokens.map(String.init) ?? "?") output tokens · \(result.inputTokens.map(String.init) ?? "?") input tokens"
                    )
                } catch {
                    say("gave up: \(error.reason)")
                }
            } catch {
                say("couldn't run (\(error))")
            }
        }

        /// What waits for the AI and why it isn't moving: new jobs with no verdict, split by whether
        /// they're still posted and already analysed; the last screening runs; and how the last two
        /// days' job analyses ended, by model and error.
        private static func screeningQueue(_ db: Database) async throws -> String {
            var out = "\n## Screening queue\n"
            for row in try await db.query(
                """
                SELECT j.closed_at IS NULL AS open,
                  EXISTS (SELECT 1 FROM job_analysis a WHERE a.job_id = j.id AND a.deleted = 0
                    AND a.prompt_version = ?) AS analysed,
                  COUNT(*) AS n
                FROM job j WHERE j.deleted = 0 AND j.state = 'new' AND j.verdict IS NULL
                GROUP BY 1, 2 ORDER BY 1 DESC, 2 DESC
                """, [.integer(Int64(AnalyzeJobTask.promptVersion))])
            {
                out +=
                    "- no verdict · \(row.int("open") == 1 ? "still posted" : "no longer posted")"
                    + " · \(row.int("analysed") == 1 ? "analysed" : "not analysed"): \(row.int("n") ?? 0)\n"
            }
            out += "\nLast screening runs:\n"
            for row in try await db.query(
                "SELECT started_at, finished_at, stats, error FROM run WHERE kind = 'screen' AND deleted = 0 ORDER BY started_at DESC LIMIT 6"
            ) {
                let started = row.int64("started_at").map { Date(timeIntervalSince1970: Double($0) / 1_000) }
                let took = row.int64("finished_at").flatMap { end in row.int64("started_at").map { (end - $0) / 1_000 }
                }
                out +=
                    "- \(started?.formatted(date: .abbreviated, time: .standard) ?? "?")"
                    + " · \(took.map { "\($0) s" } ?? "never finished") · \(row.string("stats") ?? "{}")"
                    + "\(row.string("error").map { " · \($0)" } ?? "")\n"
            }
            out += "\nJob analyses in the last 48 hours, by outcome:\n"
            let since = Int64((Date().timeIntervalSince1970 - 48 * 3_600) * 1_000)
            for row in try await db.query(
                """
                SELECT date(at / 1000, 'unixepoch', 'localtime') AS day, provider, model, outcome, error_code,
                  COUNT(*) AS n, MAX(at) AS last
                FROM llm_call WHERE task_id = 'analyzeJob' AND at >= ?
                GROUP BY 1, 2, 3, 4, 5 ORDER BY 1 DESC, n DESC
                """, [.integer(since)])
            {
                let last = row.int64("last").map { Date(timeIntervalSince1970: Double($0) / 1_000) }
                out +=
                    "- \(row.string("day") ?? "?") · \(row.string("provider") ?? "?")/\(row.string("model") ?? "?")"
                    + " · \(row.string("outcome") ?? "?")\(row.string("error_code").map { " (\($0))" } ?? "")"
                    + ": \(row.int("n") ?? 0), last \(last?.formatted(date: .omitted, time: .standard) ?? "?")\n"
            }
            out += "\nJobs whose analysis failed in the last 48 hours:\n"
            for row in try await db.query(
                """
                SELECT j.title, j.company, j.description_kind AS kind, length(j.description) AS chars,
                  COUNT(*) AS n, group_concat(DISTINCT c.error_code) AS errors
                FROM llm_call c JOIN job j ON j.id = c.job_id
                WHERE c.task_id = 'analyzeJob' AND c.outcome = 'failed' AND c.at >= ?
                GROUP BY j.id ORDER BY MAX(c.at) DESC LIMIT 20
                """, [.integer(since)])
            {
                out +=
                    "- \(row.string("title") ?? "?") · \(row.string("company") ?? "?") · \(row.string("kind") ?? "?")"
                    + " · \(row.int("chars") ?? 0) characters · \(row.int("n") ?? 0) failed calls"
                    + " (\(row.string("errors") ?? ""))\n"
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
                    if address == "himalayas" {
                        _ = try await SourceRepository(db).add(kind: .himalayas)
                        say("added himalayas")
                        continue
                    }
                    guard case .detected(let kind, let slug) = ATSDetector.detect(address) else {
                        say("can't add \(address)")
                        continue
                    }
                    let config = BoardConfig(slug: slug, region: ATSDetector.leverRegion(address)).json
                    let added = try await SourceRepository(db).add(kind: kind, config: config)
                    say("added \(kind.rawValue) \(slug) as \(added.id)")
                }
                // `--adzuna-budget=<n>`: Adzuna may spend only n requests on the copy. The copy's log
                // isn't your real one, so its searches would otherwise come out of your day unseen.
                if let budget = CommandLine.arguments.first(where: { $0.hasPrefix("--adzuna-budget=") })
                    .flatMap({ Int($0.dropFirst(16)) }),
                    let adzuna = try await SourceRepository(db).sources().first(where: { $0.kind == .adzuna })
                {
                    try await FetchLog(db).record(
                        FetchLogEntry(
                            runID: nil, sourceID: adzuna.id, at: Date(), request: "dry-run allowance",
                            outcome: .skipped,
                            requests: AdzunaSource.Budget.standard.day - budget))
                    say("Adzuna may spend \(budget) requests")
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
                    adzuna: adzuna, himalayasKey: (try? secrets.read(SecretKey("himalayas.key"))) ?? nil,
                    serpAPIKey: (try? secrets.read(SecretKey("serpapi.key"))) ?? nil)
                let http = URLSessionHTTPClient()
                for pass in 1...2 {
                    let started = Date()
                    let run = FetchRun(
                        db: db, postedWithinDays: preferences.maxAgeDays, roles: preferences.roleMatcher,
                        watch: preferences.watchCatalog
                            ? CatalogWatch(catalog: .bundled, countries: preferences.countries) : nil,
                        finder: LeadFinder(db: db, probe: BoardProbe(http: http), catalog: .bundled),
                        googlePhrases: preferences.roleMatcher.googlePhrases, places: preferences.effectivePlaces,
                        makeSource: { try SourceFactory.make($0, http: http, search: search) })
                    var last = FetchRun.Progress()
                    for await progress in run.start() { last = progress }
                    say(
                        "fetch \(pass) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(last.sourcesDone) sources, "
                            + "\(last.found) found, \(last.added) new, \(last.leads) leads, \(last.attached) attached, \(last.upgraded) upgraded, "
                            + "\(last.changed) changed, \(last.closed) closed, \(last.reopened) reopened, "
                            + "\(last.unchanged) unchanged, \(last.outside) outside, \(last.tooOld) too old, "
                            + "\(last.otherRoles) other roles, \(last.boardsFound) boards found, "
                            + "\(last.catalogAdded) catalog added, \(last.quiet) quiet, "
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
                    "SELECT outcome, COUNT(*) AS n, SUM(ms) AS ms, SUM(requests) AS r FROM fetch_log GROUP BY outcome")
                {
                    say(
                        "log \(row.string("outcome") ?? "?"): \(row.int("n") ?? 0) entries, \(row.int("r") ?? 0) requests, \(row.int("ms") ?? 0) ms"
                    )
                }
                try? fm.removeItem(at: copy)
            } catch {
                say("failed: \(error)")
            }
        }

        /// `--adzuna-probe`: how many Canadian postings a few Adzuna searches find, for sizing a
        /// fetch (2026-10-23 research). About 10 calls of the free 250 a day. Never the key.
        /// `--serpapi-probe[=<query>]`: one Google Jobs search through SerpApi with your key (one of
        /// the plan's searches) for a city-level query, printing each result's shape: where Google
        /// took it from, its apply links' hosts, its dates, and the response's filters. Research
        /// for the collection redesign (2026-10-26). The key is never printed.
        private static func serpApiProbe() async {
            let secrets = AppSecrets.store()
            guard let key = (try? secrets.read(SecretKey("serpapi.key"))) ?? nil, !key.isEmpty else {
                return print("serpapi-probe: no SerpApi key saved")
            }
            let query =
                CommandLine.arguments.first { $0.hasPrefix("--serpapi-probe=") }.map { String($0.dropFirst(16)) }
                ?? "software developer"
            let place =
                CommandLine.arguments.first { $0.hasPrefix("--place=") }.map { String($0.dropFirst(8)) }
                ?? "Toronto, Ontario, Canada"
            var components = URLComponents(string: "https://serpapi.com/search.json")
            components?.queryItems = [
                URLQueryItem(name: "engine", value: "google_jobs"), URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "location", value: place), URLQueryItem(name: "gl", value: "ca"),
                URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "api_key", value: key),
            ]
            guard let url = components?.url else { return print("serpapi-probe: bad URL") }
            do {
                let (data, response) = try await URLSessionHTTPClient().data(for: URLRequest(url: url))
                print("serpapi-probe: \(query) in \(place): HTTP \(response.statusCode), \(data.count) bytes")
                // The sandbox can't write outside its container: `--raw` sends the raw answer out as
                // base64, as snapshots do.
                if CommandLine.arguments.contains("--raw") { print("SERPAPI-RAW \(data.base64EncodedString())") }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                print("keys: \(object.keys.sorted().joined(separator: ", "))")
                if let pagination = object["serpapi_pagination"] as? [String: Any] {
                    print("pagination keys: \(pagination.keys.sorted().joined(separator: ", "))")
                }
                for filter in object["filters"] as? [[String: Any]] ?? [] {
                    let options = (filter["options"] as? [[String: Any]] ?? []).map { option in
                        "\(option["name"] ?? "?")=\((option["parameters"] as? [String: Any])?["uds"] ?? "-")"
                    }
                    print("filter \(filter["name"] ?? "?"): \(options.joined(separator: " | "))")
                }
                for job in object["jobs_results"] as? [[String: Any]] ?? [] {
                    let detected = job["detected_extensions"] as? [String: Any] ?? [:]
                    let options = (job["apply_options"] as? [[String: Any]] ?? []).map { option in
                        "\(option["title"] ?? "?")→\((option["link"] as? String).flatMap(URL.init(string:))?.host() ?? "?")"
                    }
                    let description = job["description"] as? String ?? ""
                    print(
                        "- \(job["title"] ?? "?") · \(job["company_name"] ?? "?") · via \(job["via"] ?? "?") · \(job["location"] ?? "?")"
                            + " · detected \(detected.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","))"
                            + " · extensions \((job["extensions"] as? [String] ?? []).joined(separator: ","))"
                            + " · apply \(options.joined(separator: ", "))"
                            + " · share \((job["share_link"] as? String).flatMap(URL.init(string:))?.host() ?? "-")"
                            + " · source_link \((job["source_link"] as? String).flatMap(URL.init(string:)).map { ($0.host() ?? "?") + $0.path() } ?? "-")"
                            + " · \(description.count) chars · keys \(job.keys.sorted().joined(separator: ","))")
                }
            } catch {
                print("serpapi-probe: \(error)")
            }
        }

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

        /// `--master-resume-pdf`: your whole master resume rendered with no page budget (SPEC §5.10,
        /// Export), as the Export PDF button saves it, printed as one base64 line
        /// (`MASTER-RESUME-PDF <base64>`) so a terminal can write the file the sandbox can't. It's
        /// your own resume, contact details included: keep the output to yourself.
        private static func masterResumePDF() async {
            do {
                let db = try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
                let resume = try await MasterResumeRepository(db).load()
                guard let typst = Bundle.main.url(forAuxiliaryExecutable: "typst") else {
                    print("master-resume-pdf: typst isn't in the app bundle")
                    return
                }
                let renderer = ResumeRenderer(runner: TypstRunner(executable: typst))
                let pdf = try await renderer.render(ResumeDocument(FullResume(resume)))
                print("master-resume-pdf: version \(resume.version), \(pdf.pageCount) page(s)")
                print("MASTER-RESUME-PDF \(pdf.data.base64EncodedString())")
            } catch {
                print("master-resume-pdf: \(error)")
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
