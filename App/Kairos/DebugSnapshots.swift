#if DEBUG
    import AppKit
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
                    SkillsSection()
                    Divider()
                    AdditionalSections(editing: .constant(nil))
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
                render(
                    EntryEditor(
                        entry: ResumeEntry(fields: .language(.init(language: "French", proficiency: .conversational)))
                    )
                    .environment(resume).background(Color(.surface)),
                    to: folder.appending(path: "entry-editor-\(name).png"), appearance: appearance)
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
                        text: "Built an event pipeline handling 4.2M events a day", metrics: ["4.2M events/day"])
                ])
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
            return MasterResume(header: header, entries: [job] + extras, skills: skills, version: 12)
        }
    }
#endif
