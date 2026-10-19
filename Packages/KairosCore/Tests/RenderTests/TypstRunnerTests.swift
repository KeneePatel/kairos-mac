import Foundation
import PDFKit
import Testing

@testable import Render

/// The pinned typst binary from scripts/fetch-typst.sh, or KAIROS_TYPST if set.
enum TypstBinary {
    static let url: URL? = {
        if let path = ProcessInfo.processInfo.environment["KAIROS_TYPST"] {
            return URL(fileURLWithPath: path)
        }
        // Tests/RenderTests/this file → repo root is four levels up from the package's Tests folder.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = repo.appendingPathComponent("Vendor/typst/typst")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }()
}

@Suite("Typst runner", .enabled(if: TypstBinary.url != nil, "Run scripts/fetch-typst.sh first"))
struct TypstRunnerTests {
    func runner() throws -> TypstRunner {
        TypstRunner(executable: try #require(TypstBinary.url))
    }

    @Test func compilesJSONIntoAOnePagePDF() async throws {
        let content: [String: Any] = [
            "name": "Jordan Rivera",
            "bullets": [
                "Built a Go reconciliation service matching 1.2M daily transactions",
                // Characters that break LaTeX pass through untouched because they're data, not markup.
                "Shipped C# & R&D tooling: 50% faster #builds, $5 saved, snake_case and *stars*",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: content)
        let pdf = try await runner().compile(template: try TypstRunner.spikeTemplate(), data: data)

        let document = try #require(PDFDocument(data: pdf))
        #expect(document.pageCount == 1)
        let text = try #require(document.string)
        #expect(text.contains("Jordan Rivera"))
        #expect(text.contains("1.2M daily transactions"))
        #expect(text.contains("C# & R&D"))
        #expect(text.contains("$5 saved"))
        #expect(text.contains("snake_case"))
    }

    @Test func reportsTypstsOwnErrorMessage() async throws {
        let broken = "#let x = (\n= Unclosed"
        await #expect {
            _ = try await runner().compile(template: broken, data: Data("{}".utf8))
        } throws: { error in
            guard case RenderError.compile(let message) = error else { return false }
            return message.contains("error")
        }
    }

    @Test func aMissingBinaryIsALaunchError() async {
        let missing = TypstRunner(executable: URL(fileURLWithPath: "/nonexistent/typst"))
        await #expect {
            _ = try await missing.compile(template: "Hi", data: Data("{}".utf8))
        } throws: { error in
            if case RenderError.launch = error { return true }
            return false
        }
    }
}
