import AppKit
import SwiftUI
import XCTest
@testable import MacUtilities

/// Renders the Updates tab from fixture data. Writes PNGs only when MAC_UTILITIES_RENDER_DIR is set.
@MainActor
final class RenderTests: XCTestCase {
    private func update(_ id: String, _ name: String, _ current: String, _ latest: String, newer: Bool,
                        healthy: Bool = true, issue: String? = nil, external: Bool = false) -> UtilityUpdate {
        UtilityUpdate(id: id, name: name, current: current, latest: latest, available: true, updateAvailable: newer,
                      healthy: healthy, external: external, issue: issue)
    }

    private func model(manager: Bool, _ utilities: [UtilityUpdate]) -> ManagerModel {
        let model = ManagerModel(environment: [:], resources: nil, version: "1.1.0")
        model.releaseStatus = ReleaseStatus(current: "1.1.0", latest: manager ? "v1.1.1" : "v1.1.0",
                                            managerUpdate: manager, utilities: utilities)
        return model
    }

    func testSummaryCounts() {
        let none = model(manager: false, [update("memory", "Memory", "1.0.0", "1.0.0", newer: false)]).releaseStatus!
        XCTAssertEqual(none.updateCount, 0)
        let two = model(manager: true, [update("a", "A", "1.0.0", "1.0.1", newer: true),
                                        update("b", "B", "1.0.0", "1.0.0", newer: false)]).releaseStatus!
        XCTAssertEqual(two.updateCount, 2)
        XCTAssertEqual(two.pendingUtilities.map(\.id), ["a"])
        XCTAssertEqual(two.currentUtilities.map(\.id), ["b"])
        XCTAssertEqual(two.latestVersion, "1.1.1")
    }

    func testRenderUpdatesTab() throws {
        guard let directory = ProcessInfo.processInfo.environment["MAC_UTILITIES_RENDER_DIR"] else { return }
        let cases: [(String, ManagerModel)] = [
            ("up-to-date", model(manager: false, [
                update("memory", "Memory", "1.2.0", "1.2.0", newer: false),
                update("git-settings", "Git & SSH", "1.0.3", "1.0.3", newer: false),
                update("qr-reader", "QR Reader", "1.0.1", "1.0.1", newer: false)])),
            ("two-updates", model(manager: false, [
                update("memory", "Memory", "1.2.0", "1.2.0", newer: false),
                update("git-settings", "Git & SSH", "1.0.3", "1.1.0", newer: true),
                update("qr-reader", "QR Reader", "1.0.1", "1.0.2", newer: true),
                update("private-tool", "Private tool", "0.3.0", "0.3.0", newer: false, external: true)])),
            ("unhealthy", model(manager: false, [
                update("memory", "Memory", "1.2.0", "1.2.0", newer: false),
                update("git-settings", "Git & SSH", "1.0.3", "1.1.0", newer: true, healthy: false,
                       issue: "Installed files changed since they were installed: Git & SSH.app"),
                update("qr-reader", "QR Reader", "1.0.1", "1.0.1", newer: false, healthy: false,
                       issue: "Payload is missing: qr-reader")]))
        ]
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, model) in cases {
            for scheme in [ColorScheme.light, .dark] {
                let view = UpdatesContent(model: model)
                    .frame(width: 780, alignment: .topLeading)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme)
                    .fixedSize(horizontal: false, vertical: true)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                let tiff = try XCTUnwrap(image.tiffRepresentation)
                let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("manager-updates-\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
