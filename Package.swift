// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopyDing",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CopyDing",
            path: "Sources/CopyDing"
        )
    ]
)
