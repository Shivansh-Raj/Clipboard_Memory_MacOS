// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipboardMemory",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClipboardCore"),
        .executableTarget(name: "ClipboardMemory", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
    ]
)
