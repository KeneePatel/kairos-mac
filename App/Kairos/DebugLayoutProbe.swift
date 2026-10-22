#if DEBUG
    import AppKit
    import SwiftUI

    /// Debug builds only: `Kairos --layout-probe` opens the real window on your data, visits every
    /// section and Settings tab, and prints the smallest window each one allows, then quits. A screen
    /// whose minimum is taller than the display pushes the window off it (Find jobs did, 2026-10-22),
    /// and offscreen snapshots can't show that: they have no window. Exits 1 if any section needs more
    /// than `limit` points. AI providers lists models over the network, so it's visited only with `--ai`;
    /// `--size=900x600` sets the window's content size before the closing snapshot of Find jobs.
    enum DebugLayoutProbe {
        /// A 13-inch MacBook Air's visible height, less room for a large Dock.
        static let limit: CGFloat = 640

        @MainActor static func runIfRequested(_ model: AppModel) async {
            guard CommandLine.arguments.contains("--layout-probe") else { return }
            setvbuf(stdout, nil, _IOLBF, 0)
            while model.phase != .ready { try? await Task.sleep(for: .milliseconds(100)) }
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
            model.section = .fetch
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

        /// The window as drawn, title bar and toolbar included.
        @MainActor private static func snapshot(_ window: NSWindow) {
            guard let frame = window.contentView?.superview,
                let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
            else { return }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            print("SNAPSHOT probe-window.png \(png.base64EncodedString())")
        }
    }
#endif
