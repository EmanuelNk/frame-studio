// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FrameStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FrameStudio",
            path: "Sources/FrameStudio"
        )
    ]
)
