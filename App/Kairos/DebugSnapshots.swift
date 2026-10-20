#if DEBUG
    import AppKit
    import LLM
    import MasterResume
    import Screening
    import Store
    import SwiftUI

    /// Debug builds only: `Kairos --render-snapshots` draws screens offscreen, in light and dark, to
    /// PNGs in the app's temporary folder, then quits before any window opens. It lets screens be
    /// checked from the terminal. The data is the design's sample persona (previews only).
    enum DebugSnapshots {
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
            }
            let today = sampleToday()
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                render(
                    NavigationStack { TodayView() }.environment(today.model).frame(width: 1_440, height: 520),
                    to: folder.appending(path: "today-\(name).png"), appearance: appearance)
                render(
                    JobExplanationView(
                        job: today.selected, source: today.model.sources.first,
                        record: today.model.screening(for: today.selected), analysis: today.analysis,
                        score: today.model.matchScore(for: today.selected)
                    )
                    .frame(width: 420, height: 980),
                    to: folder.appending(path: "job-explanation-\(name).png"), appearance: appearance)
                render(
                    SearchPreferencesView().environment(today.model).frame(width: 820, height: 1_500)
                        .background(Color(.surface)),
                    to: folder.appending(path: "search-settings-\(name).png"), appearance: appearance)
            }
            print("snapshots: \(folder.path)")
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
        @MainActor private static func sampleToday() -> (model: AppModel, selected: Job, analysis: JobAnalysis) {
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
            let jobs = [
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
                jobs[2].id.rawValue: record(
                    .no, .prefilter, ["Written in French, which isn't among your languages."], nil),
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
                profile: WorkProfile(authorization: [.canada: .citizen, .unitedStates: .needsSponsorship]))
            let analysis = JobAnalysis(
                requirements: [
                    .init(text: "3+ years building services in Go or Java", kind: .must, matchedSkill: "Go"),
                    .init(text: "PostgreSQL in production", kind: .must, matchedSkill: "PostgreSQL"),
                    .init(text: "Message queues such as RabbitMQ or Kafka", kind: .must, matchedSkill: "Kafka"),
                    .init(text: "Designing REST or gRPC APIs", kind: .must, matchedSkill: "gRPC"),
                    .init(text: "Legally entitled to work in Canada", kind: .must),
                    .init(text: "Kubernetes", kind: .nice, matchedSkill: "Kubernetes"),
                    .init(text: "Terraform", kind: .nice),
                    .init(text: "French", kind: .nice),
                ], yearsRequired: 3, seniority: .mid, domains: ["logistics"],
                flags: .init(sponsorship: .notOffered, clearance: .notMentioned, french: .asset, remoteScope: .hybrid))
            return (model, jobs[0], analysis)
        }

        /// Sample keys are made-up strings shown masked; nothing here is a real key.
        @MainActor private static func sampleAISettings(db: Database) -> AISettingsModel {
            var settings = LLMSettings.defaults()
            settings.providers[0].keyNames = ["llm.gemini.primary", "llm.gemini.backup"]
            settings.routes["writeExperience"] = [
                ModelRef(provider: "gemini", model: "gemini-flash-latest"),
                ModelRef(provider: "ollama-local", model: "qwen3.5:4B"),
            ]
            // The primary used up its Flash quota; the backup carries on.
            let rests = KeyRests()
            rests.rest(
                key: "llm.gemini.primary", model: "gemini-flash-latest", until: SystemClock().now + .seconds(26_000))
            return AISettingsModel(
                preview: settings,
                models: [
                    "gemini": .loaded([
                        "gemini-flash-latest", "gemini-flash-lite-latest", "gemini-3.5-flash", "gemini-2.5-flash",
                    ]),
                    "ollama-local": .loaded(["qwen3.5:4B"]),
                ],
                usage: ["gemini": Usage(calls: 131, tokens: 48_000), "ollama-local": Usage(calls: 12, tokens: 9_000)],
                masked: ["llm.gemini.primary": "AIza••••••••••••Q2xk", "llm.gemini.backup": "AIza••••••••••••7mPa"],
                keyChecks: ["llm.gemini.primary": .works, "llm.gemini.backup": .works], rests: ["gemini": rests], db: db
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
