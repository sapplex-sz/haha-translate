// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "HaHaCore",
    platforms: [.macOS("15.0")],
    products: [.library(name: "HaHaCore", targets: ["HaHaCore"])],
    targets: [
        .target(name: "HaHaCore", path: "Sources/Core"),
        .testTarget(name: "HaHaCoreTests", dependencies: ["HaHaCore"], path: "Tests")
    ]
)
