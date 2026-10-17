// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AtonemoSonos",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "AtonemoSonos", path: "Sources"),
        .testTarget(name: "AtonemoSonosTests", dependencies: ["AtonemoSonos"], path: "Tests"),
    ]
)
