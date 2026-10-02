// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Nudge",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MinderCore",
            targets: ["MinderCore"]
        ),
        .executable(
            name: "Nudge",
            targets: ["Nudge"]
        )
    ],
    targets: [
        .executableTarget(name: "NudgeChecks", dependencies: ["MinderCore"], path: "Tests/ManagedCoreChecks"),
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MinderCore",
            dependencies: ["CSQLite"],
            path: "Sources/MinderCore",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "Nudge",
            dependencies: ["MinderCore"],
            path: "Sources/MinderApp"
        ),
        .testTarget(
            name: "MinderCoreTests",
            dependencies: ["MinderCore"],
            path: "Tests/MinderCoreTests",
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "MinderAppTests",
            dependencies: ["Nudge", "MinderCore"],
            path: "Tests/MinderAppTests"
        )
    ]
)
