// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NESNPlayer", platforms: [.macOS(.v14)], targets: [
    .executableTarget(name: "NESNPlayer"),
    .testTarget(name: "NESNPlayerTests", dependencies: ["NESNPlayer"], path: "Tests/NESNPlayerTests"),
])
