#if DEBUG
    import AppKit
    import Engine
    import Jobs
    import KairosKit
    import Render
    import Resume
    import Screening
    import Store
    import SwiftUI
    import Tailoring

    /// Debug tools run from the command line, then quit:
    ///
    /// - `--snapshots`: renders every screen, light and dark, over sample data (Jordan Rivera and the
    ///   design's companies) and prints each PNG as base64 on stdout, since the sandbox keeps the
    ///   app's files from the terminal.
    /// - `--import-check`: imports a temporary copy of the first Kairos's database into a temporary
    ///   folder and prints the report. The real files are only read.
    @MainActor
    enum Snapshots {
        static func runIfRequested() {
            let arguments = CommandLine.arguments
            guard arguments.contains("--snapshots") || arguments.contains("--import-check") else { return }
            Task { @MainActor in
                if arguments.contains("--import-check") { await importCheck() } else { await render() }
                exit(0)
            }
            // Keep the process alive for the task: the app's scenes never come up.
            NSApplication.shared.setActivationPolicy(.prohibited)
            NSApplication.shared.run()
        }

        // MARK: - Import check

        static func importCheck() async {
            let real = DataFolder.applicationSupport()
            let temporary = DataFolder(
                root: FileManager.default.temporaryDirectory.appending(path: "import-check-\(UUID().uuidString)"))
            defer { try? FileManager.default.removeItem(at: temporary.root) }
            do {
                try FileManager.default.createDirectory(
                    at: temporary.legacyDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
                for suffix in ["", "-wal", "-shm"] {
                    let source = URL(filePath: real.legacyDatabase.path + suffix)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(
                            at: source, to: URL(filePath: temporary.legacyDatabase.path + suffix))
                    }
                }
                let store = try await KairosStore.open(at: temporary.database)
                let report = try await LegacyImport(store: store, folder: temporary).run()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
                let jobs = try await store.jobs.summaries()
                print(
                    "live jobs \(jobs.count), inbox \(JobLists.inbox(jobs).count), saved \(JobLists.saved(jobs).count)")
                print("sources \(try await store.sources.all().count), resume v\(try await store.resume.version())")
                print(
                    "integrity \(try await store.db.first("PRAGMA integrity_check")?.string("integrity_check") ?? "?")")
            } catch {
                print("IMPORT CHECK FAILED: \(error)")
            }
        }

        // MARK: - Snapshots

        static func render() async {
            let folder = DataFolder(
                root: FileManager.default.temporaryDirectory.appending(path: "snapshots-\(UUID().uuidString)"))
            defer { try? FileManager.default.removeItem(at: folder.root) }
            guard
                let workspace = try? await Workspace.open(
                    folder: folder, typst: Bundle.main.url(forAuxiliaryExecutable: "typst"))
            else {
                print("SNAPSHOT FAILED: no workspace")
                return
            }
            let ids = (try? await seed(workspace)) ?? [:]
            let model = AppModel(workspace: workspace)
            await model.reload()
            let screens: [(String, AppSection, () -> Void)] = [
                ("inbox", .inbox, { model.selectedJob = ids["backend"] }),
                ("inbox-zero", .inbox, { model.selectedJob = nil }),
                ("saved", .saved, {}),
                ("resumes", .resumes, { model.selectedBuild = model.builds.first { $0.status == .done }?.id }),
                (
                    "applied", .applied,
                    {
                        model.selectedApplication = model.applications.first { $0.status == .applied }?.id
                    }
                ),
                (
                    "interviews", .interviews,
                    { model.selectedApplication = model.applications.first { $0.status == .interview }?.id }
                ),
                ("improve", .improve, {}),
                ("filtered", .filtered, {}),
                ("master-resume", .masterResume, {}),
                ("sources", .sources, {}),
                ("settings-search", .settings, { model.settingsPage = .search }),
                ("settings-ai", .settings, { model.settingsPage = .ai }),
                ("settings-general", .settings, { model.settingsPage = .general }),
            ]
            for (name, section, setUp) in screens {
                model.section = section
                setUp()
                for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    await snapshot(
                        RootView().environment(model), name: "\(name)-\(suffix)",
                        size: CGSize(width: 1440, height: 900), appearance: appearance)
                }
            }
            await snapshot(MenuBarView().environment(model), name: "menu-bar-light", size: nil, appearance: .aqua)
        }

        static func snapshot(_ view: some View, name: String, size: CGSize?, appearance: NSAppearance.Name) async {
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            // ARC owns it: closing mustn't release it a second time.
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            // Let tasks load their data and the layout settle.
            try? await Task.sleep(for: .milliseconds(1_200))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            print("SNAPSHOT \(name).png \(png.base64EncodedString())")
            fflush(stdout)
            window.close()
        }

        // MARK: - Sample data

        /// Jordan Rivera, the design's sample person, and jobs at the design's companies.
        static func seed(_ workspace: Workspace) async throws -> [String: String] {
            let store = workspace.store
            let now = Date()
            var preferences = SearchPreferences()
            preferences.roles = [.software, .devops]
            preferences.countries = [.canada, .unitedStates]
            preferences.watchCatalog = false
            try await store.settings.set(SearchPreferences.storageKey, to: preferences)
            try await store.resume.replace(with: sampleResume, reason: "Sample")

            let northline = try await store.sources.addByYou(
                Board(kind: .greenhouse, slug: "northline", name: "Northline Freight"))
            let maplepay = try await store.sources.addByYou(Board(kind: .lever, slug: "maplepay", name: "Maplepay"))
            _ = try await store.sources.add(
                [
                    Board(kind: .ashby, slug: "tidewater", name: "Tidewater Health"),
                    Board(kind: .workable, slug: "brightline", name: "Brightline"),
                ],
                origin: .catalog)
            _ = try await store.sources.search(.himalayas)

            func listing(
                _ path: String, _ company: String, _ title: String, _ city: String?, _ region: String?,
                remote: RemoteScope = .onsite
            )
                -> Listing
            {
                let url = "https://job-boards.greenhouse.io/\(path)"
                return Listing(
                    canonicalURL: url, url: url, company: company, title: title,
                    location: city.map { "\($0), \(region ?? "")" } ?? "Remote - Canada", city: city, region: region,
                    country: .canada,
                    remoteScope: remote, postedAt: now.addingTimeInterval(-86_400 * 2),
                    description: """
                        ## About the role
                        You'll build the services that move freight across Canada: event pipelines in **Go**, APIs over PostgreSQL, and the tooling around them.

                        ## What you'll do
                        - Design and ship backend services in Go
                        - Run Kafka pipelines handling millions of events a day
                        - Keep PostgreSQL fast and safe

                        ## What you bring
                        - 3+ years building backend services
                        - Go or Java, PostgreSQL, a message queue
                        - Kubernetes is a plus
                        """)
            }
            _ = try await store.ledger.record(
                [
                    listing(
                        "northline/jobs/1", "Northline Freight", "Backend Developer", "Toronto", "ON", remote: .hybrid),
                    listing("northline/jobs/2", "Northline Freight", "Platform Engineer", "Montreal", "QC"),
                    listing("northline/jobs/3", "Northline Freight", "Senior Data Engineer", "Toronto", "ON"),
                    listing("northline/jobs/4", "Northline Freight", "Full Stack Developer", "Halifax", "NS"),
                ], from: northline, complete: true, at: now)
            _ = try await store.ledger.record(
                [
                    listing("maplepay/1", "Maplepay", "Software Developer, Payments", "Waterloo", "ON"),
                    listing("maplepay/2", "Maplepay", "Junior Software Engineer", nil, nil, remote: .remoteCountry),
                    listing("maplepay/3", "Maplepay", "Account Executive", "Toronto", "ON"),
                ], from: maplepay, complete: true, at: now)

            var ids: [String: String] = [:]
            for job in try await store.jobs.summaries() {
                ids[job.title] = job.id
            }
            ids["backend"] = ids["Backend Developer"]
            let analysis = JobAnalysis(
                requirements: [
                    .init(
                        text: "3+ years building backend services", kind: .must, category: .experience, match: .yes,
                        evidence: ["x1"]),
                    .init(text: "Go or Java", kind: .must, category: .skill, match: .yes, evidence: ["s1"]),
                    .init(text: "PostgreSQL", kind: .must, category: .skill, match: .yes, evidence: ["s3"]),
                    .init(
                        text: "A message queue such as Kafka", kind: .must, category: .skill, match: .partial,
                        evidence: ["s2"]),
                    .init(text: "Kubernetes", kind: .nice, category: .skill, match: .no),
                    .init(
                        text: "Legally entitled to work in Canada", kind: .must, category: .authorization,
                        match: .notJudged),
                ], yearsRequired: 3, seniority: .mid, domains: ["logistics"])
            var weak = analysis
            for index in weak.requirements.indices where weak.requirements[index].kind == .must && index > 0 {
                weak.requirements[index].match = .no
                weak.requirements[index].evidence = nil
            }
            let engine = VerdictEngine(
                preferences: preferences, profile: WorkProfile(), languages: [],
                totalYears: sampleResume.header.totalYears)
            for (title, judged) in [
                ("Backend Developer", analysis), ("Platform Engineer", analysis),
                ("Software Developer, Payments", analysis),
                ("Full Stack Developer", analysis), ("Junior Software Engineer", weak),
            ] {
                guard let id = ids[title], let job = try await store.jobs.job(id) else { continue }
                let decision = engine.decide(judged, for: job)
                let state = ScreeningState(
                    stage: .judged, verdict: decision.verdict, rule: decision.rule.rawValue, reasons: decision.reasons,
                    coverage: decision.coverage, match: decision.coverage.match,
                    rank: Ranking.rank(
                        decision.verdict, country: job.country, match: decision.coverage.match, countries: [.canada]),
                    screenedAt: now)
                let stored = StoredAnalysis(
                    analysis: judged, model: "gemini/gemini-flash-latest", promptVersion: AnalyzeJobTask.promptVersion,
                    analyzedAt: now)
                try await store.screening.save(stored, state: state, for: id)
            }
            if let id = ids["Account Executive"] {
                try await store.screening.record(
                    ScreeningState(
                        stage: .filtered, rule: PrefilterRule.titleInclude.rawValue, reasons: ["Not one of your roles"],
                        screenedAt: now),
                    for: id)
            }
            if let id = ids["Senior Data Engineer"] {
                try await store.screening.record(
                    ScreeningState(
                        stage: .filtered, rule: PrefilterRule.seniority.rawValue,
                        reasons: ["A senior role; you look for junior and mid."], screenedAt: now),
                    for: id)
            }
            if let id = ids["Software Developer, Payments"] { try await store.jobs.setDecision(.saved, for: id) }

            if let id = ids["Platform Engineer"] {
                let resume = TailoredResume(header: .init(name: "Jordan Rivera", headline: "Backend developer"))
                var build = BuildRecord(
                    jobID: id, mode: .strict, resumeVersion: 1, status: .done, resume: resume, score: 82, createdAt: now
                )
                build.startedAt = now.addingTimeInterval(-70)
                build.finishedAt = now
                if let renderer = workspace.renderer {
                    let pdf = try await renderer.render(ResumeDocument(FullResume(sampleResume)))
                    let url = workspace.folder.builds.appending(
                        path: "\(build.id.lowercased)/Jordan Rivera - Resume.pdf")
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try pdf.data.write(to: url)
                    build.files = [
                        .init(kind: .resume, path: workspace.folder.relative(url), sha256: StableID.sha256(pdf.data))
                    ]
                }
                try await store.builds.save(build)
                var interview = try await store.applications.apply(
                    Application(
                        jobID: id, buildID: build.id, appliedAt: now.addingTimeInterval(-86_400 * 9),
                        channel: "Company site"))
                interview.status = .interview
                interview.nextStep = "Technical interview, Tuesday 10:00"
                try await store.applications.save(interview, note: "Booked with the hiring manager")
            }
            if let id = ids["Full Stack Developer"] {
                var waiting = try await store.applications.apply(
                    Application(jobID: id, appliedAt: now.addingTimeInterval(-86_400 * 3)))
                waiting.followUpAt = now.addingTimeInterval(86_400 * 4)
                try await store.applications.save(waiting)
            }
            return ids
        }

        static var sampleResume: MasterResume {
            var header = ResumeHeader()
            header.fullName = "Jordan Rivera"
            header.email = "jordan.rivera@example.com"
            header.phone = "+14165550123"
            header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
            header.gitHubURL = "https://github.com/jrivera"
            header.city = "Toronto"
            header.region = "ON"
            header.country = "CA"
            header.headline = "Backend developer who ships reliable services"
            header.highlights = "Five years building event-driven services in Go and Python for logistics and fintech."
            header.totalYears = 5
            return MasterResume(
                header: header,
                entries: [
                    ResumeEntry(
                        fields: .experience(
                            .init(
                                employer: "Harbourline Logistics", title: "Software Developer, Backend",
                                location: "Toronto, ON")),
                        start: YearMonth("2022-03"), isCurrent: true,
                        bullets: [
                            ResumeBullet(
                                text: "Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms.",
                                metrics: ["4.2M events a day"], skills: ["Go", "Kafka"]),
                            ResumeBullet(
                                text:
                                    "Moved 40 services to Kubernetes with zero-downtime deploys and PostgreSQL failover.",
                                metrics: ["40 services"], skills: ["Kubernetes", "PostgreSQL"]),
                        ]),
                    ResumeEntry(
                        fields: .experience(
                            .init(employer: "Maplewood Pay", title: "Junior Developer", location: "Waterloo, ON")),
                        start: YearMonth("2020-06"), end: YearMonth("2022-02"),
                        bullets: [
                            ResumeBullet(
                                text: "Wrote the Python reconciliation job that matched 98% of payouts without review.",
                                metrics: ["98%"], skills: ["Python", "PostgreSQL"])
                        ]),
                    ResumeEntry(
                        fields: .education(
                            .init(
                                institution: "University of Waterloo", credential: "BMath", field: "Computer Science",
                                location: "Waterloo, ON", honours: "", coursework: [])),
                        start: YearMonth("2016-09"), end: YearMonth("2020-04")),
                ],
                skills: ["Go", "Python", "PostgreSQL", "Kafka", "gRPC", "Docker"].map { Skill(name: $0) } + [
                    Skill(name: "Rust", level: .canDiscuss)
                ])
        }
    }
#endif
