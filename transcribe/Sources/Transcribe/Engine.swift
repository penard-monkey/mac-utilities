import Foundation

// The engine is the local mlx-whisper server (transcribe/engine/server.py) on
// 127.0.0.1:<port>. This file holds everything the window needs that is not
// UI: the HTTP client, where transcripts are saved, the shared history and the
// settings file. The `transcribe` CLI writes the same history and settings.

struct Segment: Codable, Equatable { var start: Double; var end: Double; var text: String }

struct EngineResult: Codable, Equatable {
    var text: String
    var segments: [Segment]
    var language: String?
    var duration: Double?
    var output_file: String?
}

struct EngineHealth: Codable, Equatable {
    var status: String
    var model: String?
    var models_loaded: [String: Bool]?
    var warm: Bool { models_loaded?["whisper"] ?? false }
}

enum EngineError: LocalizedError, Equatable {
    case notRunning(String)
    case rejected(String)
    case failed(String)
    case vanished
    case timedOut
    var errorDescription: String? {
        switch self {
        case .notRunning(let url): return "The transcription engine is not running on \(url). Run `transcribe server start` or reinstall Transcribe."
        case .rejected(let why): return why
        case .failed(let why): return why
        case .vanished: return "The engine restarted while this file was being transcribed. Try again."
        case .timedOut: return "Timed out waiting for the engine."
        }
    }
}

protocol Transcribing: Sendable {
    func health() async -> EngineHealth?
    func transcribe(_ file: URL, language: String?) async throws -> EngineResult
}

struct EngineClient: Transcribing {
    var base: URL
    var jobsDir: URL
    var session: URLSession = .shared
    var pollMin: Double = 0.2
    var pollMax: Double = 2.0
    var timeout: Double = 1800

    func health() async -> EngineHealth? {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(EngineHealth.self, from: data)
    }

    func transcribe(_ file: URL, language: String?) async throws -> EngineResult {
        var body: [String: String] = ["file_path": file.path, "mode": "basic", "output_dir": jobsDir.path]
        if let language, !language.isEmpty { body["language"] = language }
        var req = URLRequest(url: base.appendingPathComponent("jobs"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch { throw EngineError.notRunning(base.absoluteString) }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 202, let jobID = obj["job_id"] as? String else {
            throw EngineError.rejected(obj["detail"] as? String ?? "The engine rejected \(file.lastPathComponent).")
        }
        let started = Date()
        var wait = pollMin
        while true {
            let (d, r) = try await session.data(from: base.appendingPathComponent("jobs").appendingPathComponent(jobID))
            if (r as? HTTPURLResponse)?.statusCode == 404 { throw EngineError.vanished }
            let job = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            switch job["status"] as? String {
            case "done":
                let result = try JSONSerialization.data(withJSONObject: job["result"] ?? [:])
                return try JSONDecoder().decode(EngineResult.self, from: result)
            case "error":
                throw EngineError.failed(job["error"] as? String ?? "Transcription failed.")
            default: break
            }
            if Date().timeIntervalSince(started) > timeout { throw EngineError.timedOut }
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            wait = min(wait * 1.5, pollMax)
        }
    }
}

enum TranscriptFile {
    /// `<stem>.txt` next to the source, then `<stem> transcript.txt`,
    /// `<stem> transcript 2.txt`… — never overwrites. Same rule as the CLI.
    static func savePath(for source: URL, fileManager: FileManager = .default) -> URL {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(stem).txt")
        var n = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem) transcript\(n == 1 ? "" : " \(n)").txt")
            n += 1
        }
        return candidate
    }

    /// One line per segment, which reads better than Whisper's single line.
    static func text(_ result: EngineResult) -> String {
        let lines = result.segments.map(\.text).filter { !$0.isEmpty }
        return (lines.isEmpty ? result.text : lines.joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: String
    var source: String
    var saved: String?
    var text: String
    var language: String?
    var duration: Double?
    var created: Double
    var via: String?
    var sourceName: String { (source as NSString).lastPathComponent }
    var createdDate: Date { Date(timeIntervalSince1970: created) }
}

/// One JSON file per transcript in ~/.cache/mac-utilities/transcribe/history,
/// named so a name sort is a time sort. The app, the CLI and the menu bar all
/// read it; one file per entry means no two writers ever touch the same file.
struct HistoryStore {
    var dir: URL
    var keep = 200

    func load(limit: Int = 200) -> [HistoryEntry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted(by: >).prefix(limit).compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) else { return nil }
            return try? JSONDecoder().decode(HistoryEntry.self, from: data)
        }
    }

    @discardableResult
    func add(source: URL, saved: URL?, result: EngineResult, now: Date = Date()) throws -> HistoryEntry {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let id = f.string(from: now) + "-" + UUID().uuidString.prefix(8).lowercased()
        let entry = HistoryEntry(id: id, source: source.path, saved: saved?.path, text: result.text,
                                 language: result.language, duration: result.duration,
                                 created: now.timeIntervalSince1970, via: "app")
        let data = try JSONEncoder().encode(entry)
        try data.write(to: dir.appendingPathComponent(id + ".json"), options: .atomic)
        prune()
        return entry
    }

    func prune() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        for name in names.dropLast(keep) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }
}

/// ~/.config/mac-utilities/transcribe.json. Unknown keys (port, model — read by
/// the engine installer) survive a save from the window.
struct TranscribeSettings: Equatable {
    var saveNextToSource = true
    var copyWhenDone = false
    var language = ""
    var port = 8765

    static func load(from url: URL) -> TranscribeSettings {
        var s = TranscribeSettings()
        guard let data = FileManager.default.contents(atPath: url.path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return s }
        if let v = obj["save_next_to_source"] as? Bool { s.saveNextToSource = v }
        if let v = obj["copy_when_done"] as? Bool { s.copyWhenDone = v }
        if let v = obj["language"] as? String { s.language = v }
        if let v = obj["port"] as? Int { s.port = v }
        return s
    }

    func save(to url: URL) throws {
        var obj = (FileManager.default.contents(atPath: url.path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        obj["save_next_to_source"] = saveNextToSource
        obj["copy_when_done"] = copyWhenDone
        obj["language"] = language
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let config = home.appendingPathComponent(".config/mac-utilities/transcribe.json")
    static let cache = home.appendingPathComponent(".cache/mac-utilities/transcribe")
    static let history = cache.appendingPathComponent("history")
    static let jobs = cache.appendingPathComponent("jobs")
}
