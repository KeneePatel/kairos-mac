#!/usr/bin/env swift
// floor-guard: diff-scoped enforcement of the CONSTRAINTS.md floor. A Swift
// port of the constraint-driven-development skill's reference guard, with
// patterns for this stack.
//
// Usage: swift scripts/floor-guard.swift [--base <ref>]
//   base defaults to origin/main. Before a remote exists, pass --base HEAD to
//   check uncommitted work against the last commit.
// Exit 0 clean, 1 at least one floor violation, 2 the guard could not run.
// Reports the rule and the location, never the value of a matched secret.
import Foundation

// MARK: - git plumbing

/// nil means the command failed; a nil never reads as clean.
func git(_ args: [String], diffExit: Bool = false) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let status = process.terminationStatus
    // `git diff --no-index` exits 1 whenever the sides differ, the normal case for a new file.
    guard status == 0 || (diffExit && status == 1) else { return nil }
    return String(decoding: data, as: UTF8.self)
}

func bail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("floor-guard: \(message)\n".utf8))
    exit(2)
}

var base = "origin/main"
if let i = CommandLine.arguments.firstIndex(of: "--base"), i + 1 < CommandLine.arguments.count {
    base = CommandLine.arguments[i + 1]
}

guard let top = git(["rev-parse", "--show-toplevel"])?.trimmingCharacters(in: .whitespacesAndNewlines),
    FileManager.default.changeCurrentDirectoryPath(top)
else { bail("not inside a git work tree") }

