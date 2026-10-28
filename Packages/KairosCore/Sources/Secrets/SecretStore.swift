import Foundation
import Security
import Synchronization

/// Names one secret: an AI provider's key, a search API key, a GitHub token. Values never leave this
/// module except to the code that asked for them; they're never logged or written to SQLite.
public struct SecretKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let name: String
    public init(_ name: String) { self.name = name }
    public var description: String { name }

    // The keys Kairos stores under fixed names. AI provider keys get generated names.
    public static let adzunaAppID = SecretKey("adzuna.app_id")
    public static let adzunaAppKey = SecretKey("adzuna.app_key")
    public static let himalayas = SecretKey("himalayas.key")
    public static let serpAPI = SecretKey("serpapi.key")
    public static let gitHub = SecretKey("github.token")
}

public enum SecretsError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case notUTF8
    /// The key file couldn't be read or written.
    case file(String)
}

/// What's known about a stored secret without reading it.
public struct SecretSummary: Sendable, Equatable {
    /// A masked form, such as "AIza••••••••••••Q2xk".
    public let hint: String?
    public init(hint: String?) { self.hint = hint }
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws(SecretsError) -> String?
    func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError)
    func delete(_ key: SecretKey) throws(SecretsError)
    /// Whether a secret is stored, and its hint, without reading the secret itself. In the login
    /// keychain this never asks for your password.
    func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary?
}

extension SecretStore {
    public func write(_ value: String, for key: SecretKey) throws(SecretsError) {
        try write(value, for: key, hint: Self.mask(value))
    }

    /// "AIza••••••••••••Q2xk": enough to tell keys apart, never enough to use one.
    public static func mask(_ value: String) -> String {
        guard value.count > 10 else { return String(repeating: "•", count: max(value.count, 4)) }
        return value.prefix(4) + String(repeating: "•", count: 12) + value.suffix(4)
    }
}

/// Secrets in one private JSON file instead of the Keychain: Kenee's decision for development
/// (2026-10-21), because the login keychain kept asking for the account password. The file is
/// readable by its user only (0600), sits in Kairos's own sandbox folder, is left out of Time
/// Machine backups and is never written to SQLite.
///
/// The format is `{"<name>": {"value": "…", "hint": "…"}}`, unchanged from the first Kairos, so the
/// keys saved there carry over.
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
        try lock.withLock { _ throws(SecretsError) in try load()[key.name]?.value }
    }

    public func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        try lock.withLock { _ throws(SecretsError) in
            var entries = try load()
            entries[key.name] = Entry(value: value, hint: hint)
            try save(entries)
        }
    }

    public func delete(_ key: SecretKey) throws(SecretsError) {
        try lock.withLock { _ throws(SecretsError) in
            var entries = try load()
            guard entries.removeValue(forKey: key.name) != nil else { return }
            try save(entries)
        }
    }

    public func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? {
        try lock.withLock { _ throws(SecretsError) in try load()[key.name].map { SecretSummary(hint: $0.hint) } }
    }

    /// No file yet is an empty store. A file that doesn't decode is an error, so a damaged file is
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

/// Generic-password items in the login keychain, for release builds. Without a paid developer team
/// the app can't use the data protection keychain, so access is tied to its code signature
/// (docs/guides/signing.md). An item's hint is kept in its comment, which macOS shows without
/// unlocking the item.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.name,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    public func read(_ key: SecretKey) throws(SecretsError) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw .notUTF8 }
        return value
    }

    public func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if let hint { attributes[kSecAttrComment as String] = hint }
        let update = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw .keychain(update) }
        var add = query(key).merging(attributes) { _, new in new }
        add[kSecAttrLabel as String] = "Kairos: \(key.name)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }
    }

    /// Attributes only: nothing is decrypted, so no prompt can appear.
    public func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? {
        var q = query(key)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .keychain(status) }
        return SecretSummary(hint: (result as? [String: Any])?[kSecAttrComment as String] as? String)
    }

    public func delete(_ key: SecretKey) throws(SecretsError) {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
    }
}

/// For tests, previews and the command line: same contract, nothing on disk.
public final class MemorySecretStore: SecretStore {
    private let values = Mutex<[SecretKey: (value: String, hint: String?)]>([:])

    public init(_ initial: [SecretKey: String] = [:]) {
        values.withLock { $0 = initial.mapValues { ($0, nil) } }
    }

    public func read(_ key: SecretKey) throws(SecretsError) -> String? { values.withLock { $0[key]?.value } }

    public func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        values.withLock { $0[key] = (value, hint) }
    }

    public func delete(_ key: SecretKey) throws(SecretsError) { _ = values.withLock { $0.removeValue(forKey: key) } }

    public func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? {
        values.withLock { $0[key].map { SecretSummary(hint: $0.hint) } }
    }
}

/// Reads each secret from the store at most once per session: every AI operation reads its keys, and
/// in the login keychain an unapproved read is a password prompt.
public final class CachingSecretStore: SecretStore {
    private let base: any SecretStore
    private let values = Mutex<[SecretKey: String]>([:])

    public init(_ base: any SecretStore) {
        self.base = base
    }

    public func read(_ key: SecretKey) throws(SecretsError) -> String? {
        if let cached = values.withLock({ $0[key] }) { return cached }
        let value = try base.read(key)
        if let value { values.withLock { $0[key] = value } }
        return value
    }

    public func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        try base.write(value, for: key, hint: hint)
        values.withLock { $0[key] = value }
    }

    public func delete(_ key: SecretKey) throws(SecretsError) {
        try base.delete(key)
        _ = values.withLock { $0.removeValue(forKey: key) }
    }

    public func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? {
        try base.summary(key)
    }
}
