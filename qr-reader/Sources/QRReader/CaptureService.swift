import AppKit
import CoreGraphics
import UniformTypeIdentifiers

enum CaptureSource {
    case region
    case clipboard
    case file(URL)
    /// Ask the user for an image. The menu bar cannot show a file picker, so
    /// the app does it.
    case chooseFile
}

enum CaptureError: LocalizedError {
    /// The user pressed escape. Not an error worth a window.
    case cancelled
    case screenRecordingDenied
    case captureFailed(String)
    case noImageOnClipboard
    case notAnImage(URL)

    var errorDescription: String? {
        switch self {
        case .cancelled: return nil
        case .screenRecordingDenied:
            return "QR Reader needs Screen Recording permission to read a code off the screen."
        case .captureFailed(let detail):
            return "The screen capture failed: \(detail)"
        case .noImageOnClipboard:
            return "There is no image on the clipboard."
        case .notAnImage(let url):
            return "\(url.lastPathComponent) is not an image QR Reader can read."
        }
    }
}

/// Produces an image to decode, and never leaves one on disk.
///
/// A captured region can contain anything that was on screen, so the temporary
/// file exists only between `screencapture` writing it and this function
/// reading it, and is removed on every exit path.
enum CaptureService {

    static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The only call that reliably raises the system prompt. Phase 0: when the
    /// grant is missing, `screencapture` just fails silently.
    static func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    static func image(from source: CaptureSource) throws -> CGImage {
        switch source {
        case .region: return try captureRegion()
        case .clipboard: return try clipboardImage()
        case .file(let url): return try fileImage(url)
        case .chooseFile: return try fileImage(try chooseFile())
        }
    }

    private static func captureRegion() throws -> CGImage {
        guard hasScreenRecordingPermission else { throw CaptureError.screenRecordingDenied }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qr-reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent("capture.png")
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive, -s selection only (no window mode), -x no shutter sound.
        task.arguments = ["-i", "-s", "-x", target.path]
        let errors = Pipe()
        task.standardError = errors
        try task.run()
        task.waitUntilExit()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard FileManager.default.fileExists(atPath: target.path) else {
            // Escape during selection exits non-zero and writes nothing.
            if task.terminationStatus != 0 && message.isEmpty { throw CaptureError.cancelled }
            throw message.isEmpty ? CaptureError.cancelled
                                  : CaptureError.captureFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.captureFailed("the capture could not be read back")
        }
        return image
    }

    private static func clipboardImage() throws -> CGImage {
        let pasteboard = NSPasteboard.general
        guard let image = NSImage(pasteboard: pasteboard),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CaptureError.noImageOnClipboard
        }
        return cgImage
    }

    private static func chooseFile() throws -> URL {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image containing a QR code."
        panel.prompt = "Decode"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { throw CaptureError.cancelled }
        return url
    }

    private static func fileImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CaptureError.notAnImage(url)
        }
        return image
    }
}
