import XCTest
import CryptoKit
@testable import GIFStickers

final class SayWhatClientTests: XCTestCase {
    private let secret = String(repeating: "a1", count: 32)
    private let success = #"{"ok":true,"kind":"sticker","message_id":"fixture-receipt","chat_jid":"private-data"}"#
    private func fixtureSecret(_ home: URL) throws -> URL {
        let url = home.appendingPathComponent("test-send.secret")
        try Data((secret + "\n").utf8).write(to: url)
        return url
    }
    private func errorMessage(_ operation: () async throws -> Void) async -> String {
        do { try await operation(); XCTFail("Expected send error"); return "" }
        catch { return error.localizedDescription }
    }
    func testExactSignedMultipartBytesAndFreshSecretAtSendTime() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let keyURL = try fixtureSecret(home)
        let rotated = String(repeating: "b2", count: 32)
        let data = try StickerFixtures.animated.get()
        let received = expectation(description: "Signed sticker upload")
        let server = try StubServer { request in
            if request.path == "/health" {
                XCTAssertNil(request.headers["x-saywhat-signature"])
                return .init(body: #"{"ok":false,"gowa":{"ok":true},"transcriber":{"ok":false}}"#)
            }
            XCTAssertEqual(request.path, "/send"); XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.headers["x-saywhat-timestamp"], "1700000000")
            let contentType = request.headers["content-type"] ?? ""
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let boundary = String(contentType.components(separatedBy: "boundary=").last ?? "")
            var expected = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nsticker\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sticker.webp\"\r\nContent-Type: image/webp\r\n\r\n".utf8)
            expected.append(data); expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
            XCTAssertEqual(request.body, expected, "Exactly two parts, with no recipient field and unchanged binary WebP")
            var signed = Data("1700000000.".utf8); signed.append(request.body)
            let mac = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data(rotated.utf8)))
            XCTAssertEqual(request.headers["x-saywhat-signature"], "sha256=" + mac.map { String(format: "%02x", $0) }.joined())
            received.fulfill()
            return .init(body: self.success)
        }
        XCTAssertNotEqual(server.url.port, 3220); XCTAssertNotEqual(server.url.port, 3210)
        let client = SayWhatClient(baseURL: server.url, secretURL: keyURL, now: { Date(timeIntervalSince1970: 1700000000) })
        let availability = await client.availability()
        XCTAssertTrue(availability.ready)
        try Data(rotated.utf8).write(to: keyURL)
        try await client.send(data)
        await fulfillment(of: [received], timeout: 3)
    }
    func testMissingSecretDisablesProbeAndRefusesSendWithoutNetwork() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let server = try StubServer { _ in XCTFail("Must not contact server without a secret"); return .init(body: "{}") }
        let client = SayWhatClient(baseURL: server.url, secretURL: home.appendingPathComponent("missing.secret"))
        let availability = await client.availability()
        XCTAssertFalse(availability.ready); XCTAssertTrue(availability.explanation.contains("send.secret"))
        let data = try StickerFixtures.animated.get()
        let message = await errorMessage { try await client.send(data) }
        XCTAssertTrue(message.contains("send.secret"))
    }
    func testMalformedSecretAndInvalidStickerNeverUpload() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = try fixtureSecret(home)
        let server = try StubServer { _ in XCTFail("Must not upload invalid input"); return .init(body: "{}") }
        let client = SayWhatClient(baseURL: server.url, secretURL: key)
        try Data("invalid secret".utf8).write(to: key)
        let message = await errorMessage { try await client.send(StickerFixtures.animated.get()) }
        XCTAssertTrue(message.contains("send.secret")); XCTAssertFalse(message.contains("invalid secret"))
        try Data(secret.utf8).write(to: key)
        let invalid = await errorMessage { try await client.send(Data("not WebP".utf8)) }
        XCTAssertTrue(invalid.contains("WebP"))
    }
    func testProbeHandlesDisconnectedMalformedAndUnavailableDaemon() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = try fixtureSecret(home)
        for body in [#"{"gowa":{"ok":false,"detail":"private-data"}}"#, "broken"] {
            let server = try StubServer { request in
                XCTAssertEqual(request.path, "/health"); XCTAssertEqual(request.method, "GET")
                return .init(body: body)
            }
            let availability = await SayWhatClient(baseURL: server.url, secretURL: key).availability()
            XCTAssertFalse(availability.ready); XCTAssertFalse(availability.explanation.contains("private-data"))
        }
        let dropped = try StubServer { _ in .init(body: "", closeWithoutResponse: true) }
        let availability = await SayWhatClient(baseURL: dropped.url, secretURL: key).availability()
        XCTAssertFalse(availability.ready); XCTAssertTrue(availability.explanation.contains("unavailable"))
    }
    func testDaemonErrorCodesBecomeReadablePrivateDataFreeMessages() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = try fixtureSecret(home), data = try StickerFixtures.animated.get()
        let cases = ["bad_request": "read", "recipient_not_allowed": "own WhatsApp", "unknown_kind": "recognize",
            "unsupported_type": "WebP", "gowa_unavailable": "reach", "not_logged_in": "logged in", "no_secret": "send.secret",
            "bad_signature": "signature", "stale": "clock", "too_large": "size", "sticker_dimensions": "512",
            "sticker_size": "size", "type_mismatch": "WebP", "too_short": "duration", "gowa_refused": "refused"]
        for (code, phrase) in cases {
            let server = try StubServer { _ in .init(status: 503, body: "{\"ok\":false,\"code\":\"\(code)\",\"error\":\"private-data\"}") }
            let client = SayWhatClient(baseURL: server.url, secretURL: key)
            let message = await errorMessage { try await client.send(data) }
            XCTAssertTrue(message.contains(phrase), "\(code): \(message)")
            XCTAssertFalse(message.contains("private-data"))
        }
        let server = try StubServer { _ in .init(status: 413, body: "private-data") }
        let message = await errorMessage { try await SayWhatClient(baseURL: server.url, secretURL: key).send(data) }
        XCTAssertTrue(message.contains("413")); XCTAssertFalse(message.contains("private-data"))
    }
    func testRedirectDoesNotForwardSignedBody() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = try fixtureSecret(home), data = try StickerFixtures.animated.get()
        let destination = try StubServer { _ in XCTFail("Do not follow a redirect"); return .init(body: self.success) }
        let server = try StubServer { _ in .init(status: 307, body: "{}", headers: ["Location": destination.url.appendingPathComponent("send").absoluteString]) }
        let message = await errorMessage { try await SayWhatClient(baseURL: server.url, secretURL: key).send(data) }
        XCTAssertTrue(message.contains("307"))
    }
    func testLostConnectionAndMalformedSuccessWarnAgainstBlindRetry() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = try fixtureSecret(home), data = try StickerFixtures.animated.get()
        for response in [StubServer.Response(body: "", closeWithoutResponse: true), .init(body: "{}")] {
            let server = try StubServer { _ in response }
            let message = await errorMessage { try await SayWhatClient(baseURL: server.url, secretURL: key).send(data) }
            XCTAssertTrue(message.contains("uncertain")); XCTAssertTrue(message.contains("before sending again"))
        }
    }
    @MainActor func testConfirmationCancellationDoesNotSendAndConfirmedSendUsesStagedBytes() async throws {
        let home = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let key = try fixtureSecret(home), data = try StickerFixtures.animated.get()
        let received = expectation(description: "Only the confirmed send")
        let server = try StubServer { request in
            if request.path == "/health" { return .init(body: #"{"gowa":{"ok":true}}"#) }
            XCTAssertNotNil(request.body.range(of: data)); received.fulfill()
            return .init(body: self.success)
        }
        let model = SendModel(client: SayWhatClient(baseURL: server.url, secretURL: key))
        await model.refresh()
        model.prepare(data); XCTAssertTrue(model.confirming)
        model.cancel(); XCTAssertFalse(model.confirming)
        model.confirm(); XCTAssertFalse(model.busy, "Cancelled confirmation must have no pending send")
        model.prepare(data); model.confirm(); XCTAssertTrue(model.busy)
        model.confirm() // repeated activation must not send twice
        await fulfillment(of: [received], timeout: 3)
        let deadline = Date().addingTimeInterval(3)
        while model.busy && Date() < deadline { await Task.yield() }
        XCTAssertFalse(model.busy); XCTAssertTrue(model.status?.contains("Favourites") == true)
    }
}
