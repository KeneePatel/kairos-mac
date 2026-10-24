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
        .library(name: "Secrets", targets: ["Secrets"]),
        .library(name: "JobSources", targets: ["JobSources"]),
        .library(name: "Pipeline", targets: ["Pipeline"]),
        .library(name: "MasterResume", targets: ["MasterResume"]),
        .library(name: "LLM", targets: ["LLM"]),
        .library(name: "Screening", targets: ["Screening"]),
        .library(name: "Tailoring", targets: ["Tailoring"]),
    ],
    targets: [
        .target(name: "Store", resources: [.copy("Schema")], swiftSettings: strict),
        .testTarget(name: "StoreTests", dependencies: ["Store"], swiftSettings: strict),
        .target(
            name: "JobSources", dependencies: ["Store"], resources: [.copy("Geo/places.json"), .copy("Catalog")],
            swiftSettings: strict),
        .testTarget(name: "JobSourcesTests", dependencies: ["JobSources", "TestSupport"], swiftSettings: strict),
        .target(name: "LLM", dependencies: ["Secrets", "Store"], resources: [.copy("Prompts")], swiftSettings: strict),
        // LLMTests also reach every module with a task, so PromptPrivacyTests and PromptEvals can
        // render all of their prompts.
        .testTarget(
            name: "LLMTests", dependencies: ["LLM", "TestSupport", "Store", "MasterResume", "Screening", "Tailoring"],
            swiftSettings: strict),
        // Test helpers shared by test targets (the scripted URLProtocol, fixtures). Never shipped.
        .target(name: "TestSupport", path: "Tests/TestSupport", swiftSettings: strict),
        .target(name: "MasterResume", dependencies: ["Store", "LLM"], swiftSettings: strict),
        .testTarget(name: "MasterResumeTests", dependencies: ["MasterResume", "LLM"], swiftSettings: strict),
        .target(name: "Screening", dependencies: ["Store", "LLM", "MasterResume"], swiftSettings: strict),
        .testTarget(
            name: "ScreeningTests", dependencies: ["Screening", "Store", "MasterResume", "LLM"], swiftSettings: strict),
        .target(
            name: "Tailoring", dependencies: ["Store", "LLM", "MasterResume"],
            resources: [.copy("Synonyms.json"), .copy("Spelling")],
            swiftSettings: strict),
        .testTarget(name: "TailoringTests", dependencies: ["Tailoring", "MasterResume", "LLM"], swiftSettings: strict),
        .target(
            name: "Pipeline",
            dependencies: ["Store", "JobSources", "Screening", "LLM", "Tailoring", "Render", "MasterResume"],
            swiftSettings: strict),
        .testTarget(
            name: "PipelineTests",
            dependencies: [
                "Pipeline", "Store", "JobSources", "Screening", "LLM", "MasterResume", "Tailoring", "Render",
                "TestSupport",
            ],
            swiftSettings: strict),
        // Render knows Tailoring's types only (SPEC §4), to lay out a build.
        .target(
            name: "Render", dependencies: ["Tailoring"], resources: [.copy("Templates"), .copy("Fonts")],
            swiftSettings: strict),
        .testTarget(name: "RenderTests", dependencies: ["Render", "Tailoring"], swiftSettings: strict),
        .target(name: "Secrets", swiftSettings: strict),
        .testTarget(name: "SecretsTests", dependencies: ["Secrets"], swiftSettings: strict),
    ]
)
