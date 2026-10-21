import Foundation
import Synchronization

/// Secrets in one private JSON file instead of the Keychain: your decision for development
/// (2026-10-21), because the login keychain kept asking for your password. Before release they go
/// back to the Keychain, and you'll be asked first (tasks/todo.md, Release).
///
/// The file is readable by your user account only (0600), sits in Kairos's own sandbox folder,
/// is left out of Time Machine backups, and is never synced or written to SQLite. Values never leave
/// this module except to the code that asked for them.
public final class FileSecretStore: SecretStore {
    private struct Entry: Codable {
        var value: String
        var hint: String?
    }

    public let url: URL
    private let lock = Mutex(())

    public init(url: URL) {
        self.url = url
    }

    public func read(_ key: SecretKey) throws(SecretsError) -> String? {
        try lock.withLock { _ throws(SecretsError) in try load()[key.account]?.value }
    }

    public func write(_ value: String, for key: SecretKey) throws(SecretsError) {
        try write(value, for: key, hint: nil)
    }

    public func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        try lock.withLock { _ throws(SecretsError) in
            var entries = try load()
            entries[key.account] = Entry(value: value, hint: hint)
            try save(entries)
        }
    }

    public func delete(_ key: SecretKey) throws(SecretsError) {
        try lock.withLock { _ throws(SecretsError) in
            var entries = try load()
            guard entries.removeValue(forKey: key.account) != nil else { return }
            try save(entries)
        }
    }

    public func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? {
        try lock.withLock { _ throws(SecretsError) in try load()[key.account].map { SecretSummary(hint: $0.hint) } }
    }

    /// No file yet is an empty store; a file that doesn't decode is an error, so a damaged file is
    /// never replaced by an empty one on the next save.
    private func load() throws(SecretsError) -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))
        } catch {
            throw .file("the key file can't be read: \(error.localizedDescription)")
        }
    }

    /// Writes a new file beside the old one, private from the start, then swaps it in.
    private func save(_ entries: [String: Entry]) throws(SecretsError) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let staged = url.deletingLastPathComponent().appending(
                path: ".\(url.lastPathComponent).\(UUID().uuidString)")
            guard
                fileManager.createFile(
                    atPath: staged.path, contents: try encoder.encode(entries), attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var target = url
            try target.setResourceValues(values)
        } catch {
            throw .file("the key file can't be saved: \(error.localizedDescription)")
        }
    }
}
