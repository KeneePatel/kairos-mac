import Foundation

/// The pinned typst binary `scripts/fetch-typst.sh` puts in `Vendor/typst/`. Render tests run the
/// real one: CI fetches it before testing, and a missing binary fails the tests rather than
/// skipping them.
public enum TypstBinary {
    public static var url: URL? {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = repository.appending(path: "Vendor/typst/typst")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }
}
