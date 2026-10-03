// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GIFStickers", platforms: [.macOS(.v14)], targets: [
    .executableTarget(name: "GIFStickers"),
    .testTarget(name: "GIFStickersTests", dependencies: ["GIFStickers"])
])
