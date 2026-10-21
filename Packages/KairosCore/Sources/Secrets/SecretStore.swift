import Foundation
import Security
import Synchronization

/// Names one secret: an LLM key, an Adzuna key, a session token. Values never leave this module except
/// to the code that asked for them; they're never logged, synced or written to SQLite (SPEC §5.7).
public struct SecretKey: Hashable, Sendable, CustomStringConvertible {
    public let account: String
    public init(_ account: String) { self.account = account }
    public var description: String { account }
}

public enum SecretsError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case notUTF8
    /// The key file couldn't be read or written (`FileSecretStore`).
    case file(String)
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws(SecretsError) -> String?
    func write(_ value: String, for key: SecretKey) throws(SecretsError)
    func delete(_ key: SecretKey) throws(SecretsError)
    /// Saves the secret with a hint beside it, such as its masked form.
    func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError)
    /// Whether a secret is stored, and its hint, without reading the secret itself. In the login
    /// keychain that never asks for your password.
    func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary?
}

/// What's known about a stored secret without unlocking it.
public struct SecretSummary: Sendable, Equatable {
    public let hint: String?

    public init(hint: String?) { self.hint = hint }
}

extension SecretStore {
    public func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        try write(value, for: key)
    }

    public func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? {
        try read(key).map { _ in SecretSummary(hint: nil) }
    }
}

/// Generic-password items in the user's login keychain.
///
/// Without the paid developer program the app has no team ID, so it can't use the data protection
/// keychain (and its "this device only" accessibility classes). Items live in the login keychain
/// instead, where macOS ties access to the app's code signature: spike T07 checks that a stable
/// self-signed certificate keeps that access across updates without prompts. An item's hint is
/// kept in its comment, an attribute macOS shows without unlocking the item.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String) { self.service = service }

    private func query(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account,
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

    public func write(_ value: String, for key: SecretKey) throws(SecretsError) {
        try write(value, for: key, hint: nil)
    }

    public func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if let hint { attributes[kSecAttrComment as String] = hint }
        let update = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw .keychain(update) }
        var add = query(key).merging(attributes) { _, new in new }
        add[kSecAttrLabel as String] = "Kairos: \(key.account)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }
    }

    /// Attributes only: no `kSecReturnData`, so nothing is decrypted and no prompt can appear.
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

/// For tests and previews: same contract, nothing touches the keychain.
public final class InMemorySecretStore: SecretStore {
    private let values = Mutex<[SecretKey: (value: String, hint: String?)]>([:])

    public init(_ initial: [SecretKey: String] = [:]) {
        values.withLock { $0 = initial.mapValues { ($0, nil) } }
    }

    public func read(_ key: SecretKey) throws(SecretsError) -> String? { values.withLock { $0[key]?.value } }
    public func write(_ value: String, for key: SecretKey) throws(SecretsError) {
        values.withLock { $0[key] = (value, $0[key]?.hint) }
    }
    public func write(_ value: String, for key: SecretKey, hint: String?) throws(SecretsError) {
        values.withLock { $0[key] = (value, hint ?? $0[key]?.hint) }
    }
    public func delete(_ key: SecretKey) throws(SecretsError) { _ = values.withLock { $0.removeValue(forKey: key) } }
    public func summary(_ key: SecretKey) throws(SecretsError) -> SecretSummary? {
        values.withLock { $0[key].map { SecretSummary(hint: $0.hint) } }
    }
}

/// Reads each secret from the store at most once per session (SPEC §5.7). Every operation that
/// uses AI builds a router, and each router reads every key: in the login keychain each read of an
/// item macOS hasn't been told to always allow is a password prompt, so this keeps it to one per
/// key per launch at worst. Values stay in memory only, as they already do inside each client.
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

    public func write(_ value: String, for key: SecretKey) throws(SecretsError) {
        try write(value, for: key, hint: nil)
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
