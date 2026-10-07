import AppKit
import QRReaderCore

/// Plain panels rather than NSAlert: Phase 0 could not get NSAlert to behave
/// predictably in this app shape, and a panel run with `runModal(for:)`
/// demonstrably waits for a real click.
enum Dialogs {

    enum PermissionChoice { case request, settings, clipboard, cancel }

    static func inform(_ title: String, _ message: String) {
        _ = choose(title: title, message: message, buttons: ["OK"], cancelIndex: 0)
    }

    static func permission() -> PermissionChoice {
        let message = """
        Reading a code off the screen needs Screen Recording permission, and \
        macOS fails silently without it.

        Scanning an image from the clipboard or a file needs no permission at all.
        """
        switch choose(title: "QR Reader needs permission", message: message,
                      buttons: ["Ask macOS Now", "Open Settings…", "Use Clipboard Instead", "Cancel"],
                      cancelIndex: 3) {
        case 0: return .request
        case 1: return .settings
        case 2: return .clipboard
        default: return .cancel
        }
    }

    /// More than one code in the capture: name them and let the user choose.
    static func pick(_ payloads: [DecodedPayload]) -> Int? {
        let titles = payloads.enumerated().map { index, payload -> String in
            let verdict = payload.verdict
            let summary = verdict.display.replacingOccurrences(of: "\n", with: " ")
            let shortened = summary.count > 60 ? String(summary.prefix(60)) + "…" : summary
            return "\(index + 1). \(shortened)"
        }
        let choice = choose(title: "\(payloads.count) codes in that selection",
                            message: "Which one do you want to look at?",
                            buttons: titles + ["Cancel"],
                            cancelIndex: titles.count,
                            vertical: true)
        return (choice == nil || choice == titles.count) ? nil : choice
    }

    /// Returns the index of the button clicked, or nil if the window was closed.
    private static func choose(title: String, message: String, buttons: [String],
                               cancelIndex: Int, vertical: Bool = false) -> Int? {
        let panel = DenyingPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "QR Reader"
        panel.isFloatingPanel = true

        var result: Int?
        let handler = IndexHandler { index in
            result = index
            NSApp.stopModal()
        }
        panel.onCancel = { result = cancelIndex; NSApp.stopModal() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        stack.addView(heading, in: .leading)

        let body = NSTextField(wrappingLabelWithString: message)
        body.preferredMaxLayoutWidth = 410
        body.textColor = .secondaryLabelColor
        stack.addView(body, in: .leading)

        let row = NSStackView()
        row.orientation = vertical ? .vertical : .horizontal
        row.alignment = vertical ? .leading : .centerY
        row.spacing = 8
        for (index, label) in buttons.enumerated() {
            let button = NSButton(title: label, target: handler, action: #selector(IndexHandler.clicked(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            // Only ever the cancelling button answers to Return; Escape is the
            // panel's, so both keys land on the same harmless choice.
            button.keyEquivalent = index == cancelIndex ? "\r" : ""
            if index == cancelIndex { panel.initialFirstResponder = button }
            row.addView(button, in: .leading)
        }
        stack.addView(row, in: .leading)

        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return result
    }
}

private final class IndexHandler: NSObject {
    private let callback: (Int) -> Void
    init(_ callback: @escaping (Int) -> Void) { self.callback = callback }
    @objc func clicked(_ sender: NSButton) { callback(sender.tag) }
}
