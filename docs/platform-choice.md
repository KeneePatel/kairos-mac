# Platform choice: SwiftUI (Xcode) or Tauri 2

**Status:** Recommendation, waiting for the owner's decision · 2026-10-18
**Decides:** SPEC ADR-001 and plan item D02

## Recommendation

**SwiftUI, built with Xcode tools.** Switch to Tauri 2 only if a Windows version becomes likely within about a year.

## Comparison

| | SwiftUI (Xcode) | Tauri 2 |
|---|---|---|
| What you write | Swift for everything | Rust for the backend, plus HTML/CSS/TypeScript for the UI |
| Fit with the spec | Keychain, WebKit page runners, PDFKit, Apple's on-device model, menu bar, notifications and login item are all built-in Swift APIs | Each needs a plugin or crate. Apple's on-device model has no Rust binding, so it needs a Swift bridge anyway |
| Dependencies | 0 packages (the spec's target) | A few hundred Rust crates through Tauri itself, plus an npm toolchain for the UI. That's the opposite of "minimize dependencies" |
| Stability | Mature on macOS. The newest macOS 26 APIs are the least-tested parts | Tauri 2 has been stable since 2024 and ships regular 2.x releases |
| Look and feel | Native macOS 26 (Liquid Glass sidebars and toolbars, system controls, accessibility, Dark Mode) for free | A web UI imitating macOS. It can look good, but menus, focus, text fields and accessibility need extra care |
| App size | About 10 MB, plus Typst (about 40 MB) | About 10–15 MB, plus Typst |
| Windows later | The UI would need a rewrite (the backend and the phone web app already work anywhere) | Same codebase builds for Windows |

## How each one is for me to build

I'm fluent in both. What matters is how quickly I can check my own work.

- **Building and testing:** both work fully from the terminal (`swift test` and `xcodebuild`, or `cargo` and `npm`). The Swift compiler catches API mistakes in seconds. Rust also catches them, but builds are slower and the borrow checker adds fix-up rounds.
- **Turning the design into a UI:** this is where Tauri is easier for me. The design canvas is HTML, so a web UI follows it almost line for line. In SwiftUI I rebuild each screen from native views. The design already follows macOS conventions, so most pieces map to standard SwiftUI views (`NavigationSplitView`, `Table`, `Form`, `inspector`, `.toolbar`).
- **Seeing the result:** neither gives me eyes by default. For both, I'd build the app, capture its window with `screencapture`, and look at the image. Your terminal needs Screen Recording permission for that.
- **Where I'm likeliest to slip:** the newest SwiftUI APIs from macOS 26. The compiler flags those immediately, so the cost is a fix-up round, not a hidden bug.

## Bottom line

The things that make this app good on a Mac are first-party in Swift and bolt-ons in Tauri: private keys in the Keychain, scraping through WebKit, PDF checks with PDFKit, the free on-device model, menu bar life, and zero dependencies. Tauri's real advantages are Windows and easier design handoff. You said Windows is "we'll see", so SwiftUI is the better trade today.

## Sources

- Tauri releases: https://v2.tauri.app/release/
- Liquid Glass in SwiftUI (macOS 26): https://dev.to/diskcleankit/liquid-glass-in-swift-official-best-practices-for-ios-26-macos-tahoe-1coo
