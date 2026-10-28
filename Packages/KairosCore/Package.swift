// swift-tools-version: 6.2
import PackageDescription

// Kairos's core: everything except the SwiftUI screens. Each module is its own target, so the
// compiler enforces the dependency direction in docs/architecture.md:
//
//   KairosKit, SQL, Secrets            foundations, no domain
//   AI                                 language models: providers, tasks, routing
//   Jobs, Resume                       the two domains: postings and the master resume
//   Screening, Tailoring, Render       judging a job, writing for it, printing it
//   Store                              the only module that knows the schema
//   Engine                             runs fetches, screening and builds over the store
//   kairos                             the command-line tool
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "KairosCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "KairosKit", targets: ["KairosKit"]),
        .library(name: "SQL", targets: ["SQL"]),
        .library(name: "Secrets", targets: ["Secrets"]),
        .library(name: "AI", targets: ["AI"]),
        .library(name: "Jobs", targets: ["Jobs"]),
        .library(name: "Resume", targets: ["Resume"]),
        .library(name: "Screening", targets: ["Screening"]),
        .library(name: "Tailoring", targets: ["Tailoring"]),
        .library(name: "Render", targets: ["Render"]),
        .library(name: "Store", targets: ["Store"]),
        .library(name: "Engine", targets: ["Engine"]),
        .executable(name: "kairos", targets: ["KairosCLI"]),
    ],
    targets: [
        .target(name: "KairosKit", swiftSettings: strict),
        .target(name: "SQL", swiftSettings: strict),
        .target(name: "Secrets", swiftSettings: strict),
        .target(name: "AI", dependencies: ["KairosKit", "Secrets"], swiftSettings: strict),
        .target(name: "Jobs", dependencies: ["KairosKit"], resources: [.copy("Resources")], swiftSettings: strict),
        .target(
            name: "Resume", dependencies: ["KairosKit", "AI"], resources: [.copy("Resources")], swiftSettings: strict),
        .target(
            name: "Screening", dependencies: ["KairosKit", "Jobs", "Resume", "AI"], resources: [.copy("Resources")],
            swiftSettings: strict),
        .target(
            name: "Tailoring", dependencies: ["KairosKit", "Resume", "Screening", "AI"],
            resources: [.copy("Resources")], swiftSettings: strict),
        .target(
            name: "Render", dependencies: ["KairosKit", "Resume", "Tailoring"],
            resources: [.copy("Templates"), .copy("Fonts")], swiftSettings: strict),
        .target(
            name: "Store",
            dependencies: ["KairosKit", "SQL", "AI", "Jobs", "Resume", "Screening", "Tailoring"],
            resources: [.copy("Schema")], swiftSettings: strict),
        .target(
            name: "Engine",
            dependencies: [
                "KairosKit", "SQL", "Secrets", "AI", "Jobs", "Resume", "Screening", "Tailoring", "Render", "Store",
            ],
            swiftSettings: strict),
        .executableTarget(
            name: "KairosCLI",
            dependencies: [
                "KairosKit", "SQL", "Secrets", "AI", "Jobs", "Resume", "Screening", "Tailoring", "Render", "Store",
                "Engine",
            ],
            swiftSettings: strict),

        // Shared by the test targets: a scripted HTTP client, fixtures, sample data. Never shipped.
        .target(
            name: "TestKit", dependencies: ["KairosKit", "AI", "Secrets", "Resume"], path: "Tests/TestKit",
            swiftSettings: strict),
        .testTarget(name: "KairosKitTests", dependencies: ["KairosKit", "TestKit"], swiftSettings: strict),
        .testTarget(name: "SQLTests", dependencies: ["SQL"], swiftSettings: strict),
        .testTarget(name: "SecretsTests", dependencies: ["Secrets"], swiftSettings: strict),
        .testTarget(name: "AITests", dependencies: ["AI", "KairosKit", "Secrets", "TestKit"], swiftSettings: strict),
        .testTarget(name: "JobsTests", dependencies: ["Jobs", "KairosKit", "TestKit"], swiftSettings: strict),
        .testTarget(
            name: "ResumeTests", dependencies: ["Resume", "AI", "KairosKit", "TestKit"], swiftSettings: strict),
        .testTarget(
            name: "ScreeningTests", dependencies: ["Screening", "Jobs", "Resume", "AI", "KairosKit", "TestKit"],
            swiftSettings: strict),
        .testTarget(
            name: "TailoringTests", dependencies: ["Tailoring", "Screening", "Resume", "AI", "KairosKit", "TestKit"],
            swiftSettings: strict),
        .testTarget(
            name: "RenderTests", dependencies: ["Render", "Tailoring", "Resume", "KairosKit", "TestKit"],
            swiftSettings: strict),
        // The recorded model replies scored again, and the live evals (KAIROS_LIVE_LLM=1).
        .testTarget(
            name: "EvalTests",
            dependencies: ["AI", "Jobs", "Resume", "Screening", "Tailoring", "KairosKit", "Secrets", "TestKit"],
            swiftSettings: strict),
        .testTarget(
            name: "StoreTests",
            dependencies: ["Store", "SQL", "Jobs", "Resume", "Screening", "Tailoring", "AI", "KairosKit", "TestKit"],
            swiftSettings: strict),
        .testTarget(
            name: "EngineTests",
            dependencies: [
                "Engine", "Store", "SQL", "Secrets", "AI", "Jobs", "Resume", "Screening", "Tailoring", "Render",
                "KairosKit", "TestKit",
            ],
            swiftSettings: strict),
    ]
)
