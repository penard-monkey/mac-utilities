// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MacUtilities", platforms: [.macOS(.v14)], targets: [
    .executableTarget(name: "MacUtilities"),
    .testTarget(name: "MacUtilitiesTests", dependencies: ["MacUtilities"], path: "tests/MacUtilitiesTests")
])
