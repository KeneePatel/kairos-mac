import Foundation
import Testing

@testable import Store

@Suite("Account store")
struct AccountStoreTests {
    func temporaryStore() -> (AccountStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kairos-accounts-\(UUID().uuidString)")
        return (AccountStore(baseDirectory: base), base)
    }

    @Test func theLocalProfileLivesInLocal() throws {
        let (store, base) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try store.databaseURL(for: .local)
        #expect(url == base.appendingPathComponent("local/kairos.sqlite"))
        #expect(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }

    @Test func eachAccountGetsItsOwnFolder() throws {
        let (store, base) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        #expect(try store.databaseURL(for: .user(id)) == base.appendingPathComponent("\(id)/kairos.sqlite"))
    }

    @Test(arguments: ["../escape", "local", "", "3F2504E0-4F89-41D3-9A0C-0305E82C3301", "not-a-uuid"])
    func rejectsAccountIDsThatArentLowercaseUUIDs(_ id: String) {
        let (store, _) = temporaryStore()
        #expect(throws: StoreError.invalidAccount(id)) { try store.databaseURL(for: .user(id)) }
    }
}
