#!/usr/bin/env swift  // Turns design/kairos/tokens.json into code once, so no view holds a raw value:
//   - one Asset Catalog colour set per colour token (Any and Dark appearances),
//     plus AccentColor, so SwiftUI's generated symbols give Color(.inkSecondary)
//   - App/Kairos/DesignTokens.swift with type styles, spacing and radii
//   - AppIcon and the menu bar template image from design/kairos/logo
// Output is deterministic: run it twice and the second run changes nothing.
//
// Usage: swift scripts/gen-tokens.swift   (from anywhere inside the repo)
import Foundation

let fm = FileManager.default
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gen-tokens: \(message)\n".utf8))
    exit(1)
}

// Repo root = the directory holding design/kairos/tokens.json, searching up from here.
var root = URL(fileURLWithPath: fm.currentDirectoryPath)
while !fm.fileExists(atPath: root.appendingPathComponent("design/kairos/tokens.json").path) {
    let parent = root.deletingLastPathComponent()
    if parent.path == root.path { fail("run inside the kairos-mac repo") }
    root = parent
}
let design = root.appendingPathComponent("design/kairos")
let assets = root.appendingPathComponent("App/Kairos/Assets.xcassets")
let swiftOut = root.appendingPathComponent("App/Kairos/DesignTokens.swift")

// MARK: - read tokens.json

struct Tokens: Decodable {
    struct ColorFamily: Decodable { let tokens: [ColorToken] }
    struct ColorToken: Decodable {
        let name: String
        let value: [String: String]
        let usage: String
    }
    struct TypeFamily: Decodable { let groups: [TypeGroup] }
    struct TypeGroup: Decodable {
        let name: String
        let styles: [TypeStyle]
    }
    struct TypeStyle: Decodable {
        let name: String
        let fontSize: String
        let lineHeight: String
        let fontWeight: Int
    }
    struct LengthFamily: Decodable { let tokens: [LengthToken] }
    struct LengthToken: Decodable {
        let name: String
        let value: String
        let usage: String
    }
    let color: ColorFamily
    let type: TypeFamily
    let spacing: LengthFamily
    let radius: LengthFamily
}

guard let data = fm.contents(atPath: design.appendingPathComponent("tokens.json").path),
    let tokens = try? JSONDecoder().decode(Tokens.self, from: data)
else { fail("can't read design/kairos/tokens.json") }

// MARK: - helpers

struct RGBA { let r, g, b, a: Double }

func parseColor(_ text: String) -> RGBA? {
    let s = text.trimmingCharacters(in: .whitespaces).lowercased()
    if s.hasPrefix("#"), s.count == 7, let v = UInt32(s.dropFirst(), radix: 16) {
        return RGBA(
            r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: 1)
    }
    if s.hasPrefix("rgba("), s.hasSuffix(")") {
        let parts = s.dropFirst(5).dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4, let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]),
            let a = Double(parts[3])
        else { return nil }
        return RGBA(r: r / 255, g: g / 255, b: b / 255, a: a)
    }
    return nil
}

func f3(_ x: Double) -> String { String(format: "%.3f", x) }

