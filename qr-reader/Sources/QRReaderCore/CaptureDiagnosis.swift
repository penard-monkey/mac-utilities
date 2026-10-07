import Foundation

/// Classifies a failed `screencapture` run.
///
/// When the Screen Recording grant is missing — or present but no longer
/// effective, which is what an ad-hoc-signed app hits after every update —
/// `screencapture` does not say "permission denied". It exits non-zero with
/// "could not create image from display/rect" and writes nothing. Showing that
/// string to someone is useless; it is a permission problem and the app has to
/// say so, because this is the single most likely failure after an update.
public enum CaptureDiagnosis {
    public static func isPermissionDenial(status: Int32, stderr: String) -> Bool {
        guard status != 0 else { return false }
        let message = stderr.lowercased()
        return message.contains("could not create image from display")
            || message.contains("could not create image from rect")
            || message.contains("not authorized")
            || message.contains("screen recording")
    }
}
