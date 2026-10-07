import AppKit

/// A panel where every ambiguous key ends in "no".
///
/// A button can carry Return or Escape as its key equivalent, not both, so the
/// deny button takes Return and the panel itself takes Escape. Focus starts on
/// the deny button, so a stray Space cannot press something consequential.
final class DenyingPanel: NSPanel {
    var onCancel: () -> Void = {}

    override func cancelOperation(_ sender: Any?) { onCancel() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Escape, whether or not the responder chain maps it
            onCancel()
            return
        }
        super.keyDown(with: event)
    }
}
