import OSLog
import SwiftUI

@main
struct KairosApp: App {
    private let log = Logger(subsystem: "com.keneepatel.kairos", category: "app")
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.open() }
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
    }
}
