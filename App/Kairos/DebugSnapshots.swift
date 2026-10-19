#if DEBUG
    import AppKit
    import LLM
    import MasterResume
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

        /// Sample keys are made-up strings shown masked; nothing here is a real key.
        @MainActor private static func sampleAISettings(db: Database) -> AISettingsModel {
            var settings = LLMSettings.defaults()
            settings.providers[0].keyNames = ["llm.gemini.primary", "llm.gemini.backup"]
            settings.routes["writeExperience"] = [
                ModelRef(provider: "gemini", model: "gemini-flash-latest"),
                ModelRef(provider: "ollama-local", model: "qwen3.5:4B"),
            ]
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
                db: db)
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
