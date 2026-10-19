import OSLog
import SwiftUI

@main
struct KairosApp: App {
    private let log = Logger(subsystem: "com.keneepatel.kairos", category: "app")

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    // kairos:// routes (auth callbacks later, SPEC §5.8) arrive here. Log only the route:
                    // query strings can carry one-time auth codes.
                    log.info("Opened route \(url.host() ?? "", privacy: .public)\(url.path(), privacy: .public)")
                }
        }
        .defaultSize(width: 1280, height: 820)
    }
}
