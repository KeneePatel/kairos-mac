// swift-tools-version: 6.2
import PackageDescription

// One target per module id in SPEC.md §4. Targets only depend in the
// direction the capability map allows, so the compiler enforces it.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "KairosCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Store", targets: ["Store"]),
        .library(name: "Render", targets: ["Render"]),
    ],
    targets: [
        .target(name: "Store", swiftSettings: strict),
        .testTarget(name: "StoreTests", dependencies: ["Store"], swiftSettings: strict),
        .target(name: "Render", resources: [.copy("Templates")], swiftSettings: strict),
        .testTarget(name: "RenderTests", dependencies: ["Render"], swiftSettings: strict),
    ]
)
