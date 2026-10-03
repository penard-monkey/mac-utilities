import AppKit
import QRReaderCore

/// QR Reader is a one-shot tool: it launches, scans, acts on one approved
/// decision and quits. Nothing stays resident, so there is no background
/// process holding a Screen Recording grant open, and the SwiftBar plugin can
/// trigger it either by URL scheme or by plain `open -a … --args`.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var settings = Settings.defaults
    private var history = HistoryStore(url: HistoryStore.defaultURL())
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings = Settings.load(from: Settings.defaultURL())
        history = HistoryStore(url: HistoryStore.defaultURL(), limit: settings.historyLimit)
        // The model load overlaps the time the user spends dragging a selection.
        Decoder.warm()
        StateFile.write(screenRecording: CaptureService.hasScreenRecordingPermission)

        if let source = Self.source(from: CommandLine.arguments) {
            run(source)
        } else if !handledLaunchURL {
            // Opened with no instruction at all (Tools launcher, double-click).
            run(.region)
        }
    }

    private var handledLaunchURL = false

    /// `qrreader://scan?source=region|clipboard`, and image files opened with us.
    func application(_ application: NSApplication, open urls: [URL]) {
        handledLaunchURL = true
        for url in urls {
            if url.isFileURL {
                run(.file(url))
            } else if url.scheme?.lowercased() == "qrreader" {
                let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "source" })?.value ?? "region"
                run(Self.source(named: source) ?? .region)
            }
        }
    }

    /// A trigger arriving while we are already running (args are not delivered
    /// to a live instance, so a reopen means "scan a region").
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        run(.region)
        return true
    }

    static func source(from arguments: [String]) -> CaptureSource? {
        for argument in arguments.dropFirst() {
            if argument.hasPrefix("--scan=") {
                return source(named: String(argument.dropFirst("--scan=".count)))
            }
            if argument.hasPrefix("--file=") {
                return .file(URL(fileURLWithPath: String(argument.dropFirst("--file=".count))))
            }
        }
        return nil
    }

    static func source(named name: String) -> CaptureSource? {
        switch name.lowercased() {
        case "region", "screen", "selection": return .region
        case "clipboard", "pasteboard": return .clipboard
        case "file", "image", "choose": return .chooseFile
        default: return nil
        }
    }

    // MARK: the one flow

    private func run(_ source: CaptureSource) {
        guard !busy else { return }
        busy = true
        // Off the launch transaction, so windows reliably reach the screen.
        DispatchQueue.main.async { [self] in
            defer { busy = false; NSApp.terminate(nil) }
            do {
                try scan(source)
            } catch CaptureError.cancelled {
                return
            } catch let error as CaptureError {
                if case .screenRecordingDenied = error {
                    offerScreenRecordingPermission()
                } else {
                    Dialogs.inform("QR Reader", error.errorDescription ?? "Something went wrong.")
                }
            } catch {
                Dialogs.inform("QR Reader", error.localizedDescription)
            }
        }
    }

    private func scan(_ source: CaptureSource) throws {
        let image = try CaptureService.image(from: source)
        let payloads = Decoder.decode(image)

        guard !payloads.isEmpty else {
            Dialogs.inform("No code found", Self.emptyAdvice(for: source))
            return
        }

        let chosen: DecodedPayload
        if payloads.count == 1 {
            chosen = payloads[0]
        } else if let index = Dialogs.pick(payloads) {
            chosen = payloads[index]
        } else {
            return
        }

        let verdict = chosen.verdict
        let decision = ApprovalWindowController.present(verdict, settings: settings)
        act(decision, on: verdict)
    }

    private func act(_ decision: ApprovalDecision, on verdict: Verdict) {
        switch decision {
        case .open:
            // The URL built during classification, never a re-parse of the
            // string on screen: what was approved is what is opened.
            if let url = verdict.openURL, verdict.isOpenable {
                NSWorkspace.shared.open(url)
            }
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.copyText(for: verdict), forType: .string)
        case .cancelled:
            break
        }
        record(verdict, decision: decision)
        SwiftBar.refresh()
    }

    /// Copy hands over the real payload — including a Wi-Fi password or an OTP
    /// secret the window masked. The user asked for it explicitly.
    static func copyText(for verdict: Verdict) -> String {
        switch verdict.kind {
        case .wifi(let credentials): return credentials.password ?? credentials.ssid
        case .otp(let seed): return "otpauth://\(seed.kind)/\(seed.label)"
        case .binary(let data): return data.map { String(format: "%02X", $0) }.joined(separator: " ")
        default: return verdict.display
        }
    }

    private func record(_ verdict: Verdict, decision: ApprovalDecision) {
        guard settings.historyEnabled else { return }
        let outcome: Decision
        switch decision {
        case .open: outcome = .opened
        case .copy: outcome = .copied
        case .cancelled: outcome = verdict.openability == .copyOnly ? .refused : .cancelled
        }
        try? history.record(verdict, decision: outcome)
    }

    static func emptyAdvice(for source: CaptureSource) -> String {
        switch source {
        case .region:
            return "Nothing in that selection decoded as a QR or barcode. Try again with a little more of the code's quiet margin included."
        case .clipboard:
            return "The image on the clipboard has no readable code in it."
        case .file(let url):
            return "No readable code in \(url.lastPathComponent)."
        case .chooseFile:
            return "No readable code in that image."
        }
    }

    private func offerScreenRecordingPermission() {
        let granted = Dialogs.permission()
        switch granted {
        case .request:
            // The only call that reliably raises the system prompt.
            if CaptureService.requestScreenRecordingPermission() {
                Dialogs.inform("Permission granted",
                               "Scan again and QR Reader will be able to read the screen.")
            } else {
                Dialogs.inform("Still blocked",
                               "macOS did not grant the permission. Add QR Reader under Privacy & Security › Screen & System Audio Recording, then scan again.")
            }
        case .settings:
            CaptureService.openScreenRecordingSettings()
        case .clipboard:
            try? scan(.clipboard)
        case .cancel:
            break
        }
    }
}

enum SwiftBar {
    /// Let the menu bar item pick up the new history entry.
    static func refresh() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-g", "swiftbar://refreshplugin?name=qr"]
        try? task.run()
    }
}

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()
