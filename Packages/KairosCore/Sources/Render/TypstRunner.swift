import Foundation
import Synchronization

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
        try await inWorkspace(template: template, data: data) { work throws(RenderError) in
            let output = work.appendingPathComponent("out.pdf")
            var arguments = ["compile"] + options(work)
            if let createdAt { arguments += ["--creation-timestamp", String(Int(createdAt.timeIntervalSince1970))] }
            arguments += [work.appendingPathComponent("template.typ").path, output.path]
            let result = try await run(arguments, home: work)
            guard result.status == 0 else { throw .compile(Self.summary(of: result.stderr)) }
            guard let pdf = FileManager.default.contents(atPath: output.path) else {
                throw .compile("typst wrote no PDF")
            }
            return pdf
        }
    }

    /// Lays `template` out with `data` and returns what `expression` (Typst code, ours, never
    /// content) evaluates to there, as JSON: how the page fitter reads a resume's layout.
    public func evaluate(_ expression: String, template: String, data: Data) async throws(RenderError) -> Data {
        try await inWorkspace(template: template, data: data) { work throws(RenderError) in
            let output = work.appendingPathComponent("value.json")
            let arguments =
                ["eval"] + options(work) + ["--in", work.appendingPathComponent("template.typ").path, expression]
            let result = try await run(arguments, home: work, output: output)
            guard result.status == 0 else { throw .compile(Self.summary(of: result.stderr)) }
            guard let value = FileManager.default.contents(atPath: output.path) else {
                throw .compile("typst returned nothing")
            }
            return value
        }
    }

    /// A throwaway folder holding the template and its data, removed afterwards.
    private func inWorkspace<T>(
        template: String, data: Data, _ body: (URL) async throws(RenderError) -> T
    ) async throws(RenderError) -> T {
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
        return try await body(work)
    }

    private func options(_ work: URL) -> [String] {
        var options = [
            "--root", work.path,
            "--input", "data=data.json",
            // Reproducible output: only typst's built-in fonts and the bundled ones, never this Mac's.
            "--ignore-system-fonts",
            // One line per problem ("template.typ:3:9: error: …"), without colour codes.
            "--diagnostic-format", "short",
        ]
        if let fonts { options += ["--font-path", fonts.path] }
        return options
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

    /// Runs typst and waits for it without blocking a thread. The exit comes from Process's
    /// termination handler, never `waitUntilExit()`, which spins a run loop and can miss an exit
    /// that already happened: a build froze for hours that way (2026-10-20), waiting on a typst that
    /// had exited. The timeout always wins: it stops waiting, asks typst to stop, and kills it if
    /// it doesn't. typst's messages go to a file, and so does its output when `output` names one, so
    /// no pipe can fill up and stall it.
    private func run(_ arguments: [String], home: URL, output: URL? = nil) async throws(RenderError) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // A sealed environment: no TYPST_FONT_PATHS or similar from the user's shell changes the
        // output, and any cache typst wants goes in the throwaway folder.
        process.environment = ["HOME": home.path, "TMPDIR": home.path]
        let log = home.appendingPathComponent("typst-messages.txt")
        guard FileManager.default.createFile(atPath: log.path, contents: nil),
            let messages = FileHandle(forWritingAtPath: log.path)
        else { throw .workspace("can't create typst's message log") }
        defer { try? messages.close() }
        process.standardError = messages
        var written: FileHandle?
        if let output {
            guard FileManager.default.createFile(atPath: output.path, contents: nil),
                let file = FileHandle(forWritingAtPath: output.path)
            else { throw .workspace("can't create typst's output file") }
            written = file
        }
        defer { try? written?.close() }
        process.standardOutput = written ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exit = ExitSignal()
        process.terminationHandler = { exit.finish($0.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw .launch(error.localizedDescription)
        }

        let status: Int32? = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await exit.wait() }
            group.addTask { [timeout] in
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()  // the other child returns at once: neither ever blocks
            return first
        }
        guard let status else {
            await Self.stop(process, exit: exit)
            throw .timedOut
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return Result(status: status, stderr: text)
    }

    /// Asks typst to stop and gives it two seconds, then kills it. Returns once it's been told to
    /// go for good, so a timeout never leaves typst running.
    private static func stop(_ process: Process, exit: ExitSignal) async {
        let pid = process.processIdentifier
        process.terminate()
        for _ in 0..<20 where !exit.hasFinished {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !exit.hasFinished { kill(pid, SIGKILL) }
    }
}

/// typst's exit, from the termination handler, for one waiter. Cancelling the wait ends it at once
/// with nil, so a timeout never waits on a process.
private final class ExitSignal: Sendable {
    private struct State {
        var status: Int32?
        var waiter: CheckedContinuation<Int32?, Never>?
        var cancelled = false
    }

    private let state = Mutex(State())

    var hasFinished: Bool { state.withLock { $0.status != nil } }

    func finish(_ status: Int32) {
        let waiter = state.withLock { state -> CheckedContinuation<Int32?, Never>? in
            state.status = status
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: status)
    }

    func wait() async -> Int32? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                let ready = state.withLock { state -> Int32?? in
                    if let status = state.status { return .some(status) }
                    if state.cancelled { return .some(nil) }
                    state.waiter = continuation
                    return .none
                }
                if case .some(let value) = ready { continuation.resume(returning: value) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Int32?, Never>? in
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: nil)
        }
    }
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
