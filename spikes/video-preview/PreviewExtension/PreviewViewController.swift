import AppKit
import OSLog
import QuickLookUI
import VLCKit

private let log = Logger(subsystem: "com.mac-utilities.video-preview-spike", category: "preview")

// Forwards libVLC's own log into the unified log so `log stream` shows it.
final class OSLogVLCLogger: NSObject, VLCLogging {
    var level: VLCLogLevel = .debug
    private let vlcLog = Logger(subsystem: "com.mac-utilities.video-preview-spike", category: "vlc")

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let module = context?.module ?? "-"
        vlcLog.notice("[\(logLevel.rawValue)] \(module, privacy: .public): \(message, privacy: .public)")
    }
}

// View-based Quick Look preview: plays the file with VLCKit, with sound, looping.
final class PreviewViewController: NSViewController, QLPreviewingController, VLCMediaPlayerDelegate {
    private var videoView: VLCVideoView!
    private var player: VLCMediaPlayer?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let videoView = VLCVideoView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        videoView.backColor = .black
        videoView.autoresizingMask = [.width, .height]
        self.videoView = videoView
        view = videoView
        preferredContentSize = NSSize(width: 800, height: 450)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        log.notice("preparePreviewOfFile \(url.path, privacy: .public)")
        await MainActor.run { self.startPlayback(url: url) }
    }

    @MainActor
    private func startPlayback(url: URL) {
        _ = view
        // VLCMediaListPlayer with private options never left "stopped" in testing,
        // and :input-repeat stops paused at EOF; a plain player that restarts
        // itself on end loops reliably.
        let player = VLCMediaPlayer(videoView: videoView)
        player.libraryInstance.loggers = [OSLogVLCLogger()]
        let media = VLCMedia(url: url)
        media.addOption(":no-video-title-show")
        player.media = media
        player.delegate = self
        player.play()
        self.player = player
        log.notice("VLCKit play() issued; libvlc \(VLCLibrary.shared().version, privacy: .public)")

        for delay in [0.5, 2.0, 5.0, 9.0, 14.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let mp = self.player else { return }
                log.notice("after \(delay)s: state=\(VLCMediaPlayerStateToString(mp.state), privacy: .public) playing=\(mp.isPlaying) time=\(mp.time.intValue) hasVideoOut=\(mp.hasVideoOut) audioTracks=\(mp.numberOfAudioTracks) volume=\(mp.audio?.volume ?? -1) window=\(self.view.window != nil)")
            }
        }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player else { return }
        let atEnd = player.state == .ended || (player.state == .paused && player.position > 0.95)
        guard atEnd else { return }
        log.notice("end reached; looping")
        DispatchQueue.main.async {
            player.stop()
            player.play()
        }
    }

    deinit {
        player?.stop()
    }
}
