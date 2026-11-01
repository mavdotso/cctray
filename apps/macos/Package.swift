// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "cctray",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "cctray", resources: [.process("Resources")]),
        .testTarget(name: "cctrayTests", dependencies: ["cctray"]),
    ]
)
