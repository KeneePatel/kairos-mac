#if DEBUG
    import AppKit
    import LLM
    import Pipeline
    import SwiftUI
    import Tailoring

    /// Debug builds only: `Kairos --layout-probe` opens the real window on your data, visits every
    /// section and Settings tab, and prints the smallest window each one allows, then quits. A screen
    /// whose minimum is taller than the display pushes the window off it (Find jobs did, 2026-10-22),
    /// and offscreen snapshots can't show that: they have no window. Exits 1 if any section needs more
    /// than `limit` points. AI providers lists models over the network, so it's visited only with `--ai`;
    /// `--size=900x600` sets the window's content size before the closing snapshot of Find jobs;
    /// `--screens` first snapshots screens with their toolbars (see `screens`).
    enum DebugLayoutProbe {
        /// A 13-inch MacBook Air's visible height, less room for a large Dock.
        static let limit: CGFloat = 640

        @MainActor static func runIfRequested(_ model: AppModel) async {
            guard CommandLine.arguments.contains("--layout-probe") else { return }
            setvbuf(stdout, nil, _IOLBF, 0)
            while model.phase != .ready { try? await Task.sleep(for: .milliseconds(100)) }
            if CommandLine.arguments.contains("--screens") { await screens(model) }
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }) else { exit(1) }
            let tabs = SettingsView.Tab.allCases.filter { $0 != .ai || CommandLine.arguments.contains("--ai") }
            var steps: [(String, () -> Void)] = AppSection.allCases.filter { $0 != .settings }.map { section in
                (section.rawValue, { model.section = section })
            }
            steps += tabs.map { tab in
                (
                    "settings.\(tab)",
                    {
                        model.settingsTab = tab
                        model.section = .settings
                    }
                )
            }
            var tooTall: [String] = []
            for (name, step) in steps {
                step()
                try? await Task.sleep(for: .seconds(1))
                let height = window.contentMinSize.height
                print("PROBE \(name) needs at least \(Int(window.contentMinSize.width)) x \(Int(height))")
                if height > limit { tooTall.append(name) }
            }
            tooTall += await buildScreens(model)
            model.section = .sources
            if let size = CommandLine.arguments.first(where: { $0.hasPrefix("--size=") })?.dropFirst(7)
                .split(separator: "x").compactMap({ Double($0) }), size.count == 2
            {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            try? await Task.sleep(for: .seconds(1))
            snapshot(window)
            print(tooTall.isEmpty ? "PROBE ok" : "PROBE too tall: \(tooTall.joined(separator: ", "))")
            exit(tooTall.isEmpty ? 0 : 1)
        }

        /// `--screens`: screens offscreen snapshots can't show whole, each in a titled window with its
        /// toolbar: Review, Improve, a job with a resume and that job's resume page, a job without one.
        @MainActor private static func screens(_ model: AppModel) async {
            let built = model.reviewJobs(.all).first { model.latestBuild(for: $0)?.status == .done }
            let unbuilt = model.reviewJobs(.yes).first { model.latestBuild(for: $0) == nil }
            var shown: [(String, AnyView)] = [
                ("inbox", AnyView(JobsView(scope: .inbox))), ("resumes", AnyView(ResumesView())),
                ("improve", AnyView(ImproveView())),
            ]
            if let built {
                shown.append(("job-built", AnyView(NavigationStack { JobScreen(id: built.id) })))
                shown.append(("job-resume", AnyView(NavigationStack { BuildsView(job: built.id) })))
            }
            if let unbuilt { shown.append(("job-unbuilt", AnyView(NavigationStack { JobScreen(id: unbuilt.id) }))) }
            for (name, view) in shown {
                let host = NSHostingView(rootView: view.environment(model))
                host.sceneBridgingOptions = [.toolbars, .title]
                host.sizingOptions = [.minSize]  // keep the window's size, as the app's window does
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.contentView = host
                window.toolbarStyle = .unified
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                window.setContentSize(NSSize(width: 1280, height: 720))
                try? await Task.sleep(for: .seconds(1.5))
                print("PROBE screen \(name) \(window.frame.size)")
                snapshot(window, name: "screen-\(name)")
                // A long list's end too: its last sections.
                if name == "improve",
                    let list = scrollViews(in: window.contentView).first(where: { $0.frame.minX < 10 }),
                    let document = list.documentView
                {
                    list.contentView.scroll(
                        to: NSPoint(x: 0, y: max(0, document.frame.height - list.contentView.bounds.height)))
                    list.reflectScrolledClipView(list.contentView)
                    try? await Task.sleep(for: .seconds(1))
                    snapshot(window, name: "screen-\(name)-end")
                }
                window.orderOut(nil)
            }
        }

        /// The Build screen with fallback notes above the PDF, for a finished build and a failed one
        /// when you have them: wrapped notes there made the window's minimum 1,393 pt for a single
        /// note and pushed half the resume off the screen (2026-10-26).
        @MainActor private static func buildScreens(_ model: AppModel) async -> [String] {
            var activity = BuildActivity()
            let first = ModelRef(provider: "ollama", model: "gemma4:31b")
            let second = ModelRef(provider: "gemini", model: "gemini-flash-lite-latest")
            for task in [TaskID.writeExperience, .writeSkills, .coverLetter] {
                activity.apply(.asking(task: task, model: first, fallback: false), at: Date())
                activity.apply(
                    .failed(task: task, model: first, reason: "gave an answer that didn't fit the format", detail: nil),
                    at: Date())
                activity.apply(.asking(task: task, model: second, fallback: true), at: Date())
                activity.apply(.answered(task: task, model: second, seconds: 1, cached: false), at: Date())
            }
            var tooTall: [String] = []
            for status in [BuildStatus.done, .failed] {
                guard let build = model.builds.first(where: { $0.status == status }) else { continue }
                let host = NSHostingView(
                    rootView: BuildView(build: build, job: nil, pdf: nil, step: nil, master: nil, activity: activity)
                        .environment(model))
                host.sizingOptions = [.minSize]
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1048, height: 600), styleMask: [.titled, .resizable],
                    backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                let name = "build.\(status.rawValue)-with-notes"
                print(
                    "PROBE \(name) needs at least \(Int(window.contentMinSize.width)) x \(Int(window.contentMinSize.height))"
                )
                if window.contentMinSize.height > limit { tooTall.append(name) }
                window.orderOut(nil)
            }
            return tooTall
        }

        @MainActor private static func scrollViews(in view: NSView?) -> [NSScrollView] {
            guard let view else { return [] }
            return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }

        /// The window as drawn, title bar and toolbar included.
        @MainActor private static func snapshot(_ window: NSWindow, name: String = "window") {
            guard let frame = window.contentView?.superview,
                let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
            else { return }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            print("SNAPSHOT probe-\(name).png \(png.base64EncodedString())")
        }
    }
#endif
