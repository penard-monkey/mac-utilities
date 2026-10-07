import AppKit

/// What the menu bar item is allowed to know without doing any work itself.
/// Written on every launch; the plugin treats it as last-known, not live.
enum StateFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/mac-utilities/qr-reader-state.json")
    }

    static func write(screenRecording: Bool) {
        let state: [String: Any] = [
            "screen_recording": screenRecording,
            "bundle_path": Bundle.main.bundlePath,
            "checked": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
