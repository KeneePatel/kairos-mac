import Foundation
import Testing

@testable import Secrets

private func folder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "kairos-secrets-\(UUID().uuidString)")
}

/// Keys in a private file until release (your decision, 2026-10-21): no Keychain, so no password
/// prompts. These are the properties that keep that file as private as a file can be.
@Suite("File secret store")
struct FileSecretStoreTests {
    @Test func itRoundTripsAndOverwrites() throws {
        let store = FileSecretStore(url: folder().appending(path: "api-keys.json"))
        let key = SecretKey("llm.gemini.1")
        #expect(try store.read(key) == nil && store.summary(key) == nil)
        try store.write("first", for: key, hint: "AIza…0001")
        try store.write("second", for: key, hint: "AIza…0002")  // overwrite, not a duplicate
        #expect(try store.read(key) == "second")
        #expect(try store.summary(key) == SecretSummary(hint: "AIza…0002"))
        try store.delete(key)
        try store.delete(key)  // deleting twice is fine
        #expect(try store.read(key) == nil && store.summary(key) == nil)
    }

    /// Keys survive a relaunch: a new store on the same file reads what the last one wrote.
    @Test func keysSurviveARelaunch() throws {
        let url = folder().appending(path: "api-keys.json")
        try FileSecretStore(url: url).write("kept", for: SecretKey("llm.gemini.1"))
        try FileSecretStore(url: url).write("also kept", for: SecretKey("github.token"))
        let again = FileSecretStore(url: url)
        #expect(try again.read(SecretKey("llm.gemini.1")) == "kept")
        #expect(try again.read(SecretKey("github.token")) == "also kept")
        #expect(try again.summary(SecretKey("github.token")) == SecretSummary(hint: nil))
    }

    /// Only you can read it, and Time Machine doesn't copy it.
    @Test func theFileIsPrivateAndLeftOutOfBackups() throws {
        let url = folder().appending(path: "api-keys.json")
        let store = FileSecretStore(url: url)
        try store.write("secret", for: SecretKey("llm.gemini.1"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try store.write("rewritten", for: SecretKey("llm.gemini.1"))  // a rewrite keeps both
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(after == 0o600)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// A damaged file is an error, never silently an empty store that the next save would overwrite.
    @Test func aDamagedFileIsAnErrorNotAnEmptyStore() throws {
        let url = folder().appending(path: "api-keys.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = FileSecretStore(url: url)
        #expect(throws: SecretsError.self) { try store.read(SecretKey("llm.gemini.1")) }
        #expect(throws: SecretsError.self) { try store.write("new", for: SecretKey("llm.gemini.1")) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "not json")  // left as it was
    }
}
