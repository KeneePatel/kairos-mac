import Foundation
import Testing

@testable import Render

/// A stand-in for typst: a shell script that ignores its arguments.
private func script(_ body: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "fake-typst-\(UUID().uuidString).sh")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// The runner's process handling, which no real typst run exercises: a build that froze for hours
/// (2026-10-20) was waiting in `waitUntilExit` for a typst that had already exited, and the timeout
/// couldn't reach it. These must finish, never hang; the time limit turns a hang into a failure.
@Suite("Typst runner: process lifecycle", .timeLimit(.minutes(1)))
struct TypstRunnerLifecycleTests {
    /// A process that ignores the terminate signal is killed, and the timeout comes back on time
    /// with nothing left running.
    @Test func aTimeoutStopsEvenAProcessThatIgnoresTermination() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "fake-typst-\(UUID().uuidString).pid")
        let stubborn = TypstRunner(
            executable: try script("echo $$ > '\(pidFile.path)'\ntrap '' TERM\nwhile true; do sleep 1; done"),
            fonts: nil, timeout: .seconds(1))
        let started = Date()
        await #expect(throws: RenderError.timedOut) {
            _ = try await stubborn.compile(template: "Hi", data: Data("{}".utf8))
        }
        #expect(Date().timeIntervalSince(started) < 10)
        let pid = try #require(
            Int32(
                String(decoding: Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<20 {
            if kill(pid, 0) != 0 {
                gone = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(gone)
    }

    /// Exits, quick and many at once, are all noticed.
    @Test func manyQuickRunsAllFinish() async throws {
        let quick = TypstRunner(executable: try script("echo 'template.typ:1:1: error: boom' >&2\nexit 1"), fonts: nil)
        let finished = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    do {
                        _ = try await quick.compile(template: "Hi", data: Data("{}".utf8))
                        return false
                    } catch {
                        return (error as? RenderError) == .compile("template.typ:1:1: error: boom")
                    }
                }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(finished == 40)
    }

    /// typst's error output still comes back, however much of it there is.
    @Test func longErrorOutputNeverStallsTheProcess() async throws {
        let noisy = TypstRunner(
            executable: try script(
                "i=0\nwhile [ $i -lt 4000 ]; do echo \"warning: line $i of noise\" >&2; i=$((i+1)); done\nexit 1"),
            fonts: nil, timeout: .seconds(20))
        let error = await #expect(throws: RenderError.self) {
            _ = try await noisy.compile(template: "Hi", data: Data("{}".utf8))
        }
        guard case .compile(let message)? = error else {
            Issue.record("expected a compile error, got \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("warning: line 0 of noise"))
    }
}
