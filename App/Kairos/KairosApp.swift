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
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.open() }
                #if DEBUG
                    .task { await DebugLayoutProbe.runIfRequested(model) }
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
        }
    }
}
