import XCTest
@testable import Transcribe

final class StubProtocol: URLProtocol {
    // path -> (status, body); a list per path is consumed in order.
    nonisolated(unsafe) static var routes: [String: [(Int, String)]] = [:]
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            StubProtocol.bodies[path] = data
        } else if let b = request.httpBody { StubProtocol.bodies[path] = b }
        var queue = StubProtocol.routes[path] ?? [(404, "{\"detail\":\"Not found\"}")]
        let (status, body) = queue.count > 1 ? queue.removeFirst() : queue[0]
        StubProtocol.routes[path] = queue
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class EngineTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        StubProtocol.routes = [:]; StubProtocol.bodies = [:]
    }

    func client() -> EngineClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return EngineClient(base: URL(string: "http://127.0.0.1:8765")!, jobsDir: tmp.appendingPathComponent("jobs"),
                            session: URLSession(configuration: config), pollMin: 0.01, pollMax: 0.02)
    }

    func testSavePathNeverOverwrites() throws {
        let src = tmp.appendingPathComponent("memo.m4a")
        FileManager.default.createFile(atPath: src.path, contents: Data())
        XCTAssertEqual(TranscriptFile.savePath(for: src).lastPathComponent, "memo.txt")
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("memo.txt").path, contents: Data("mine".utf8))
        XCTAssertEqual(TranscriptFile.savePath(for: src).lastPathComponent, "memo transcript.txt")
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("memo transcript.txt").path, contents: Data())
        XCTAssertEqual(TranscriptFile.savePath(for: src).lastPathComponent, "memo transcript 2.txt")
    }

    func testTranscriptTextIsOneLinePerSegment() {
        let r = EngineResult(text: "hola mundo", segments: [Segment(start: 0, end: 1, text: "hola"), Segment(start: 1, end: 2, text: "mundo")])
        XCTAssertEqual(TranscriptFile.text(r), "hola\nmundo\n")
        XCTAssertEqual(TranscriptFile.text(EngineResult(text: " solo ", segments: [])), "solo\n")
    }

    func testHistoryRoundTripNewestFirstAndPrunes() throws {
        let store = HistoryStore(dir: tmp.appendingPathComponent("history"), keep: 3)
        let r = EngineResult(text: "x", segments: [], language: "es", duration: 2)
        for i in 0..<5 {
            try store.add(source: URL(fileURLWithPath: "/a/\(i).m4a"), saved: nil, result: r, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
        }
        let all = store.load()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.sourceName), ["4.m4a", "3.m4a", "2.m4a"])
        XCTAssertEqual(all.first?.via, "app")
    }

    func testHistoryReadsCliEntries() throws {
        let dir = tmp.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cli = #"{"id": "20261003-120000-abcd1234", "source": "/x/v.mp4", "saved": null, "text": "hi", "language": "en", "duration": null, "created": 1791000000.0, "via": "cli"}"#
        try cli.write(to: dir.appendingPathComponent("20261003-120000-abcd1234.json"), atomically: true, encoding: .utf8)
        let e = HistoryStore(dir: dir).load().first
        XCTAssertEqual(e?.text, "hi"); XCTAssertNil(e?.saved); XCTAssertEqual(e?.via, "cli")
    }

    func testSettingsKeepUnknownKeys() throws {
        let url = tmp.appendingPathComponent("transcribe.json")
        try #"{"port": 9999, "model": "m"}"#.write(to: url, atomically: true, encoding: .utf8)
        var s = TranscribeSettings.load(from: url)
        XCTAssertEqual(s.port, 9999); XCTAssertTrue(s.saveNextToSource)
        s.copyWhenDone = true
        try s.save(to: url)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "m"); XCTAssertEqual(obj["port"] as? Int, 9999)
        XCTAssertEqual(obj["copy_when_done"] as? Bool, true)
    }

    func testClientSendsBasicWithOutputDirAndPolls() async throws {
        StubProtocol.routes["/jobs"] = [(202, #"{"job_id":"j1","status":"queued"}"#)]
        StubProtocol.routes["/jobs/j1"] = [
            (200, #"{"job_id":"j1","status":"running","result":null,"error":null}"#),
            (200, #"{"job_id":"j1","status":"done","error":null,"result":{"text":"hola","segments":[{"start":0,"end":1.5,"text":"hola"}],"language":"es","duration":1.5,"output_file":"/j/a.json"}}"#),
        ]
        let r = try await client().transcribe(URL(fileURLWithPath: "/tmp/a.oga"), language: nil)
        XCTAssertEqual(r.text, "hola"); XCTAssertEqual(r.language, "es"); XCTAssertEqual(r.duration, 1.5)
        let sent = try JSONSerialization.jsonObject(with: StubProtocol.bodies["/jobs"]!) as! [String: String]
        XCTAssertEqual(sent["mode"], "basic")
        XCTAssertEqual(sent["output_dir"], tmp.appendingPathComponent("jobs").path)
        XCTAssertNil(sent["language"])
    }

    func testClientSurfacesEngineErrors() async {
        StubProtocol.routes["/jobs"] = [(202, #"{"job_id":"j2","status":"queued"}"#)]
        StubProtocol.routes["/jobs/j2"] = [(200, #"{"job_id":"j2","status":"error","result":null,"error":"no audio track in s.mp4 — nothing to transcribe"}"#)]
        do { _ = try await client().transcribe(URL(fileURLWithPath: "/tmp/s.mp4"), language: "es"); XCTFail("expected an error") }
        catch { XCTAssertEqual(error.localizedDescription, "no audio track in s.mp4 — nothing to transcribe") }
        StubProtocol.routes["/jobs"] = [(400, #"{"detail":"File not found: /tmp/x"}"#)]
        do { _ = try await client().transcribe(URL(fileURLWithPath: "/tmp/x"), language: nil); XCTFail("expected an error") }
        catch { XCTAssertEqual(error.localizedDescription, "File not found: /tmp/x") }
    }

    func testHealthParsesWarmState() async {
        StubProtocol.routes["/health"] = [(200, #"{"status":"ok","models_loaded":{"whisper":false,"diarization":false},"model":"m"}"#)]
        let h = await client().health()
        XCTAssertEqual(h?.warm, false); XCTAssertEqual(h?.model, "m")
    }
}
