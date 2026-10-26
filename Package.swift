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
                "AppBuild.swift",
                "ConvolutionalCode.swift",
                "Goertzel.swift",
                "LogUIBatcher.swift",
                "Models.swift",
                "OFDMModem.swift",
                "PacketLayout.swift",
                "RunLog.swift",
                "ScanCSVExporter.swift",
                "ScanPayload.swift",
                "ScanProtocol.swift",
                "ScanReceiver.swift",
                "ScanResult.swift",
                "ScanResultBuilder.swift",
                "SpectralSet.swift",
                "StartAdmission.swift",
                "StartRetryState.swift",
                "StopHandoff.swift",
                "TestScenario.swift",
                "WatchActivityState.swift",
                "WorkoutStartPolicy.swift"
            ]
        ),
        .testTarget(
            name: "AquaEchoCoreTests",
            dependencies: ["AquaEchoCore"],
            path: "Tests/AquaEchoCoreTests"
        )
    ]
)
