// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "GitSettings", platforms: [.macOS(.v14)], products: [
    .executable(name: "GitSettings", targets: ["GitSettings"])
], targets: [
    .target(name: "GitSettingsCore"),
    .executableTarget(name: "GitSettings", dependencies: ["GitSettingsCore"]),
    .testTarget(name: "GitSettingsCoreTests", dependencies: ["GitSettingsCore"])
])
