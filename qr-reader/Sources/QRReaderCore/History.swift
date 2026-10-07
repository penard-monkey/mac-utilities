import Foundation

public enum Decision: String, Codable { case opened, copied, cancelled, refused }

public struct HistoryEntry: Codable, Equatable {
    public let at: Date
    public let type: String
    public let host: String?
    public let payload: String
    public let flags: [String]
    public let decision: Decision
}

/// Redaction happens before anything reaches disk, not on the way out.
public enum Redaction {
    static let sensitiveQueryNames: Set<String> = [
        "secret", "key", "token", "access_token", "id_token", "refresh_token",
        "password", "passwd", "pwd", "pass", "auth", "authorization", "code",
        "session", "sig", "signature", "apikey", "api_key",
    ]

    public static func redact(_ verdict: Verdict) -> String {
        switch verdict.kind {
        case .wifi(let credentials):
            return credentials.password == nil
                ? "WIFI:S:\(credentials.ssid); (no password)"
                : "WIFI:S:\(credentials.ssid); password redacted"
        case .otp(let seed):
            return "otpauth://\(seed.kind)/\(seed.label) secret redacted"
        case .card:
            return "contact card, \(verdict.display.count) characters, not stored"
        case .binary(let data):
            return "binary, \(data.count) bytes"
        case .web(let url), .custom(let url), .blocked(let url), .contact(let url), .location(let url):
            return redactURL(url) ?? cap(verdict.display)
        case .text:
            return cap(verdict.display)
        }
    }

    static func redactURL(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if components.user != nil || components.password != nil {
            components.user = "redacted"
            components.password = nil
        }
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                sensitiveQueryNames.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: "redacted")
                    : item
            }
        }
        return components.string.map { cap($0) }
    }

    static func cap(_ text: String, limit: Int = 300) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

/// Append-only JSON Lines, trimmed to the newest `limit` entries, mode 0600.
public struct HistoryStore {
    public let url: URL
    public let limit: Int

    public init(url: URL, limit: Int = 100) {
        self.url = url
        self.limit = max(1, limit)
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".cache/mac-utilities/qr-reader-history.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func record(_ verdict: Verdict, decision: Decision, at date: Date = Date()) throws {
        let entry = HistoryEntry(at: date, type: verdict.typeName, host: verdict.host,
                                 payload: Redaction.redact(verdict),
                                 flags: verdict.flags.map(\.label), decision: decision)
        var entries = read()
        entries.append(entry)
        try write(Array(entries.suffix(limit)))
    }

    public func read() -> [HistoryEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? Self.decoder.decode(HistoryEntry.self, from: data)
        }
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ entries: [HistoryEntry]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let body = try entries.map { entry -> String in
            String(data: try Self.encoder.encode(entry), encoding: .utf8) ?? ""
        }.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        // atomically: true replaces the file, so the mode has to be set after.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
