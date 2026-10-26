import OSLog
import SwiftUI

@main
struct KairosApp: App {
    private let log = Logger(subsystem: "com.keneepatel.kairos", category: "app")
    @State private var model = AppModel()

    init() {
        #if DEBUG
            DebugSnapshots.runIfRequested()
            DebugReport.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .task { await model.open() }
                #if DEBUG
                    .task { await DebugLayoutProbe.runIfRequested(model) }
                    .task { await DebugSelectProbe.runIfRequested(model) }
                #endif
                .onOpenURL { url in
                    // kairos:// routes (auth callbacks later, SPEC §5.8) arrive here. Log only the route:
                    // query strings can carry one-time auth codes.
                    log.info("Opened route \(url.host() ?? "", privacy: .public)\(url.path(), privacy: .public)")
                    #if DEBUG
                        DebugRoutes.handle(url)
                    #endif
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            // Every shortcut the sidebar and the status line offer, in a menu so it can be learned
            // (UI v2). The Job menu arrives with the Inbox slice.
            CommandMenu("Go") {
                ForEach(AppSection.working) { section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(section.shortcut ?? "0", modifiers: .command)
                }
                Divider()
                ForEach(AppSection.reports + AppSection.setup) { section in
                    Button(section.title) { model.section = section }
                }
                Divider()
                Button("Find New Jobs") { model.fetchNow() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isFetching || model.sources.allSatisfy { !$0.enabled })
                Button("Stop") { model.stopFetch() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isFetching)
            }
            // One key per decision in the lists; here with ⌘ so the menu teaches them.
            CommandMenu("Job") {
                let job = model.job(model.selectedJob)
                let inList = [AppSection.inbox, .saved, .skipped].contains(model.section) && job != nil
                Button("Build Resume") { model.perform(.build) }
                    .keyboardShortcut("b", modifiers: .command).disabled(!inList)
                Button(job?.state == .shortlisted ? "Unsave" : "Save") { model.perform(.save) }
                    .keyboardShortcut("d", modifiers: .command).disabled(!inList)
                Button(job?.state == .skipped ? "Bring Back" : "Skip") { model.perform(.skip) }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(!inList)
                Button("Open Posting") { model.perform(.openPosting) }
                    .keyboardShortcut("o", modifiers: .command).disabled(!inList)
                Divider()
                Button("Mark Applied") { model.perform(.markApplied) }
                    .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!inList)
                Button("Re-evaluate") { model.perform(.reevaluate) }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!inList)
            }
        }
        // The menu bar item (SPEC R2): what waits, what's new, what runs, Find new jobs, Open Kairos.
        MenuBarExtra("Kairos", image: "MenuBarIcon") {
            MenuBarView().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
