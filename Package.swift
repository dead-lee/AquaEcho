// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AquaEchoCoreTests",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AquaEchoCore",
            path: "Shared",
            sources: [
                "StartAdmission.swift",
                "StartRetryState.swift",
                "WorkoutStartPolicy.swift",
                "StopHandoff.swift",
                "LogUIBatcher.swift"
            ]
        ),
        .testTarget(
            name: "AquaEchoCoreTests",
            dependencies: ["AquaEchoCore"],
            path: "Tests/AquaEchoCoreTests"
        )
    ]
)
