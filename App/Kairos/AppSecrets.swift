import Foundation
import Secrets
import Store

/// Where Kairos keeps API keys. Until release they're in a private file in Kairos's own folder, not
/// the Keychain, so nothing asks for your password (your decision, 2026-10-21). Before release they
/// go back to the Keychain, after asking you first: tasks/todo.md, Release.
enum AppSecrets {
    static let fileName = "api-keys.json"

    /// The store the app and its debug runs use, reading each key at most once a session.
    static func store() -> any SecretStore {
        let folder =
            (try? AccountStore.applicationSupport().baseDirectory)
            ?? FileManager.default.temporaryDirectory.appending(path: "Kairos")
        return CachingSecretStore(FileSecretStore(url: folder.appending(path: fileName)))
    }
}
