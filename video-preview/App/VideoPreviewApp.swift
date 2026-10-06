import AppKit
import SwiftUI

@main
struct VideoPreviewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var status = ExtensionStatus()

    var body: some Scene {
        Window("Video Preview", id: "main") {
            ContentView(status: status)
                .frame(width: 480)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
