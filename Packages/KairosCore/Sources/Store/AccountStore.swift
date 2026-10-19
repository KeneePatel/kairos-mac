import Foundation

/// Whose data a database holds: the signed-out local profile, or one signed-in account (SPEC §5.1).
public enum AccountID: Hashable, Sendable {
    case local
    case user(String)
}

/// Where each account's database lives: `<base>/<account>/kairos.sqlite`, with `local/` for use
/// before sign-in. In the sandboxed app, `<base>` is Application Support/Kairos inside the container.
public struct AccountStore: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// The app's real location.
    public static func applicationSupport() throws(StoreError) -> AccountStore {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw .directory("no Application Support directory") }
        return AccountStore(baseDirectory: support.appendingPathComponent("Kairos", isDirectory: true))
    }

    /// The database file for `account`, creating its folder if needed.
    public func databaseURL(for account: AccountID) throws(StoreError) -> URL {
        let folder = baseDirectory.appendingPathComponent(try folderName(for: account), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw .directory("can't create \(folder.path): \(error.localizedDescription)")
        }
        return folder.appendingPathComponent("kairos.sqlite")
    }

    func folderName(for account: AccountID) throws(StoreError) -> String {
        switch account {
        case .local:
            return "local"
        case .user(let id):
            // Account ids come from the server; accept only a lowercase UUID so a bad id can never
            // become a path like "../".
            let isUUID = id.count == 36 && UUID(uuidString: id) != nil && id == id.lowercased()
            guard isUUID else { throw .invalidAccount(id) }
            return id
        }
    }
}