func colorEntry(_ c: RGBA, dark: Bool) -> [String: Any] {
    var entry: [String: Any] = [
        "color": [
            "color-space": "srgb",
            "components": ["red": f3(c.r), "green": f3(c.g), "blue": f3(c.b), "alpha": f3(c.a)],
        ],
        "idiom": "universal",
    ]
    if dark { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
    return entry
}

let xcodeInfo: [String: Any] = ["author": "xcode", "version": 1]

func writeJSON(_ object: Any, to url: URL) {
    guard
        let json = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { fail("can't encode \(url.lastPathComponent)") }
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard fm.createFile(atPath: url.path, contents: json + Data("\n".utf8)) else { fail("can't write \(url.path)") }
}

func camel(_ name: String) -> String {
    let parts = name.split(separator: "-").map(String.init)
    guard let first = parts.first else { return name }
    return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}

func points(_ length: String) -> String {
    let n = length.replacingOccurrences(of: "px", with: "")
    return n.hasSuffix(".0") ? String(n.dropLast(2)) : n
}

// MARK: - colours

// Start clean so a removed token leaves no stale colour set behind. Only the
// parts this script owns are replaced; anything else in the catalog stays.
for owned in ["Colors", "AccentColor.colorset", "AppIcon.appiconset", "MenuBarIcon.imageset"] {
    try? fm.removeItem(at: assets.appendingPathComponent(owned))
}
writeJSON(["info": xcodeInfo], to: assets.appendingPathComponent("Contents.json"))
writeJSON(
    ["info": xcodeInfo, "properties": ["provides-namespace": false]],
    to: assets.appendingPathComponent("Colors/Contents.json"))

// glass-nav is the mockups' stand-in for Liquid Glass; the app uses system materials instead.
// accent is written once, as AccentColor below: Xcode names that asset's symbol `.accent`, so a
// separate accent colour set would collide with it. Color(.accent) still resolves to the token.
let skipped: Set<String> = ["glass-nav", "accent"]
for token in tokens.color.tokens where !skipped.contains(token.name) {
    guard let lightText = token.value["light"], let light = parseColor(lightText) else {
        fail("\(token.name): unreadable light value")
    }
    let dark = token.value["dark"].flatMap(parseColor) ?? light
    writeJSON(
        ["colors": [colorEntry(light, dark: false), colorEntry(dark, dark: true)], "info": xcodeInfo],
        to: assets.appendingPathComponent("Colors/\(token.name).colorset/Contents.json"))
}

// System controls (selection, default buttons, toggles) pick up the brand accent.
if let accent = tokens.color.tokens.first(where: { $0.name == "accent" }),
    let light = accent.value["light"].flatMap(parseColor)
{
    let dark = accent.value["dark"].flatMap(parseColor) ?? light
    writeJSON(
        ["colors": [colorEntry(light, dark: false), colorEntry(dark, dark: true)], "info": xcodeInfo],
        to: assets.appendingPathComponent("AccentColor.colorset/Contents.json"))
}

// MARK: - icons

func copy(_ from: String, to: URL) {
    let src = design.appendingPathComponent(from)
    guard fm.fileExists(atPath: src.path) else { fail("missing \(from)") }
    try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.removeItem(at: to)
    do { try fm.copyItem(at: src, to: to) } catch { fail("can't copy \(from): \(error)") }
}

// macOS icon slots: (point size, scale, source PNG). 16 and 32 px use the heavier small version.
let iconSlots: [(String, String, String)] = [
    ("16x16", "1x", "logo/png/app-icon-small-16.png"), ("16x16", "2x", "logo/png/app-icon-small-32.png"),
    ("32x32", "1x", "logo/png/app-icon-small-32.png"), ("32x32", "2x", "logo/png/app-icon-default-64.png"),
    ("128x128", "1x", "logo/png/app-icon-default-128.png"), ("128x128", "2x", "logo/png/app-icon-default-256.png"),
    ("256x256", "1x", "logo/png/app-icon-default-256.png"), ("256x256", "2x", "logo/png/app-icon-default-512.png"),
    ("512x512", "1x", "logo/png/app-icon-default-512.png"), ("512x512", "2x", "logo/png/app-icon-default-1024.png"),
]
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
var images: [[String: String]] = []
for (size, scale, source) in iconSlots {
    let file = (source as NSString).lastPathComponent
    copy(source, to: iconSet.appendingPathComponent(file))
    images.append(["filename": file, "idiom": "mac", "scale": scale, "size": size])
}
writeJSON(["images": images, "info": xcodeInfo], to: iconSet.appendingPathComponent("Contents.json"))

let menuBar = assets.appendingPathComponent("MenuBarIcon.imageset")
copy("logo/menubar-template.svg", to: menuBar.appendingPathComponent("menubar-template.svg"))
writeJSON(
    [
        "images": [["filename": "menubar-template.svg", "idiom": "universal"]],
        "info": xcodeInfo,
        "properties": ["preserves-vector-representation": true, "template-rendering-intent": "template"],
    ], to: menuBar.appendingPathComponent("Contents.json"))

// MARK: - DesignTokens.swift

// The README maps each desktop style to a macOS text style, so text follows the user's size settings.
let textStyles: [String: String] = [
    "title1": ".title", "title2": ".title2", "title3": ".title3", "headline": ".headline",
    "body": ".body", "callout": ".callout", "caption": ".subheadline",
]
func weight(_ w: Int) -> String {
    switch w {
    case 700...: ".bold"
    case 600..<700: ".semibold"
    case 500..<600: ".medium"
    default: ".regular"
    }
}

var swift = """
    // Generated by scripts/gen-tokens.swift from design/kairos/tokens.json. Don't edit by hand.
    // Colours aren't here: use the Asset Catalog symbols, e.g. Color(.inkSecondary) or Color(.accent).
    import SwiftUI

    /// Type styles from tokens.json, on macOS text styles so they follow the user's text size.
    enum TypeStyle {

    """
guard let desktop = tokens.type.groups.first(where: { $0.name == "Desktop" }) else { fail("no Desktop type group") }
for style in desktop.styles {
    if let textStyle = textStyles[style.name] {
        swift += "    /// \(points(style.fontSize))/\(points(style.lineHeight)) pt\n"
        swift +=
            "    static let \(camel(style.name)) = Font.system(\(textStyle), weight: \(weight(style.fontWeight)))\n"
    } else {
        swift += "    /// \(points(style.fontSize))/\(points(style.lineHeight)) pt, tabular figures\n"
        swift +=
            "    static let \(camel(style.name)) = Font.system(size: \(points(style.fontSize)), "
            + "weight: \(weight(style.fontWeight))).monospacedDigit()\n"
    }
}
swift += "}\n\n/// Spacing and layout sizes from tokens.json, in points.\nenum Spacing {\n"
for token in tokens.spacing.tokens {
    swift += "    /// \(token.usage)\n    static let \(camel(token.name)): CGFloat = \(points(token.value))\n"
}
swift += "}\n\n/// Corner radii from tokens.json, in points.\nenum Radius {\n"
for token in tokens.radius.tokens {
    let name = camel(token.name.replacingOccurrences(of: "radius-", with: ""))
    swift += "    /// \(token.usage)\n    static let \(name): CGFloat = \(points(token.value))\n"
}
swift += "}\n"
guard fm.createFile(atPath: swiftOut.path, contents: Data(swift.utf8)) else { fail("can't write DesignTokens.swift") }

print("gen-tokens: \(tokens.color.tokens.count - skipped.count) colour sets, AppIcon, MenuBarIcon, DesignTokens.swift")
