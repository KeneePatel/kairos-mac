import Foundation
import Secrets
import Testing

@Suite("Secret stores")
struct SecretStoreTests {
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kairos-secrets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theFileStoreKeepsValuesAndHints() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileSecretStore(url: folder.appending(path: "api-keys.json"))
        #expect(try store.read(.serpAPI) == nil)
        try store.write("AIzaSyExampleExampleQ2xk", for: SecretKey("llm.gemini.1"))
        #expect(try store.read(SecretKey("llm.gemini.1")) == "AIzaSyExampleExampleQ2xk")
        #expect(try store.summary(SecretKey("llm.gemini.1"))?.hint == "AIza••••••••••••Q2xk")
        try store.delete(SecretKey("llm.gemini.1"))
        #expect(try store.read(SecretKey("llm.gemini.1")) == nil)
    }

    /// The first Kairos wrote this exact shape; its keys must read back unchanged.
    @Test func readsTheFirstKairossFile() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "api-keys.json")
        try #"{"adzuna.app_id":{"value":"id-1"},"llm.gemini.ab12cd34":{"hint":"AIza••••","value":"secret-1"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let store = FileSecretStore(url: url)
        #expect(try store.read(.adzunaAppID) == "id-1")
        #expect(try store.read(SecretKey("llm.gemini.ab12cd34")) == "secret-1")
        #expect(try store.summary(SecretKey("llm.gemini.ab12cd34"))?.hint == "AIza••••")
    }

    @Test func theFileIsPrivateAndLeftOutOfBackups() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "api-keys.json")
        try FileSecretStore(url: url).write("value", for: .gitHub)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func aDamagedFileIsAnErrorNotAnEmptyStore() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "api-keys.json")
        try "{broken".write(to: url, atomically: true, encoding: .utf8)
        let store = FileSecretStore(url: url)
        #expect(throws: SecretsError.self) { try store.read(.serpAPI) }
        #expect(throws: SecretsError.self) { try store.write("x", for: .serpAPI) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{broken")
    }

    @Test func theCacheReadsEachKeyOnce() throws {
        final class Counting: SecretStore, @unchecked Sendable {
            var reads = 0
            let base = MemorySecretStore([.serpAPI: "k"])
            func read(_ key: SecretKey) throws(SecretsError) -> String? {
                reads += 1
                return try base.read(key)
            }
            func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
                try base.write(value, for: key, hint: hint)
            }
            func delete(_ key: SecretKey) throws(SecretsError) { try base.delete(key) }
            func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? { try base.summary(key) }
        }
        let counting = Counting()
        let cache = CachingSecretStore(counting)
        #expect(try cache.read(.serpAPI) == "k")
        #expect(try cache.read(.serpAPI) == "k")
        #expect(counting.reads == 1)
        try cache.write("k2", for: .serpAPI)
        #expect(try cache.read(.serpAPI) == "k2" && counting.reads == 1)
        try cache.delete(.serpAPI)
        #expect(try cache.read(.serpAPI) == nil)
    }

    @Test func masksShortAndLongValues() {
        #expect(MemorySecretStore.mask("abc") == "••••")
        #expect(MemorySecretStore.mask("sk-1234567890abcd") == "sk-1••••••••••••abcd")
    }
}
