import Foundation
import XCTest
@testable import MacUtilities

final class NativeTests: XCTestCase {
    @MainActor
    func testNativeModelChecksAndUpdatesThroughFakeReleaseFeed() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = ["-B", repo.appendingPathComponent("scripts/tests/native_fixture.py").path]
        let output = Pipe()
        let input = Pipe()
        fixture.standardOutput = output
        fixture.standardError = output
        fixture.standardInput = input
        try fixture.run()
        defer {
            try? input.fileHandleForWriting.close()
            fixture.waitUntilExit()
        }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
        }
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: String])
        let home = try XCTUnwrap(config["home"])
        let resources = URL(fileURLWithPath: try XCTUnwrap(config["resources"]))
        var environment = ProcessInfo.processInfo.environment
        environment["MAC_UTILITIES_HOME"] = home
        environment["MAC_UTILITIES_NO_SYSTEM_EFFECTS"] = "1"
        environment["MAC_UTILITIES_RELEASE_BASE_URL"] = config["feed"]
        let model = ManagerModel(environment: environment, resources: resources, version: "1.0.0")
        await model.refresh()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.utilities.contains { $0.id == "memory" && $0.installed })
        await model.checkUpdates()
        XCTAssertNil(model.updateError)
        XCTAssertEqual(model.releaseStatus?.current, "1.0.0")
        XCTAssertEqual(model.releaseStatus?.latest, "v1.0.1")
        XCTAssertEqual(model.releaseStatus?.managerUpdate, true)
        await model.updateRelease(id: "manager")
        XCTAssertNil(model.updateError)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.message?.contains("v1.0.1 installed") == true)
        XCTAssertTrue(model.source.hasSuffix("releases/v1.0.1/Catalog"))
        let receipt = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/mac-utilities/state/manager-app.json")
        let record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertEqual((record["release"] as? [String: String])?["tag"], "v1.0.1")
        let memory = try XCTUnwrap(model.utilities.first { $0.id == "memory" })
        await model.perform("menu", utility: memory, extra: "hide")
        await model.updateRelease(id: "memory")
        XCTAssertNil(model.updateError)
        let memoryReceipt = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/mac-utilities/state/receipts/memory.json")
        let memoryRecord = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: memoryReceipt)) as? [String: Any])
        XCTAssertEqual((memoryRecord["release"] as? [String: String])?["tag"], "v1.0.1")
        XCTAssertEqual(memoryRecord["visible"] as? Bool, false)
        let agents = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path))
    }
}
