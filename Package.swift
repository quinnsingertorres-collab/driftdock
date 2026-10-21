// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Driftdock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Driftdock",
            path: "Sources/Driftdock"
        )
    ]
)
