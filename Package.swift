// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AIUsageKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "AIUsageCore", targets: ["AIUsageCore"]),
        .library(name: "AIUsageDesignSystem", targets: ["AIUsageDesignSystem"]),
        .library(name: "AIUsageMacServices", targets: ["AIUsageMacServices"]),
        .executable(name: "AIUsageMac", targets: ["AIUsageMac"])
    ],
    targets: [
        .target(
            name: "AIUsageCore",
            path: "Sources/AIUsageCore"
        ),
        .target(
            name: "AIUsageDesignSystem",
            dependencies: ["AIUsageCore"],
            path: "Sources/AIUsageDesignSystem",
            resources: [.process("Resources")]
        ),
        .target(
            name: "AIUsageMacServices",
            dependencies: ["AIUsageCore"],
            path: "Sources/AIUsageMacServices",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AIUsageMac",
            dependencies: ["AIUsageCore", "AIUsageDesignSystem", "AIUsageMacServices"],
            path: "App",
            exclude: ["Assets.xcassets"]
        ),
        .testTarget(
            name: "AIUsageMacTests",
            dependencies: ["AIUsageCore", "AIUsageMacServices"],
            path: "Tests/AIUsageMacTests"
        )
    ]
)
