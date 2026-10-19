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
}

public protocol SecretStore: Sendable {
    func read(_ key: SecretKey) throws(SecretsError) -> String?
    func write(_ value: String, for key: SecretKey) throws(SecretsError)
    func delete(_ key: SecretKey) throws(SecretsError)
}

/// Generic-password items in the user's login keychain.
///
/// Without the paid developer program the app has no team ID, so it can't use the data protection
/// keychain (and its "this device only" accessibility classes). Items live in the login keychain
/// instead, where macOS ties access to the app's code signature: spike T07 checks that a stable
/// self-signed certificate keeps that access across updates without prompts.
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
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw .keychain(update) }
        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Kairos: \(key.account)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }
    }

    public func delete(_ key: SecretKey) throws(SecretsError) {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
    }
}

/// For tests and previews: same contract, nothing touches the keychain.
public final class InMemorySecretStore: SecretStore {
    private let values = Mutex<[SecretKey: String]>([:])

    public init(_ initial: [SecretKey: String] = [:]) {
        values.withLock { $0 = initial }
    }

    public func read(_ key: SecretKey) throws(SecretsError) -> String? { values.withLock { $0[key] } }
    public func write(_ value: String, for key: SecretKey) throws(SecretsError) { values.withLock { $0[key] = value } }
    public func delete(_ key: SecretKey) throws(SecretsError) { _ = values.withLock { $0.removeValue(forKey: key) } }
}
