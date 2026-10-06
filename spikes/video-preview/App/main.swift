import AppKit

// Host app for the Quick Look preview extension. Launching it once lets
// LaunchServices/PlugInKit discover the embedded .appex.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let label = NSTextField(wrappingLabelWithString:
            "Video Preview Spike is installed.\n\nSelect an .mkv or .webm file in Finder and press Space.")
        label.alignment = .center
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Video Preview Spike"
        label.frame = window.contentView!.bounds.insetBy(dx: 20, dy: 20)
        label.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
