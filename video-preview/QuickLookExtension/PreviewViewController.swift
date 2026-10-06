import AppKit
import OSLog
import QuickLookUI
import VLCKit

private let log = Logger(subsystem: "com.mac-utilities.video-preview", category: "preview")

/// Forwards libVLC errors to the unified log.
final class VLCOSLogger: NSObject, VLCLogging {
    var level: VLCLogLevel = .error
    private let vlcLog = Logger(subsystem: "com.mac-utilities.video-preview", category: "vlc")

    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        // VLCKit passes --quiet itself; libVLC 3 reports it on every preview.
        guard message != "option quiet does not exist" else { return }
        vlcLog.notice("\(context?.module ?? "-", privacy: .public): \(message, privacy: .public)")
    }
}

/// View-based Quick Look preview that plays the file with VLCKit, with sound,
/// looping. Clicking the video pauses and resumes it.
final class PreviewViewController: NSViewController, QLPreviewingController, VLCMediaPlayerDelegate {
    private var videoView: VLCVideoView!
    private var player: VLCMediaPlayer?
    private var pausedByUser = false
    private var reportedStart = false

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let videoView = VLCVideoView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        videoView.backColor = .black
        videoView.autoresizingMask = [.width, .height]
        videoView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(togglePause)))
        self.videoView = videoView
        view = videoView
        preferredContentSize = NSSize(width: 800, height: 450)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        await MainActor.run { self.play(url) }
    }

    @MainActor
    private func play(_ url: URL) {
        _ = view
        // A plain player that restarts itself at the end loops reliably;
        // VLCMediaListPlayer never started and :input-repeat stops paused.
        let player = VLCMediaPlayer(videoView: videoView)
        player.libraryInstance.loggers = [VLCOSLogger()]
        let media = VLCMedia(url: url)
        media.addOption(":no-video-title-show")
        player.media = media
        player.delegate = self
        player.play()
        self.player = player
    }

    @objc private func togglePause() {
        guard let player else { return }
        if player.isPlaying {
            pausedByUser = true
            player.pause()
        } else {
            pausedByUser = false
            player.play()
        }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player else { return }
        let size = player.videoSize
        if player.isPlaying, !reportedStart {
            reportedStart = true
            log.notice("Playback started: video \(Int(size.width))x\(Int(size.height)), audio tracks \(player.numberOfAudioTracks)")
        }
        if size.width > 0, size.height > 0, preferredContentSize != size {
            preferredContentSize = size
        }
        let finished = player.state == .ended || (player.state == .paused && !pausedByUser && player.position > 0.95)
        guard finished else { return }
        DispatchQueue.main.async {
            player.stop()
            player.play()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        player?.stop()
    }

    deinit {
        player?.stop()
    }
}
