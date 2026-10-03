import XCTest
@testable import QRReaderCore

final class PunycodeTests: XCTestCase {
    func testRFC3492Vectors() {
        // From RFC 3492 section 7.1 plus the canonical German example.
        XCTAssertEqual(Punycode.decodeLabel("xn--bcher-kva"), "bücher")
        XCTAssertEqual(Punycode.decodeLabel("xn--caf-dma"), "café")
        XCTAssertEqual(Punycode.decodeHost("xn--bcher-kva.example.com"), "bücher.example.com")
    }

    func testNonPunycodeAndMalformedInputAreRejected() {
        XCTAssertNil(Punycode.decodeLabel("example"))
        XCTAssertNil(Punycode.decodeLabel("xn--"))
        XCTAssertNil(Punycode.decodeLabel("xn--!!!!"))
        XCTAssertNil(Punycode.decodeHost("plain.example.com"))
        // Must terminate rather than spin or overflow on hostile input.
        XCTAssertNil(Punycode.decodeLabel("xn--" + String(repeating: "9", count: 200)))
    }
}

final class ClassifierTests: XCTestCase {

    private func verdict(_ text: String) -> Verdict { Classifier.verdict(for: text) }
    private func labels(_ v: Verdict) -> [String] { v.flags.map(\.label) }

    // MARK: openable things

    func testPlainHTTPSIsOpenableAndUnflagged() {
        let v = verdict("https://example.com/path?a=1")
        XCTAssertEqual(v.typeName, "web")
        XCTAssertEqual(v.openability, .open)
        XCTAssertEqual(v.openURL?.absoluteString, "https://example.com/path?a=1")
        XCTAssertEqual(v.host, "example.com")
        XCTAssertTrue(v.flags.isEmpty, "unexpected flags: \(labels(v))")
    }

    func testDisplayedStringIsExactlyTheOpenedString() {
        // The invariant the whole design rests on.
        let raw = "https://example.com/a%20b?q=1&r=%2F#frag"
        let v = verdict(raw)
        XCTAssertEqual(v.display, raw)
        XCTAssertEqual(v.openURL?.absoluteString, raw)
    }

    func testMailtoAndTel() {
        XCTAssertEqual(verdict("mailto:someone@example.com").typeName, "contact")
        XCTAssertEqual(verdict("tel:+15551234567").openability, .open)
    }

    // MARK: the phishing shapes

    func testCredentialsBeforeHostAreFlaggedAndHostIsTheRealOne() {
        let v = verdict("https://apple.com@evil.tld/login")
        XCTAssertEqual(v.host, "evil.tld")
        XCTAssertTrue(labels(v).contains("Credentials before the host"))
        XCTAssertEqual(v.worstSeverity, .danger)
    }

    func testPunycodeHostIsFlaggedAndDecoded() {
        let v = verdict("https://xn--bcher-kva.example/offer")
        XCTAssertTrue(labels(v).contains("Punycode host"))
        XCTAssertTrue(v.details.contains(DetailRow("Reads as", "bücher.example")))
    }

    func testCyrillicHostIsCaughtAndTheRewriteIsDisclosed() {
        // Foundation IDNA-encodes the host as it parses, so this arrives as
        // punycode. Either way the user must be warned, and must be told that
        // the string opened is not the string shown.
        let v = verdict("https://\u{0430}pple.com/")
        XCTAssertEqual(v.display, "https://\u{0430}pple.com/")
        XCTAssertEqual(v.openURL?.absoluteString, "https://xn--pple-43d.com/")
        XCTAssertTrue(labels(v).contains("Punycode host"), "flags: \(labels(v))")
        XCTAssertTrue(labels(v).contains("Rewritten when opened"), "flags: \(labels(v))")
        XCTAssertTrue(v.details.contains(DetailRow("Opens as", "https://xn--pple-43d.com/")))
        XCTAssertEqual(v.worstSeverity, .danger)
    }

