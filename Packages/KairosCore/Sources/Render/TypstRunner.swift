import Foundation

/// Runs the bundled `typst` binary to turn a template plus JSON content into a PDF.
///
/// Content goes in as a JSON file the template reads with `json(sys.inputs.at("data"))`, so nothing the
/// model writes is ever spliced into Typst source and nothing needs escaping (ADR-004).
public struct TypstRunner: Sendable {
    public let executable: URL
    public let timeout: Duration

    public init(executable: URL, timeout: Duration = .seconds(30)) {
        self.executable = executable
        self.timeout = timeout
    }

    /// Compiles `template` (Typst source) with `data` (JSON bytes) and returns the PDF bytes.
    public func compile(template: String, data: Data) async throws(RenderError) -> Data {
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
        let arguments = [
            "compile",
            "--root", work.path,
            "--input", "data=data.json",
            // Reproducible output: only the fonts embedded in typst (and later, bundled ones).
            "--ignore-system-fonts",
            work.appendingPathComponent("template.typ").path,
            output.path,
        ]
        let result = try await run(arguments)
        guard result.status == 0 else { throw .compile(result.stderr) }
        guard let pdf = fm.contents(atPath: output.path) else { throw .compile("typst wrote no PDF") }
        return pdf
    }

    private struct Result: Sendable {
        let status: Int32
        let stderr: String
    }

    private func run(_ arguments: [String]) async throws(RenderError) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
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