guard let mergeBase = git(["merge-base", base, "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines),
    !mergeBase.isEmpty
else { bail("no merge base against \(base)") }

guard let tracked = git(["diff", "--unified=0", mergeBase, "--"]) else { bail("could not diff against \(mergeBase)") }
guard let untrackedList = git(["ls-files", "--others", "--exclude-standard"]) else {
    bail("could not list untracked files")
}
var untracked = ""
for file in untrackedList.split(separator: "\n") {
    guard let d = git(["diff", "--no-index", "--unified=0", "/dev/null", String(file)], diffExit: true) else {
        bail("could not diff untracked file \(file)")
    }
    untracked += d + "\n"
}

// MARK: - walk the diff

struct Line { let file: String; let text: String }
var added: [Line] = []
var removed: [Line] = []
var deleted: [String] = []
var file = ""
var oldFile = ""
var inHeader = false

func pathOf(_ s: Substring) -> String {
    let p = String(s)
    return p.hasPrefix("a/") || p.hasPrefix("b/") ? String(p.dropFirst(2)) : p
}

for raw in (tracked + "\n" + untracked).split(separator: "\n", omittingEmptySubsequences: false) {
    let line = Substring(raw)
    if line.hasPrefix("diff ") {
        inHeader = true
    } else if line.hasPrefix("@@") {
        inHeader = false
    } else if inHeader {
        if line.hasPrefix("--- ") {
            oldFile = pathOf(line.dropFirst(4))
        } else if line.hasPrefix("+++ ") {
            let newFile = pathOf(line.dropFirst(4))
            file = newFile == "/dev/null" ? oldFile : newFile
            if newFile == "/dev/null" { deleted.append(file) }
        }
    } else if line.hasPrefix("+") {
        added.append(Line(file: file, text: String(line.dropFirst())))
    } else if line.hasPrefix("-") {
        removed.append(Line(file: file, text: String(line.dropFirst())))
    }
}

// MARK: - rules

struct Finding { let rule: String; let file: String; let text: String }
var findings: [Finding] = []
func flag(_ rule: String, _ file: String, _ text: String) {
    findings.append(Finding(rule: rule, file: file, text: String(text.trimmingCharacters(in: .whitespaces).prefix(120))))
}
func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

let codeExtensions: Set<String> = ["swift", "sh", "js", "sql", "yml", "yaml", "typ"]
func isCode(_ f: String) -> Bool { codeExtensions.contains((f as NSString).pathExtension) }
func isTest(_ f: String) -> Bool { f.contains("/Tests/") || f.hasSuffix("Tests.swift") || f.contains("UITests/") }
func isConstraints(_ f: String) -> Bool { f.hasSuffix("CONSTRAINTS.md") }
let guardFile = "scripts/floor-guard.swift"  // holds these patterns as text

// 1. A checker silenced.
let suppressions =
    #"swift-format-ignore|swiftlint:disable|gitleaks:allow|-suppress-warnings|unsafeFlags\(\[\s*"-w"|nonisolated\(unsafe\)|// *eslint-disable|@ts-ignore"#
// 4. Unfinished work (non-test code).
let stubs =
    #"try!|fatalError\("[^"]*(not implemented|unimplemented|todo)|preconditionFailure\("[^"]*not implemented|catch\s*\{\s*\}|\bTODO\b"#
// 2. A test made easier.
let skips = #"\.disabled\(|XCTSkip|\.enabled\(if:\s*false"#

for line in added where line.file != guardFile {
    if isCode(line.file) && matches(suppressions, line.text) { flag("silenced-checker", line.file, line.text) }
    if isCode(line.file) && !isTest(line.file) && matches(stubs, line.text) {
        flag("unfinished-work", line.file, line.text)
    }
    if isTest(line.file) && matches(skips, line.text) { flag("test-made-easier", line.file, line.text) }
    if isConstraints(line.file) && matches(#"^\| *(W|E)\d+ *\|"#, line.text) { flag("new-exception", line.file, line.text) }
}

// 2b. A test file deleted, or an assertion removed from a test file that remains.
for f in deleted where isTest(f) { flag("test-deleted", f, "file deleted") }
for line in removed where isTest(line.file) && !deleted.contains(line.file) {
    if matches(#"#expect|#require|XCTAssert"#, line.text) { flag("assertion-removed", line.file, line.text) }
}

// 1b/2c. A CONSTRAINTS.md rule weakened or removed. A rule is a floor bullet
// (keyed by its text before the first colon) or a table row (keyed by its
// first cell). Numbers carry a direction read from nearby words: a minimum
// loosens by going down, a maximum by going up, and a number with no readable
// direction is reported whenever it changes.
func ruleKey(_ text: String) -> String? {
    let s = text.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") {
        return s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
    if s.hasPrefix("- ") || s.hasPrefix("* ") {
        return String(s.dropFirst(2)).split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    return nil
}
func isExceptionRow(_ text: String) -> Bool { matches(#"^\| *(W|E)\d+ *\|"#, text.trimmingCharacters(in: .whitespaces)) }

enum Direction { case min, max }
func thresholds(_ text: String) -> [(n: Double, dir: Direction?)] {
    let lower = text.lowercased()
    guard let regex = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#) else { return [] }
    let ns = lower as NSString
    return regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)).map { m in
        let n = Double(ns.substring(with: m.range)) ?? 0
        let beforeStart = max(0, m.range.location - 24)
        let before = ns.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart))
        let afterStart = m.range.location + m.range.length
        let after = ns.substring(with: NSRange(location: afterStart, length: min(40, ns.length - afterStart)))
        if matches(#"(>=|>|≥|at least|minimum|\bmin\b|no less than|not fall|not drop)\s*$"#, before)
            || matches(#"^\s*\S*\s*(or more|or higher|must not fall|must not drop)"#, after)
        {
            return (n, .min)
        }
        if matches(#"(<=|<|≤|at most|maximum|\bmax\b|no more than|under|below|not grow|not exceed)\s*$"#, before)
            || matches(#"^\s*\S*\s*(or less|or lower|must not grow|must not exceed)"#, after)
        {
            return (n, .max)
        }
        return (n, nil)
    }
}

let removedRules = removed.filter { isConstraints($0.file) && ruleKey($0.text) != nil }
let addedRules = added.filter { isConstraints($0.file) && ruleKey($0.text) != nil }
for r in removedRules {
    guard let a = addedRules.first(where: { ruleKey($0.text) == ruleKey(r.text) }) else {
        if !isExceptionRow(r.text) { flag("rule-removed", r.file, r.text) }  // dropping an exception tightens
        continue
    }
    let was = thresholds(r.text)
    let now = thresholds(a.text)
    var verdict: String?
    for dir in [Direction.min, Direction.max, nil] as [Direction?] {
        let b = was.filter { $0.dir == dir }
        let n = now.filter { $0.dir == dir }
        for (i, old) in b.enumerated() where verdict == nil {
            guard i < n.count else {
                verdict = "threshold-removed"
                break
            }
            let new = n[i].n
            if new == old.n { continue }
            switch dir {
            case .min: if new < old.n { verdict = "threshold-loosened" }
            case .max: if new > old.n { verdict = "threshold-loosened" }
            case nil: verdict = "threshold-changed"
            }
        }
    }
    if let verdict { flag(verdict, r.file, r.text + "  ->  " + a.text) }
}

// MARK: - report

if findings.isEmpty {
    print("floor-guard: clean")
    exit(0)
}
var report = "floor-guard: \(findings.count) floor violation(s):\n"
for f in findings { report += "  [\(f.rule)] \(f.file): \(f.text)\n" }
report += "\nEach is a move that lowers the bar. Fix the code, or route it through a tracked exception in CONSTRAINTS.md.\n"
FileHandle.standardError.write(Data(report.utf8))
exit(1)
