import Engine
import Foundation
import Jobs
import KairosKit
import Store
import TestKit
import Testing

@Suite("Workspace")
struct WorkspaceTests {
    @Test func aFreshInstallStartsHimalayasAndKeepsTenBackups() async throws {
        let folder = DataFolder(
            root: FileManager.default.temporaryDirectory.appending(path: "kairos-ws-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let clock = ManualWallClock(now)
        let workspace = try await Workspace.open(folder: folder, http: FakeHTTP(), clock: clock)
        let preparation = await workspace.prepare()
        #expect(preparation.imported == nil && preparation.importError == nil)
        #expect(try await workspace.store.sources.all().map(\.kind) == [.himalayas])

        for _ in 0..<12 {
            try await workspace.backUp()
            clock.advance(by: 60)
        }
        let backups = try FileManager.default.contentsOfDirectory(at: folder.backups, includingPropertiesForKeys: nil)
        #expect(backups.count == Workspace.backupsKept)
        // The newest are kept.
        #expect(
            backups.contains {
                $0.lastPathComponent == folder.backup(at: clock.now.addingTimeInterval(-60)).lastPathComponent
            })
    }
}
