import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var status: ExtensionStatus
    @State private var busy = false

    private let formats = [
        ("MKV", "Matroska video (.mkv)"),
        ("WebM", "WebM video (.webm)"),
        ("AVI", "AVI video (.avi)"),
        ("FLV", "Flash video (.flv)"),
        ("WMV", "Windows Media video (.wmv)"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video Preview").font(.title2).bold()
                    Text("Press Space on a video in Finder to play it, with sound, right in Quick Look.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GroupBox("Formats") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(formats, id: \.0) { format in
                        HStack {
                            Text(format.0).bold().frame(width: 52, alignment: .leading)
                            Text(format.1).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Quick Look extension") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(dotColor).frame(width: 10, height: 10)
                        Text(stateText).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        switch status.state {
                        case .on:
                            Button("Turn Off") { act { await status.setEnabled(false) } }
                        case .off:
                            Button("Turn On") { act { await status.setEnabled(true) } }
                        case .notRegistered, .otherCopy:
                            Button("Register") { act { await status.registerAndCheck() } }
                        case .checking:
                            ProgressView().controlSize(.small)
                        }
                    }
                    HStack {
                        Button("Refresh Quick Look") { act { await status.refreshQuickLook() } }
                        Button("Check Again") { act { await status.check() } }
                        if busy { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if !status.message.isEmpty {
                        Text(status.message).font(.callout).foregroundStyle(.secondary)
                    }
                    Text("If Finder still shows an icon or its own preview, click Refresh Quick Look and press Space again. Subtitle files next to a video are not loaded.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Playback by VLCKit 3.7.3 from VideoLAN, licensed under the GNU LGPL 2.1 or later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Licenses…") { openLicenses() }
                    .controlSize(.small)
            }
        }
        .padding(20)
    }

    private var stateText: String {
        switch status.state {
        case .checking: return "Checking…"
        case .on: return "On: Quick Look uses Video Preview for these formats."
        case .off: return "Off: turned off for Quick Look."
        case .notRegistered: return "Not registered yet."
        case .otherCopy(let path): return "Registered from another copy: \(path)"
        }
    }

    private var dotColor: Color {
        switch status.state {
        case .on: return .green
        case .off: return .orange
        case .notRegistered, .otherCopy: return .red
        case .checking: return .gray
        }
    }

    private func act(_ work: @escaping @MainActor () async -> Void) {
        busy = true
        Task { @MainActor in
            await work()
            busy = false
        }
    }

    private func openLicenses() {
        guard let resources = Bundle.main.resourceURL else { return }
        let files = ["THIRD_PARTY_NOTICES.md", "VLCKit-LGPL-2.1.txt", "LICENSE"]
            .map { resources.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open(files, withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }
}
