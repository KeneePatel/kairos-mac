#if DEBUG
    import Foundation
    import OSLog
    import PDFKit
    import Render
    import Secrets

    /// Debug-only kairos://debug/... routes, so spikes can be exercised from the terminal
    /// (`open kairos://debug/render-spike`) without UI scripting.
    enum DebugRoutes {
        private static let log = Logger(subsystem: "com.keneepatel.kairos", category: "debug")

        static func handle(_ url: URL) {
            guard url.host() == "debug" else { return }
            switch url.path() {
            case "/render-spike": Task { await renderSpike() }
            case "/keychain-write": keychain(write: true)
            case "/keychain-read": keychain(write: false)
            default: log.error("Unknown debug route \(url.path(), privacy: .public)")
            }
        }

        /// T07: build A writes a test item; build B (same certificate, different code) reads it back.
        /// A Keychain prompt between the two means the code identity changed.
        private static func keychain(write: Bool) {
            let store = KeychainStore(service: "com.keneepatel.kairos")
            let key = SecretKey("debug.signing-spike")
            do {
                if write {
                    try store.write("written by build \(buildNumber)", for: key)
                    log.notice("keychain-spike: wrote the test item from build \(buildNumber, privacy: .public)")
                } else if let value = try store.read(key) {
                    log.notice(
                        "keychain-spike: build \(buildNumber, privacy: .public) read: \(value, privacy: .public)")
                } else {
                    log.notice("keychain-spike: no test item found")
                }
            } catch {
                log.error("keychain-spike: \(String(describing: error), privacy: .public)")
            }
        }

        private static var buildNumber: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        }

        /// T06: runs the bundled typst from inside the App Sandbox and reports what came back.
        private static func renderSpike() async {
            guard let binary = Bundle.main.url(forAuxiliaryExecutable: "typst") else {
                log.error("render-spike: typst is not in the app bundle")
                return
            }
            // Sample content (fixture data, never shipped): the spike template's two fields.
            let content = Data(
                #"{"name":"Jordan Rivera","bullets":["Rendered from inside the sandbox: C# & R&D, 50%, $5"]}"#.utf8)
            let started = ContinuousClock.now
            do {
                let pdf = try await TypstRunner(executable: binary).compile(
                    template: try TypstRunner.spikeTemplate(), data: content)
                let elapsed = ContinuousClock.now - started
                let pages = PDFDocument(data: pdf)?.pageCount ?? 0
                let text = PDFDocument(data: pdf)?.string ?? ""
                log.notice(
                    "render-spike: ok, \(pdf.count) bytes, \(pages) page(s), text found: \(text.contains("C# & R&D")), \(elapsed, privacy: .public)"
                )
            } catch {
                log.error("render-spike: failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
#endif