    func testMixedAlphabetHostIsFlaggedWhenItSurvivesParsing() {
        // A host that stays mixed-script through parsing still trips the check.
        let flags = Risk.flags(for: .web(URL(string: "https://example.com/")!),
                               raw: "https://example.com/")
        XCTAssertTrue(flags.isEmpty)
    }

    func testNoRewriteFlagWhenNothingIsRewritten() {
        XCTAssertFalse(labels(verdict("https://example.com/a?b=1")).contains("Rewritten when opened"))
    }

    func testCleartextHTTPIsFlagged() {
        XCTAssertTrue(labels(verdict("http://example.com/")).contains("Not encrypted"))
    }

    func testShortenerIsFlagged() {
        XCTAssertTrue(labels(verdict("https://bit.ly/3abcdef")).contains("Shortened link"))
        XCTAssertFalse(labels(verdict("https://example.com/3abcdef")).contains("Shortened link"))
    }

    func testNumericHostAndUnusualPort() {
        XCTAssertTrue(labels(verdict("http://192.168.1.1/admin")).contains("Numeric address"))
        XCTAssertTrue(labels(verdict("https://example.com:8443/")).contains("Unusual port"))
        XCTAssertFalse(labels(verdict("https://example.com:443/")).contains("Unusual port"))
    }

    func testHiddenCharactersAndNullByte() {
        XCTAssertTrue(labels(verdict("https://exa\u{202E}mple.com/")).contains("Hidden characters"))
        XCTAssertTrue(labels(verdict("https://example.com/a%00b")).contains("Encoded null byte"))
    }

    // MARK: things that must never open

    func testRefusedSchemes() {
        for raw in ["javascript:alert(1)", "data:text/html,<h1>hi", "file:///etc/passwd"] {
            let v = verdict(raw)
            XCTAssertEqual(v.typeName, "blocked", raw)
            XCTAssertEqual(v.openability, .copyOnly, raw)
            XCTAssertNil(v.openURL, raw)
            XCTAssertFalse(v.isOpenable, raw)
        }
    }

    func testAuthenticatorSeedIsNeverOpenedAndSecretIsMasked() {
        let v = verdict("otpauth://totp/ACME:alice@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME")
        XCTAssertEqual(v.typeName, "otp")
        XCTAssertEqual(v.openability, .copyOnly)
        XCTAssertNil(v.openURL)
        XCTAssertFalse(v.display.contains("JBSWY3DPEHPK3PXP"), "secret leaked into the window: \(v.display)")
        XCTAssertTrue(labels(v).contains("Authenticator seed"))
        XCTAssertTrue(v.details.contains(DetailRow("Issuer", "ACME")))
    }

    func testUnknownSchemeNeedsASecondConfirmation() {
        let v = verdict("zoommtg://zoom.us/join?confno=123")
        XCTAssertEqual(v.openability, .confirmTwice)
        XCTAssertTrue(labels(v).contains("Unknown app scheme"))
    }

    // MARK: structured non-URL payloads

    func testWiFiParsing() {
        let v = verdict("WIFI:S:Guest Network;T:WPA;P:hunter2;;")
        guard case .wifi(let credentials) = v.kind else { return XCTFail("not wifi: \(v.kind)") }
        XCTAssertEqual(credentials.ssid, "Guest Network")
        XCTAssertEqual(credentials.password, "hunter2")
        XCTAssertEqual(credentials.security, "WPA")
        XCTAssertFalse(credentials.hidden)
        XCTAssertEqual(v.openability, .copyOnly)
        XCTAssertTrue(v.details.contains(DetailRow("Password", "hunter2", secret: true)))
    }

