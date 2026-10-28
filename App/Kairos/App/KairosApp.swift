import SwiftUI

@main
struct KairosApp: App {
    @State private var model = AppModel()

    init() {
        #if DEBUG
            Snapshots.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .task { await model.open() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(model.undo.map { "Undo \($0.title)" } ?? "Undo") { model.undoDecision() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(model.undo == nil)
            }
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
                Button("Find New Jobs") { model.findNewJobs() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.activity.isRunning)
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.activity.isRunning)
            }
            // One key per decision in the lists; here with ⌘ so the menu teaches them.
            CommandMenu("Job") {
                let job = model.section.isJobList ? model.summary(model.selectedJob) : nil
                Button("Build Resume") { if let job { model.build(job.id) } }
                    .keyboardShortcut("b", modifiers: .command).disabled(job == nil)
                Button(job?.decision == .saved ? "Unsave" : "Save") { if let job { model.toggleSave(job.id) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(job == nil)
                Button(job?.decision == .skipped ? "Bring Back" : "Skip") { if let job { model.skip(job.id) } }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(job == nil)
                Button("Open Posting") { if let job { model.openPosting(job.id) } }
                    .keyboardShortcut("o", modifiers: .command).disabled(job == nil)
                Divider()
                Button("Mark Applied") { if let job { model.markApplied(job.id) } }
                    .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(job == nil)
                Button("Re-evaluate") { if let job { model.reevaluate(job.id) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).disabled(job == nil)
            }
        }

        MenuBarExtra("Kairos", image: "MenuBarIcon") {
            MenuBarView().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
