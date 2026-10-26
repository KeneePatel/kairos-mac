#if DEBUG
    import AppKit
    import JobSources
    import Pipeline
    import QuartzCore
    import Screening
    import Store
    import SwiftUI

    /// Debug builds only: `Kairos --select-probe` opens the real window on your data at the Inbox,
    /// moves the selection down six jobs and prints, for each move, the longest the main thread was
    /// held and how long each thing the pane loads or computes takes on its own, so a slow switch
    /// can be traced to its cause (2026-10-26: choosing another job held it 3–4 s, building your
    /// screening profile once per evidence id). Exits 1 if any move holds the main thread longer
    /// than `limit`.
    enum DebugSelectProbe {
        /// A switch that holds the main thread longer than this is felt as a wait.
        static let limit = 0.25

        @MainActor static func runIfRequested(_ model: AppModel) async {
            guard CommandLine.arguments.contains("--select-probe") else { return }
            setvbuf(stdout, nil, _IOLBF, 0)
            while model.phase != .ready { try? await Task.sleep(for: .milliseconds(100)) }
            model.section = .inbox
            try? await Task.sleep(for: .seconds(2))
            let visible = model.visibleJobs
            print("SELECT \(visible.count) visible · \(model.jobs.count) jobs · \(model.sources.count) sources")
            var slow: [String] = []
            for id in visible.prefix(6) {
                guard let job = model.job(id) else { continue }
                var t = CACurrentMediaTime()
                _ = model.groups(.inbox, query: Inbox.Query())
                let groups = CACurrentMediaTime() - t
                t = CACurrentMediaTime()
                let stored = await model.storedAnalysis(for: job)
                let analysis = CACurrentMediaTime() - t
                t = CACurrentMediaTime()
                _ = await model.postings(of: job)
                let postings = CACurrentMediaTime() - t
                t = CACurrentMediaTime()
                _ = model.screeningProfile
                let profile = CACurrentMediaTime() - t
                let evidence = stored?.analysis.requirements.flatMap { $0.evidence ?? [] } ?? []
                t = CACurrentMediaTime()
                for item in evidence { _ = model.screeningProfile?.describe(item) }
                let describe = CACurrentMediaTime() - t
                t = CACurrentMediaTime()
                let blocks = MarkdownBlock.parse(job.descriptionMarkdown ?? "")
                let markdown = CACurrentMediaTime() - t
                // The switch itself, watched from another thread: the longest the main thread
                // stayed busy in the three seconds after the selection changed.
                let watch = Task.detached { await stallWatch(seconds: 3) }
                t = CACurrentMediaTime()
                model.selectedJob = id
                await nextTurns(3)
                let turns = CACurrentMediaTime() - t
                let stall = await watch.value
                if stall.longest > limit { slow.append(job.title) }
                print(
                    String(
                        format:
                            "SELECT %@: main held %.0f ms at most, %.0f ms over 50 ms in all, %.0f ms to three turns · groups %.1f · analysis %.1f · postings %.1f · profile %.1f · describe×%d %.1f · markdown %.1f ms (%d blocks, %d chars, %d requirements)",
                        job.title, stall.longest * 1000, stall.held * 1000, turns * 1000, groups * 1000,
                        analysis * 1000, postings * 1000, profile * 1000, evidence.count, describe * 1000,
                        markdown * 1000, blocks.count, job.descriptionMarkdown?.count ?? 0,
                        stored?.analysis.requirements.count ?? 0))
            }
            print(slow.isEmpty ? "SELECT ok" : "SELECT slow: \(slow.joined(separator: ", "))")
            exit(slow.isEmpty ? 0 : 1)
        }

        @MainActor private static func nextTurns(_ count: Int) async {
            for _ in 0..<count {
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            }
        }

        /// Pings the main queue every 10 ms for `seconds` and reports the longest wait for an answer
        /// and the sum of the waits over 50 ms.
        nonisolated private static func stallWatch(seconds: Double) async -> (longest: Double, held: Double) {
            var longest = 0.0
            var held = 0.0
            let end = CACurrentMediaTime() + seconds
            while CACurrentMediaTime() < end {
                let sent = CACurrentMediaTime()
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                let wait = CACurrentMediaTime() - sent
                longest = max(longest, wait)
                if wait > 0.05 { held += wait }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return (longest, held)
        }
    }
#endif