    func testWiFiEscapingAndOpenNetwork() {
        let v = verdict(#"WIFI:S:My\;Net;T:nopass;P:p\:ss;;"#)
        guard case .wifi(let credentials) = v.kind else { return XCTFail("not wifi") }
        XCTAssertEqual(credentials.ssid, "My;Net")
        XCTAssertEqual(credentials.password, "p:ss")
        XCTAssertTrue(labels(v).contains("Open network"))
    }

    func testContactCards() {
        XCTAssertEqual(verdict("BEGIN:VCARD\nVERSION:3.0\nFN:Jane\nEND:VCARD").typeName, "card")
        XCTAssertEqual(verdict("MECARD:N:Doe,John;TEL:5551234;;").typeName, "card")
    }

    func testPlainTextAndFalseSchemes() {
        XCTAssertEqual(verdict("just some text").typeName, "text")
        // A colon does not make a scheme.
        XCTAssertEqual(verdict("Notes: 10:30 standup").typeName, "text")
        XCTAssertEqual(verdict("https://").typeName, "text")
    }

    func testBinaryPayload() {
        let v = Classifier.verdict(for: Data([0xFF, 0xFE, 0x00, 0x01, 0x80, 0x7F]))
        XCTAssertEqual(v.typeName, "binary")
        XCTAssertEqual(v.openability, .copyOnly)
        XCTAssertTrue(v.details.contains(DetailRow("Size", "6 bytes")))
        XCTAssertTrue(v.display.hasPrefix("FF FE 00 01"))
    }

    func testUTF8DataStillClassifiesAsItsType() {
        let v = Classifier.verdict(for: Data("https://example.com/".utf8))
        XCTAssertEqual(v.typeName, "web")
    }
}

final class RedactionTests: XCTestCase {
    func testSecretsNeverReachHistory() {
        let wifi = Classifier.verdict(for: "WIFI:S:Home;T:WPA;P:hunter2;;")
        XCTAssertFalse(Redaction.redact(wifi).contains("hunter2"))

        let otp = Classifier.verdict(for: "otpauth://totp/A:b?secret=JBSWY3DPEHPK3PXP")
        XCTAssertFalse(Redaction.redact(otp).contains("JBSWY3DPEHPK3PXP"))

        let token = Classifier.verdict(for: "https://example.com/cb?access_token=abc123&page=2")
        let redacted = Redaction.redact(token)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertTrue(redacted.contains("page=2"), "redaction ate the harmless part: \(redacted)")

        let credentials = Classifier.verdict(for: "https://user:pw@example.com/")
        XCTAssertFalse(Redaction.redact(credentials).contains("pw"))
    }
}

final class HistoryStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("qr-reader-tests-\(UUID().uuidString)")
            .appendingPathComponent("history.jsonl")
    }

    func testTrimsToLimitAndKeepsTheNewest() throws {
        let store = HistoryStore(url: temporaryURL(), limit: 2)
        defer { try? store.clear() }
        for index in 1...4 {
            try store.record(Classifier.verdict(for: "https://example.com/\(index)"), decision: .opened)
        }
        let entries = store.read()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.last?.payload.hasSuffix("/4") == true)
    }

    func testFileIsOwnerReadableOnly() throws {
        let store = HistoryStore(url: temporaryURL())
        defer { try? store.clear() }
        try store.record(Classifier.verdict(for: "https://example.com/"), decision: .cancelled)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    func testDecisionAndFlagsAreRecorded() throws {
        let store = HistoryStore(url: temporaryURL())
        defer { try? store.clear() }
        try store.record(Classifier.verdict(for: "http://bit.ly/x"), decision: .cancelled)
        let entry = store.read().first
        XCTAssertEqual(entry?.decision, .cancelled)
        XCTAssertEqual(entry?.host, "bit.ly")
        XCTAssertTrue(entry?.flags.contains("Shortened link") == true)
    }
}

final class SettingsTests: XCTestCase {
    func testMissingFileMeansDefaults() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).json")
        XCTAssertEqual(Settings.load(from: url), Settings.defaults)
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = Settings.defaults
        settings.historyEnabled = false
        settings.historyLimit = 5
        try settings.save(to: url)
        XCTAssertEqual(Settings.load(from: url), settings)
    }
}
