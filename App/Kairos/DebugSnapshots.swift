#if DEBUG
    import AppKit
    import LLM
    import MasterResume
    import Pipeline
    import Render
    import Screening
    import Store
    import SwiftUI
    import Tailoring

    /// Debug builds only: `Kairos --render-snapshots [--print=<name>]` draws screens offscreen, in light
    /// and dark, to PNGs in the app's temporary folder, then quits before any window opens. It lets
    /// screens be checked from the terminal. The data is the design's sample persona (previews only).
    enum DebugSnapshots {
        /// A build whose experience fell back to Flash-Lite, whose rewrite was skipped, and whose
        /// letter is still being written.
        static func sampleActivity() -> BuildActivity {
            let flash = ModelRef(provider: "gemini", model: "gemini-flash-latest")
            let lite = ModelRef(provider: "gemini", model: "gemini-flash-lite-latest")
            let start = Date().addingTimeInterval(-40)
            var activity = BuildActivity()
            activity.apply(.asking(task: .writeExperience, model: flash, fallback: false), at: start)
            activity.apply(.asking(task: .writeSkills, model: flash, fallback: false), at: start)
            activity.apply(.answered(task: .writeSkills, model: flash, seconds: 6, cached: false), at: start + 6)
            activity.apply(
                .retrying(task: .writeExperience, model: flash, reason: "was overloaded (503)"), at: start + 8)
            activity.apply(
                .failed(task: .writeExperience, model: flash, reason: "was overloaded (503)", detail: nil),
                at: start + 12)
            activity.apply(.asking(task: .writeExperience, model: lite, fallback: true), at: start + 12)
            activity.apply(.answered(task: .writeExperience, model: lite, seconds: 7, cached: false), at: start + 19)
            activity.apply(.asking(task: .rewriteSection, model: lite, fallback: false), at: start + 20)
            activity.apply(
                .failed(task: .rewriteSection, model: lite, reason: "didn't answer in time", detail: nil),
                at: start + 30)
            activity.apply(.asking(task: .coverLetter, model: lite, fallback: false), at: start + 31)
            return activity
        }

        @MainActor static func runIfRequested() {
            guard CommandLine.arguments.contains("--render-snapshots") else { return }
            let folder = FileManager.default.temporaryDirectory.appending(path: "snapshots")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard let db = try? Database(path: ":memory:") else { exit(1) }
            let resume = ResumeModel(preview: sampleResume(), db: db)
            let page = HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.space6) {
                    ContactSection()
                    Divider()
                    EntrySection(
                        title: "Experience", kinds: [.experience, .project], editing: .constant(nil),
                        deleting: .constant(nil))
                    Divider()
                    SkillsSection()
                    Divider()
                    AdditionalSections(editing: .constant(nil), deleting: .constant(nil))
                }
                .padding(Spacing.space6)
                .frame(width: 760, alignment: .leading)
                Divider()
                ReadinessPanel(resume: resume.resume, readiness: resume.readiness).frame(width: 300)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(.surface))
            .environment(resume)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(page, to: folder.appending(path: "master-resume-\(name).png"), appearance: appearance)
                if let job = resume.resume.entries(.experience).first {
                    render(
                        EntryEditor(entry: job).environment(resume).background(Color(.surface)),
                        to: folder.appending(path: "entry-editor-\(name).png"), appearance: appearance)
                }
            }
            if let draft = sampleDraft() {
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    render(
                        ImportReviewView(session: ImportSession(preview: draft)).environment(resume)
                            .background(Color(.surface)),
                        to: folder.appending(path: "import-review-\(name).png"), appearance: appearance)
                }
            }
            let ai = sampleAISettings(db: db)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(
                    ProvidersView().environment(ai).frame(width: 980, height: 1_640).background(Color(.surface)),
                    to: folder.appending(path: "ai-settings-\(name).png"), appearance: appearance)
                render(
                    ScrollView { TaskRoutingView().padding(Spacing.space6) }.environment(ai)
                        .frame(width: 980, height: 1_500).background(Color(.surface)),
                    to: folder.appending(path: "ai-routing-\(name).png"), appearance: appearance)
            }
            let today = sampleToday(resume: resume)
            // S14: a resume without a phone or LinkedIn keeps Build blocked, and says why.
            var unfinished = resume.resume
            unfinished.header.phone = ""
            unfinished.header.linkedInURL = ""
            let blocked = AppModel(
                preview: today.model.jobs, screenings: today.model.screenings, sources: today.model.sources,
                resume: ResumeModel(preview: unfinished, db: db))
            // T40: the same job as Adzuna found it, with its snippet note and credit.
            let adzuna = Source(id: UUID(), kind: .adzuna, config: "{}")
            var adzunaJob = today.selected
            adzunaJob.sourceID = adzuna.id
            let fromAdzuna = AppModel(
                preview: [adzunaJob], screenings: today.model.screenings, sources: [adzuna], resume: resume)
            let stored = StoredAnalysis(
                analysis: today.analysis, model: "gemini-flash-lite-latest", promptVersion: 2,
                analyzedAt: Date().addingTimeInterval(-3_600))
            // Job collection v2: the job on its company's board and on Adzuna, with its history.
            let job = today.selected
            let posted = AppModel(
                preview: today.model.jobs, screenings: today.model.screenings,
                sources: today.model.sources + [adzuna], resume: resume)
            let listings = [
                Listing(
                    canonicalURL: job.canonicalURL, jobID: job.id, sourceID: job.sourceID, url: job.url,
                    title: job.title,
                    company: job.company, location: job.location, postedAt: job.postedAt, descriptionMarkdown: nil,
                    descriptionKind: .full, firstSeenAt: Date().addingTimeInterval(-3 * 86_400),
                    lastSeenAt: Date().addingTimeInterval(-3_600)),
                Listing(
                    canonicalURL: "https://www.adzuna.ca/land/ad/5123", jobID: job.id, sourceID: adzuna.id,
                    url: "https://www.adzuna.ca/land/ad/5123", title: job.title, company: job.company,
                    location: job.location, postedAt: job.postedAt, descriptionMarkdown: nil, descriptionKind: .snippet,
                    firstSeenAt: Date().addingTimeInterval(-2 * 86_400), lastSeenAt: Date().addingTimeInterval(-86_400)),
            ]
            let history = [
                JobEvent(
                    jobID: job.id, at: Date().addingTimeInterval(-3 * 86_400), kind: .found, sourceID: job.sourceID),
                JobEvent(
                    jobID: job.id, at: Date().addingTimeInterval(-2 * 86_400), kind: .postedElsewhere,
                    sourceID: adzuna.id),
            ]
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(
                    ReviewView().environment(today.model).frame(width: 1_440, height: 560),
                    to: folder.appending(path: "review-\(name).png"), appearance: appearance)
                render(
                    FilteredOutView().environment(today.model).frame(width: 1_440, height: 420),
                    to: folder.appending(path: "filtered-out-\(name).png"), appearance: appearance)
                render(
                    NavigationStack { FetchView() }.environment(today.model).frame(width: 1_440, height: 640),
                    to: folder.appending(path: "fetch-\(name).png"), appearance: appearance)
                render(
                    NavigationStack {
                        JobScreen(id: today.selected.id, preview: stored, listings: listings, history: history)
                    }
                    .environment(posted)
                    .frame(width: 1_200, height: 1_700),
                    to: folder.appending(path: "job-\(name).png"), appearance: appearance)
                render(
                    NavigationStack { JobScreen(id: today.selected.id, preview: stored) }.environment(blocked)
                        .frame(width: 1_200, height: 700),
                    to: folder.appending(path: "job-blocked-\(name).png"), appearance: appearance)
                render(
                    SearchPreferencesView().environment(today.model).frame(width: 820, height: 1_500)
                        .background(Color(.surface)),
                    to: folder.appending(path: "search-settings-\(name).png"), appearance: appearance)
                render(
                    AdzunaSheet().environment(today.model).background(Color(.surface)),
                    to: folder.appending(path: "adzuna-sheet-\(name).png"), appearance: appearance)
                render(
                    NavigationStack { JobScreen(id: adzunaJob.id, preview: stored) }.environment(fromAdzuna)
                        .frame(width: 1_200, height: 700),
                    to: folder.appending(path: "job-adzuna-\(name).png"), appearance: appearance)
            }
            // T45: applications across the board, one with a follow-up due today.
            let (tracked, timeline) = sampleApplications(jobs: today.model.jobs)
            let tracking = AppModel(
                preview: today.model.jobs, screenings: today.model.screenings, sources: today.model.sources,
                resume: resume, applications: tracked)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(
                    ApplicationsView().environment(tracking).frame(width: 1_440, height: 520),
                    to: folder.appending(path: "applications-\(name).png"), appearance: appearance)
                if let first = tracked.first {
                    render(
                        NavigationStack { ApplicationScreen(id: first.id, preview: timeline) }.environment(tracking)
                            .frame(width: 1_200, height: 1_100),
                        to: folder.appending(path: "application-\(name).png"), appearance: appearance)
                }
            }
            let build = sampleBuild(resume: resume.resume, job: today.selected)
            let pdf = renderNow(
                ResumeDocument(build.content ?? TailoredResume(header: .init(name: "")), for: .standard), in: folder)
            let stretched = sampleBuild(resume: resume.resume, job: today.selected, stretch: true)
            let stretchedPDF = renderNow(
                ResumeDocument(stretched.content ?? TailoredResume(header: .init(name: "")), for: .standard),
                in: folder,
                name: "build-stretch")
            let stretchModel = AppModel(
                preview: today.model.jobs, screenings: [:], sources: today.model.sources,
                stretch: StretchSettings(enabled: true, perRole: 2), resume: resume)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(
                    BuildView(
                        build: build, job: today.selected, pdf: pdf, step: nil, master: resume.resume, letter: true,
                        selected: 0
                    )
                    .environment(today.model)
                    .frame(width: 1_340, height: 860),
                    to: folder.appending(path: "build-\(name).png"), appearance: appearance)
                render(
                    BuildView(
                        build: build, job: today.selected, pdf: pdf, step: nil, master: resume.resume, letter: true,
                        activity: sampleActivity()
                    )
                    .environment(today.model)
                    .frame(width: 1_340, height: 860),
                    to: folder.appending(path: "build-activity-\(name).png"), appearance: appearance)
                render(
                    BuildView(
                        build: stretched, job: today.selected, pdf: stretchedPDF, step: nil, master: resume.resume,
                        selected: 3
                    )
                    .environment(stretchModel)
                    .frame(width: 1_340, height: 900),
                    to: folder.appending(path: "build-stretch-\(name).png"), appearance: appearance)
                render(
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.space6) {
                            ResumeLengthView()
                            StretchModeView()
                        }
                        .padding(Spacing.space6)
                    }
                    .environment(stretchModel)
                    .frame(width: 820, height: 760).background(Color(.surface)),
                    to: folder.appending(path: "general-settings-\(name).png"), appearance: appearance)
            }
            print("snapshots: \(folder.path)")
            // `--print=<name>`: the snapshots whose file names start with it, as base64, for a terminal
            // that macOS keeps out of the app's container.
            if let prefix = CommandLine.arguments.first(where: { $0.hasPrefix("--print=") })?.dropFirst(8),
                let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            {
                for file in files.sorted() where file.hasPrefix(prefix) {
                    guard let data = FileManager.default.contents(atPath: folder.appending(path: file).path) else {
                        continue
                    }
                    print("snapshot \(file) \(data.base64EncodedString())")
                }
            }
            exit(0)
        }

        @MainActor private static func render(_ view: some View, to url: URL, appearance: NSAppearance.Name) {
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
            // The container is closed to other processes, so the terminal gets a copy on stdout.
            print("SNAPSHOT \(url.lastPathComponent) \(png.base64EncodedString())")
        }

        /// A draft as the import task would return it (sample data).
        private static func sampleDraft() -> ImportDraft? {
            let json = """
                {"headline":"Backend developer","total_years":5,
                 "experience":[{"title":"Software Developer, Backend","employer":"Harbourline Logistics","location":"Toronto, ON",
                   "start":"2022-03","current":true,"bullets":["Built an event pipeline handling 4.2M events a day",
                   "Onboarded 11 carriers in 4 days instead of 3 weeks","Migrated 14 services to Kubernetes"]}],
                 "projects":[{"name":"Dockyard","role":"Author","start":"2023","current":true,"bullets":["Open-source Go CLI"]}],
                 "education":[{"institution":"University of Waterloo","credential":"BMath","field":"Computer Science","start":"2015","end":"2019"}],
                 "skills":[{"name":"Go","level":"proven"},{"name":"PostgreSQL","level":"proven"},{"name":"Kafka","level":"can_discuss"}],
                 "languages":[{"language":"French","proficiency":"conversational"}]}
                """
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return (try? decoder.decode(ImportResumeTask.Output.self, from: Data(json.utf8))).map(ImportDraft.init)
        }

        /// Today with the design's sample companies (fictional), screened as screening would.
        @MainActor private static func sampleToday(resume: ResumeModel) -> (
            model: AppModel, selected: Job, analysis: JobAnalysis
        ) {
            let source = Source(id: UUID(), kind: .greenhouse, config: "{}")
            func job(
                _ title: String, _ company: String, _ city: String, _ region: String, _ country: Country,
                _ work: RemoteScope, _ verdict: Verdict, rank: Double
            ) -> Job {
                Job(
                    canonicalURL: "https://jobs.example.com/\(company)/\(title)", sourceID: source.id,
                    url: "https://jobs.example.com/1", dedupKey: "\(company)|\(title)", company: company, title: title,
                    location: "\(city), \(region)", city: city, region: region, country: country, remoteScope: work,
                    postedAt: Date().addingTimeInterval(-2 * 86_400),
                    descriptionMarkdown: "Build the services that track two million shipments a day.", verdict: verdict,
                    verdictSource: .analysis, rank: rank, firstSeenAt: Date())
            }
            var jobs = [
                job("Backend Developer II", "Northline Freight", "Toronto", "ON", .canada, .hybrid, .yes, rank: 220.92),
                job(
                    "Software Developer, Platform", "Cobalt Ledger", "Waterloo", "ON", .canada, .hybrid, .maybe,
                    rank: 120.76),
                job(
                    "Développeur back-end", "Quillstone Média", "Montréal", "QC", .canada, .remoteCountry, .no, rank: 20
                ),
                job(
                    "Backend Engineer, Integrations", "Fernhill Robotics", "Boston", "MA", .unitedStates, .remote, .yes,
                    rank: 210.86),
                job(
                    "Senior Backend Engineer", "Kestrel Analytics", "New York", "NY", .unitedStates, .onsite, .no,
                    rank: 10.35),
            ]
            jobs[2].verdictSource = .prefilter  // the French posting never reached the AI
            func record(_ verdict: Verdict, _ stage: VerdictSource, _ reasons: [String], _ coverage: Coverage?)
                -> ScreeningRecord
            {
                ScreeningRecord(
                    stage: stage, verdict: verdict, ruleID: nil, coverage: coverage, reasons: reasons, at: Date())
            }
            let screenings = [
                jobs[0].id.rawValue: record(
                    .yes, .analysis, ["Covers 4 of 4 must-haves and 1 of 2 nice-to-haves.", "French is an asset."],
                    Coverage(mustCovered: 4, mustTotal: 4, niceCovered: 1, niceTotal: 2)),
                jobs[1].id.rawValue: record(
                    .maybe, .analysis, ["Missing Java", "Covers 2 of 3 must-haves and 0 of 1 nice-to-haves."],
                    Coverage(mustCovered: 2, mustTotal: 3, niceCovered: 0, niceTotal: 1)),
                jobs[2].id.rawValue: ScreeningRecord(
                    stage: .prefilter, verdict: .no, ruleID: "french", coverage: nil,
                    reasons: ["Written in French, which isn't among your languages."], at: Date()),
                jobs[3].id.rawValue: record(
                    .yes, .analysis, ["Covers 3 of 3 must-haves and 1 of 3 nice-to-haves."],
                    Coverage(mustCovered: 3, mustTotal: 3, niceCovered: 1, niceTotal: 3)),
                jobs[4].id.rawValue: record(
                    .no, .analysis,
                    [
                        "Won't sponsor a visa, and you'd need one in the US.",
                        "Covers 2 of 3 must-haves and 0 of 0 nice-to-haves.",
                        "Possible TN route: as a Canadian citizen you may qualify for TN status for some professions.",
                    ], Coverage(mustCovered: 2, mustTotal: 3, niceCovered: 0, niceTotal: 0)),
            ]
            var preferences = SearchPreferences()
            preferences.titleInclude = ["Backend Developer", "Software Engineer, Backend", "Platform Engineer"]
            preferences.titleExclude = ["Principal", "Manager", "Director", "Intern"]
            preferences.regions = ["CA": ["ON", "BC"]]
            preferences.maxYearsRequired = 8
            let model = AppModel(
                preview: jobs, screenings: screenings, sources: [source], preferences: preferences,
                profile: WorkProfile(authorization: [.canada: .citizen, .unitedStates: .needsSponsorship]),
                resume: resume)
            // Prompt v2's shape. Ids follow the sample resume's screening profile: s1 Go, s3 PostgreSQL,
            // s4 RabbitMQ, s5 gRPC, c2 Terraform, x1b1 the event pipeline, x1b3 Kubernetes.
            func requirement(
                _ text: String, _ kind: JobAnalysis.Requirement.Kind, _ category: JobAnalysis.Requirement.Category,
                _ match: JobAnalysis.Requirement.Match, _ evidence: [String] = []
            ) -> JobAnalysis.Requirement {
                .init(text: text, kind: kind, category: category, match: match, evidence: evidence)
            }
            let analysis = JobAnalysis(
                requirements: [
                    requirement("3+ years building services in Go or Java", .must, .experience, .yes, ["s1", "x1b1"]),
                    requirement("PostgreSQL in production", .must, .skill, .yes, ["s3"]),
                    requirement("Message queues such as RabbitMQ or Kafka", .must, .skill, .yes, ["s4"]),
                    requirement("Designing REST or gRPC APIs", .must, .experience, .partial, ["s5"]),
                    requirement("Legally entitled to work in Canada", .must, .authorization, .notJudged),
                    requirement("Clear written communication", .must, .soft, .notJudged),
                    requirement("Kubernetes", .nice, .skill, .partial, ["x1b3"]),
                    requirement("Terraform", .nice, .skill, .partial, ["c2"]),
                    requirement("French", .nice, .language, .no),
                ], yearsRequired: 3, seniority: .mid, domains: ["logistics"],
                flags: .init(sponsorship: .notOffered, clearance: .notMentioned, french: .asset, remoteScope: .hybrid))
            return (model, jobs[0], analysis)
        }

        /// A finished build of the sample resume for Northline's posting (fictional): strict, or
        /// Stretch with one gap bullet for Terraform.
        private static func sampleBuild(resume: MasterResume, job: Job, stretch: Bool = false) -> BuildRecord {
            let role = resume.entries(.experience)[0]
            let project = resume.entries(.project)[0]
            let texts = [
                "Built an event pipeline in Go and PostgreSQL handling 4.2M events a day at p99 under 120 ms.",
                "Cut carrier onboarding from 3 weeks to 4 days for 11 carriers with a gRPC integration kit.",
                "Moved 14 services to Kubernetes with Kafka event streaming.",
            ]
            let content = TailoredResume(
                header: TailoredResume.Header(resume.header),
                summary: "Backend developer with 6 years building Go and PostgreSQL services for logistics.",
                skills: [
                    SkillGroup(label: "Languages", skills: ["Go", "Python"]),
                    SkillGroup(label: "Data and messaging", skills: ["PostgreSQL", "RabbitMQ", "gRPC"]),
                ],
                experience: [
                    TailoredResume.Entry(
                        entryID: role.id, title: "Software Developer, Backend", organization: "Harbourline Logistics",
                        location: "Toronto, ON", dates: "Mar 2022 – Present",
                        bullets: zip(texts, role.bullets).map { TailoredBullet(text: $0, sourceIDs: [$1.id]) }
                            + (stretch
                                ? [
                                    TailoredBullet(
                                        text:
                                            "Wrote Terraform modules for the event pipeline's three environments, cutting setup time by about 30%.",
                                        sourceIDs: [], gap: true, covers: "Terraform")
                                ] : []))
                ],
                projects: [
                    TailoredResume.Entry(
                        entryID: project.id, title: "Dockyard", organization: "Go", dates: "Jan 2023 – Present",
                        bullets: [
                            TailoredBullet(
                                text: "Open-source Go CLI for cleaning up local Docker resources.",
                                sourceIDs: [project.bullets[0].id])
                        ])
                ],
                certifications: [
                    TailoredResume.Entry(entryID: UUID(), title: "AWS Solutions Architect Associate", dates: "2024")
                ],
                languages: "French (conversational)")
            let requirements = JobRequirements(
                musts: [
                    "3+ years building services in Go", "Strong PostgreSQL", "Message queues such as RabbitMQ or Kafka",
                ],
                nices: ["Kubernetes", "Terraform"], domains: ["logistics"])
            return BuildRecord(
                id: UUID(), jobID: job.id.rawValue, mode: stretch ? .stretch : .strict, masterVersion: 11,
                status: .done,
                content: content,
                score: MatchScore.score(content, for: requirements, pages: 1), iterations: 1, error: nil,
                createdAt: Date(), finishedAt: Date(),
                coverLetter: stretch
                    ? nil
                    : CoverLetterRecord(
                        status: .done,
                        letter: CoverLetter(
                            header: content.header, date: "October 20, 2026", company: job.company,
                            jobTitle: job.title, greeting: "Dear \(job.company) hiring team,",
                            paragraphs: ["One.", "Two.", "Three."], closing: "Sincerely,",
                            signature: content.header.name)))
        }

        /// Renders with the bundled typst, blocking: fine for a debug snapshot, never for the app.
        /// Sample applications on the given jobs (sample persona, previews only), and the first one's
        /// timeline.
        private static func sampleApplications(jobs: [Job]) -> ([Application], [ApplicationEvent]) {
            let now = Date()
            func days(_ n: Double) -> Date { now.addingTimeInterval(n * 86_400) }
            let plan: [(ApplicationStatus, Double, Date?, String?)] = [
                (.interview, -7, days(0), "Send a thank-you note"), (.applied, -5, days(2), "Email the recruiter"),
                (.applied, -9, nil, nil), (.screen, -3, nil, nil), (.offer, -6, days(4), "Reply to the offer"),
                (.rejected, -12, nil, nil),
            ]
            let applications = zip(jobs, plan).map { job, step in
                Application(
                    id: UUID(), jobID: job.id, appliedAt: days(step.1 - 14), channel: "Greenhouse", status: step.0,
                    statusAt: days(step.1), nextActionAt: step.2, nextAction: step.3,
                    notes: step.0 == .interview
                        ? "Team is splitting a monolith into event-driven services. Ask about on-call." : "")
            }
            guard let first = applications.first else { return ([], []) }
            let timeline = [
                ApplicationEvent(id: UUID(), applicationID: first.id, kind: .status(.applied), at: first.appliedAt),
                ApplicationEvent(
                    id: UUID(), applicationID: first.id, kind: .status(.screen), at: days(-12),
                    note: "30 min with the recruiter"),
                ApplicationEvent(
                    id: UUID(), applicationID: first.id, kind: .status(.interview), at: days(-7),
                    note: "Go and SQL pair-coding, 60 min"),
                ApplicationEvent(
                    id: UUID(), applicationID: first.id, kind: .note, at: days(-2), note: "System design next week"),
            ]
            return (applications, timeline)
        }

        private static func renderNow(_ document: ResumeDocument, in folder: URL, name: String = "build") -> URL? {
            guard let typst = Bundle.main.url(forAuxiliaryExecutable: "typst"), let fonts = TypstRunner.bundledFonts,
                let template = try? ResumeTemplate.standard.source(), let data = try? JSONEncoder().encode(document)
            else { return nil }
            let work = folder.appending(path: "\(name)-render")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try? Data(template.utf8).write(to: work.appending(path: "template.typ"))
            try? data.write(to: work.appending(path: "data.json"))
            let output = work.appending(path: "build.pdf")
            let process = Process()
            process.executableURL = typst
            process.arguments = [
                "compile", "--root", work.path, "--input", "data=data.json", "--ignore-system-fonts", "--font-path",
                fonts.path, work.appending(path: "template.typ").path, output.path,
            ]
            try? process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? output : nil
        }

        /// Sample keys are made-up strings shown masked; nothing here is a real key.
        @MainActor private static func sampleAISettings(db: Database) -> AISettingsModel {
            var settings = LLMSettings.defaults()
            settings.providers[0].keyNames = ["llm.gemini.primary", "llm.gemini.backup"]
            settings.providers.append(
                LLMSettings.Provider(
                    id: "ollama-cloud", presetID: "ollama-cloud", keyNames: ["llm.ollama-cloud.primary"]))
            settings.routes["writeExperience"] = [
                ModelRef(provider: "gemini", model: "gemini-flash-latest"),
                ModelRef(provider: "ollama-local", model: "qwen3.5:4B"),
            ]
            // The primary used up its Flash quota; the backup carries on.
            let rests = KeyRests()
            rests.rest(
                key: "llm.gemini.primary", model: "gemini-flash-latest", until: SystemClock().now + .seconds(26_000))
            // Bars from the same code the app runs: the primary refused for Flash, Google named the
            // backup's limit, and the Ollama account spent a little of its month.
            let now = Date()
            let gemini = ProviderPreset.gemini
            let models = ["gemini-flash-lite-latest", "gemini-flash-latest"]
            let allowances: [String: [UsageBar]] = [
                "llm.gemini.primary": gemini.dailyBars(
                    models: models,
                    use: [
                        "gemini-flash-lite-latest": KeyModelUse(calls: 312),
                        "gemini-flash-latest": KeyModelUse(
                            calls: 20, limit: 20, refused: true, back: now.addingTimeInterval(26_000)),
                    ], now: now),
                "llm.gemini.backup": gemini.dailyBars(
                    models: models,
                    use: [
                        "gemini-flash-lite-latest": KeyModelUse(calls: 40),
                        "gemini-flash-latest": KeyModelUse(calls: 6),
                    ],
                    now: now),
                "llm.ollama-cloud.primary": CreditBalance(
                    included: 2.41, allowance: 2.50, periodEnd: now.addingTimeInterval(6 * 86_400), purchased: 0
                ).bars,
            ]
            return AISettingsModel(
                preview: settings,
                models: [
                    "gemini": .loaded([
                        "gemini-flash-latest", "gemini-flash-lite-latest", "gemini-3.5-flash", "gemini-2.5-flash",
                    ]),
                    "ollama-local": .loaded(["qwen3.5:4B"]),
                    // Ollama's own list, 2026-10-23.
                    "ollama-cloud": .loaded(ModelGuide.ollamaCloud.map(\.model)),
                ],
                usage: [
                    "gemini": Usage(calls: 131, tokens: 48_000), "ollama-local": Usage(calls: 12, tokens: 9_000),
                    "ollama-cloud": Usage(calls: 24, tokens: 110_000),
                ],
                masked: [
                    "llm.gemini.primary": "AIza••••••••••••Q2xk", "llm.gemini.backup": "AIza••••••••••••7mPa",
                    "llm.ollama-cloud.primary": "8f2c••••••••••••d41e",
                ],
                keyChecks: [
                    "llm.gemini.primary": .works, "llm.gemini.backup": .works, "llm.ollama-cloud.primary": .works,
                ],
                rests: ["gemini": rests], spent: ["ollama-cloud": 0.04],
                // Flash overloaded today; Flash-Lite and gemma fine.
                health: [
                    ModelRef(provider: "gemini", model: "gemini-flash-latest"): .init(
                        calls: 9, failed: 7, averageSeconds: 41),
                    ModelRef(provider: "gemini", model: "gemini-flash-lite-latest"): .init(
                        calls: 52, failed: 1, averageSeconds: 6),
                    ModelRef(provider: "ollama-cloud", model: "gemma4:31b"): .init(
                        calls: 24, failed: 0, averageSeconds: 9),
                ], allowances: allowances, db: db
            )
        }

        private static func sampleResume() -> MasterResume {
            var header = ResumeHeader()
            header.fullName = "Jordan Rivera"
            header.email = "jordan@example"
            header.phone = "+14165550123"
            header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
            header.portfolioURL = "http://jordan.dev"
            header.headline = "Backend developer"
            header.totalYears = 6
            let job = ResumeEntry(
                fields: .experience(.init(employer: "Harbourline Logistics", title: "Software Developer, Backend")),
                start: YearMonth(year: 2022, month: 3), isCurrent: true,
                bullets: [
                    ResumeBullet(
                        text: "Built an event pipeline handling 4.2M events a day",
                        metrics: ["4.2M events/day", "p99 < 120 ms"], skills: ["Go", "PostgreSQL", "RabbitMQ"]),
                    ResumeBullet(
                        text: "Onboarded 11 carriers in 4 days instead of 3 weeks", metrics: ["11 carriers"],
                        skills: ["gRPC"]),
                    ResumeBullet(text: "Migrated 14 services to Kubernetes", skills: ["Kafka"]),
                    ResumeBullet(text: "Led the five-person on-call rotation"),
                ])
            let project = ResumeEntry(
                fields: .project(.init(name: "Dockyard", role: "Author", tech: ["Go"])),
                start: YearMonth(year: 2023, month: 1), isCurrent: true,
                bullets: [ResumeBullet(text: "Open-source CLI for cleaning up local Docker resources")])
            let skills =
                ["Go", "Python", "PostgreSQL", "RabbitMQ", "gRPC"].map { Skill(name: $0, category: "Language") }
                + ["Kafka", "Terraform", "Rust"].map { Skill(name: $0, level: .canDiscuss) }
            let extras = [
                ResumeEntry(
                    fields: .certification(
                        .init(name: "AWS Solutions Architect Associate", issuer: "Amazon Web Services")),
                    start: YearMonth(year: 2024, month: 5)),
                ResumeEntry(fields: .language(.init(language: "French", proficiency: .conversational))),
            ]
            return MasterResume(header: header, entries: [job, project] + extras, skills: skills, version: 12)
        }
    }
#endif
