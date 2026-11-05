// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacSweep",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacSweep", path: "Sources/MacSweep")
    ]
)
