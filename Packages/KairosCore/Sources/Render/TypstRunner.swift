import Foundation

/// Runs the bundled `typst` binary to turn a template plus JSON content into a PDF.
///
/// Content goes in as a JSON file the template reads with `json(sys.inputs.at("data"))`, so nothing the
/// model writes is ever spliced into Typst source and nothing needs escaping (ADR-004).
public struct TypstRunner: Sendable {
    public let executable: URL
    /// The only text fonts typst may use besides its built-in ones (`Fonts/`, Source Serif 4).
    public let fonts: URL?
    public let timeout: Duration

    public init(executable: URL, fonts: URL? = TypstRunner.bundledFonts, timeout: Duration = .seconds(30)) {
        self.executable = executable
        self.fonts = fonts
        self.timeout = timeout
    }

    /// The fonts shipped with this module.
    public static let bundledFonts = Bundle.module.url(forResource: "Fonts", withExtension: nil)

    /// Compiles `template` (Typst source) with `data` (JSON bytes) and returns the PDF bytes.
    /// `createdAt` fixes the PDF's creation date, for reproducible output.
    public func compile(template: String, data: Data, createdAt: Date? = nil) async throws(RenderError) -> Data {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("kairos-render-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try Data(template.utf8).write(to: work.appendingPathComponent("template.typ"))
            try data.write(to: work.appendingPathComponent("data.json"))
        } catch {
            throw .workspace(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: work) }

        let output = work.appendingPathComponent("out.pdf")
        var arguments = [
            "compile",
            "--root", work.path,
            "--input", "data=data.json",
            // Reproducible output: only typst's built-in fonts and the bundled ones, never this Mac's.
            "--ignore-system-fonts",
            // One line per problem ("template.typ:3:9: error: …"), without colour codes.
            "--diagnostic-format", "short",
        ]
        if let fonts { arguments += ["--font-path", fonts.path] }
        if let createdAt { arguments += ["--creation-timestamp", String(Int(createdAt.timeIntervalSince1970))] }
        arguments += [work.appendingPathComponent("template.typ").path, output.path]
        let result = try await run(arguments, home: work)
        guard result.status == 0 else { throw .compile(Self.summary(of: result.stderr)) }
        guard let pdf = fm.contents(atPath: output.path) else { throw .compile("typst wrote no PDF") }
        return pdf
    }

    private struct Result: Sendable {
        let status: Int32
        let stderr: String
    }

    /// typst's errors, without its warnings, at most 2,000 characters.
    static func summary(of stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        let errors = lines.filter { $0.contains("error") }
        let text = (errors.isEmpty ? lines : errors).joined(separator: "\n")
        return text.isEmpty ? "typst failed without saying why" : String(text.prefix(2_000))
    }

    private func run(_ arguments: [String], home: URL) async throws(RenderError) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A sealed environment: no TYPST_FONT_PATHS or similar from the user's shell changes the
        // output, and any cache typst wants goes in the throwaway folder.
        process.environment = ["HOME": home.path, "TMPDIR": home.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw .launch(error.localizedDescription)
        }

        let box = ProcessBox(process)
        let stderr = errors.fileHandleForReading
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                // Drain stderr before waiting, so typst never stalls on a full pipe.
                let data = stderr.readDataToEndOfFile()
                box.process.waitUntilExit()
                return .finished(data)
            }
            group.addTask { [timeout] in
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            if case .timedOut = first { box.process.terminate() }
            group.cancelAll()
            return first
        }
        switch outcome {
        case .timedOut:
            throw .timedOut
        case .finished(let data):
            return Result(status: process.terminationStatus, stderr: String(decoding: data, as: UTF8.self))
        }
    }

    private enum Outcome: Sendable {
        case finished(Data)
        case timedOut
    }
}

/// `Process` isn't marked `Sendable`, but `waitUntilExit()` and `terminate()` are safe to call from
/// another thread. This box lets the reader and the timeout reach the one running process.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

public enum RenderError: Error, Equatable, Sendable {
    case workspace(String)
    case launch(String)
    case compile(String)
    case timedOut
}

extension TypstRunner {
    /// The spike template shipped with this module (T06).
    public static func spikeTemplate() throws(RenderError) -> String {
        guard let url = Bundle.module.url(forResource: "spike", withExtension: "typ", subdirectory: "Templates"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw .workspace("spike template missing from the bundle") }
        return text
    }
}
