// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "QRReader", platforms: [.macOS(.v14)], products: [
    .executable(name: "QRReader", targets: ["QRReader"])
], targets: [
    .target(name: "QRReaderCore"),
    .executableTarget(name: "QRReader", dependencies: ["QRReaderCore"]),
    .testTarget(name: "QRReaderCoreTests", dependencies: ["QRReaderCore"])
])
