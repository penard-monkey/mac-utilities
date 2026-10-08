import AppKit
import QRReaderCore

enum ApprovalDecision { case open, copy, cancelled }

/// The approval window.
///
/// Rules this file exists to enforce:
///   * the only route to Open is a click on the Open button;
///   * Cancel is the default, Escape cancels, closing the window cancels;
///   * nothing is on a timer — no timeout ever approves anything;
///   * the payload is shown in full (wrapped and scrollable, never truncated),
///     because a hidden tail is exactly where a nasty URL puts its surprise.
final class ApprovalWindowController: NSObject, NSWindowDelegate {

    private let verdict: Verdict
    private let settings: Settings
    private let panel: DenyingPanel
    private var decision: ApprovalDecision = .cancelled
    private var detailsStack: NSStackView?
    private var redirectLabel: NSTextField?
    private var revealedSecrets = false

    static func present(_ verdict: Verdict, settings: Settings) -> ApprovalDecision {
        let controller = ApprovalWindowController(verdict: verdict, settings: settings)
        return controller.run()
    }

    init(verdict: Verdict, settings: Settings) {
        self.verdict = verdict
        self.settings = settings
        panel = DenyingPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.delegate = self
        panel.title = "QR Reader"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = buildContent()
        fitPanel()
    }

    /// Width of the text column; the window is this plus the side insets.
    private static let contentWidth: CGFloat = 470

    /// Size the window from the content's real constraints, never from a guess.
    private func fitPanel() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    /// The content view, exposed so a render harness can draw the real layout.
    var contentViewForRendering: NSView { panel.contentView! }

    /// Render-harness hooks: put the window in the Details-open or redirect-result state.
    func showDetailsForRendering() { rebuildDetails(visible: true) }
    func showRedirectResultForRendering(_ text: String) {
        redirectLabel?.isHidden = false
        redirectLabel?.stringValue = text
        fitPanel()
    }

    private func run() -> ApprovalDecision {
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return decision
    }

    // MARK: layout

    private func buildContent() -> NSView {
        let container = NSView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth + 40),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        stack.addView(headerRow(), in: .leading)
        stack.addView(payloadView(), in: .leading)

        for flag in verdict.flags {
            stack.addView(flagRow(flag), in: .leading)
        }

        if !verdict.details.isEmpty {
            let disclosure = NSButton(title: "Details", target: self, action: #selector(toggleDetails))
            disclosure.bezelStyle = .inline
            disclosure.setButtonType(.momentaryPushIn)
            stack.addView(disclosure, in: .leading)

            let details = NSStackView()
            details.orientation = .vertical
            details.alignment = .leading
            details.spacing = 4
            details.isHidden = true
            verdict.details.forEach { details.addView(detailRow($0), in: .leading) }
            detailsStack = details
            stack.addView(details, in: .leading)
        }

        if case .web = verdict.kind, settings.offerRedirectResolution {
            let resolve = NSButton(title: "Resolve redirects…", target: self, action: #selector(resolveRedirects))
            resolve.bezelStyle = .inline
            resolve.toolTip = "Contacts the site to see where it forwards to. This reveals to that server that you scanned the code."
            stack.addView(resolve, in: .leading)

            let label = NSTextField(wrappingLabelWithString: "")
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.isHidden = true
            label.preferredMaxLayoutWidth = Self.contentWidth
            redirectLabel = label
            stack.addView(label, in: .leading)
        }

        stack.addView(buttonRow(), in: .leading)
        return container
    }

    private func headerRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        if let severity = verdict.worstSeverity, severity >= .caution {
            let symbol = severity == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
            let imageView = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            imageView.contentTintColor = severity == .danger ? .systemRed : .systemOrange
            imageView.symbolConfiguration = .init(pointSize: 18, weight: .semibold)
            row.addView(imageView, in: .leading)
        }

        let title = NSTextField(labelWithString: verdict.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        row.addView(title, in: .leading)
        return row
    }

    /// Scrollable and wrapping: the whole payload is visible, including its end.
    private func payloadView() -> NSView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textStorage?.setAttributedString(attributedPayload())

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: verdict.display.count > 120 ? 84 : 52).isActive = true
        return scroll
    }

    /// The host is bold and in the primary colour, the rest dimmed, so the eye
    /// lands on where this actually goes rather than on a familiar-looking prefix.
    private func attributedPayload() -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString(string: verdict.display, attributes: [
            .font: mono, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if let host = verdict.host, let range = Self.authorityHostRange(in: verdict.display, host: host) {
            text.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ], range: NSRange(range, in: verdict.display))
        }
        return text
    }

    /// Finds the host inside the authority, not the first textual match — a path
    /// that repeats the host name must not steal the highlight.
    static func authorityHostRange(in text: String, host: String) -> Range<String.Index>? {
        guard let scheme = text.range(of: "://") else { return text.range(of: host) }
        let authorityStart = scheme.upperBound
        let authorityEnd = text[authorityStart...].firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            ?? text.endIndex
        guard authorityStart <= authorityEnd else { return nil }
        let authority = text[authorityStart..<authorityEnd]
        let searchStart = authority.lastIndex(of: "@").map { authority.index(after: $0) } ?? authorityStart
        return text.range(of: host, range: searchStart..<authorityEnd)
    }

    private func flagRow(_ flag: RiskFlag) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6

        let bullet = NSTextField(labelWithString: "•")
        bullet.textColor = color(for: flag.severity)
        bullet.font = .systemFont(ofSize: 12, weight: .bold)
        row.addView(bullet, in: .leading)

        let text = NSMutableAttributedString(
            string: flag.label + " ",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: color(for: flag.severity)])
        text.append(NSAttributedString(
            string: flag.detail,
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.secondaryLabelColor]))

        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = Self.contentWidth - 20
        row.addView(label, in: .leading)
        return row
    }

    private func color(for severity: RiskFlag.Severity) -> NSColor {
        switch severity {
        case .danger: return .systemRed
        case .caution: return .systemOrange
        case .note: return .secondaryLabelColor
        }
    }

    private func detailRow(_ detail: DetailRow) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline

        let label = NSTextField(labelWithString: detail.label)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        row.addView(label, in: .leading)

        if detail.secret && !revealedSecrets {
            let reveal = NSButton(title: "Reveal", target: self, action: #selector(revealSecrets))
            reveal.bezelStyle = .inline
            row.addView(reveal, in: .leading)
        } else {
            let value = NSTextField(wrappingLabelWithString: detail.value)
            value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            value.lineBreakMode = .byCharWrapping
            value.maximumNumberOfLines = 0
            value.isSelectable = true
            value.preferredMaxLayoutWidth = Self.contentWidth - 80
            value.translatesAutoresizingMaskIntoConstraints = false
            value.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth - 80).isActive = true
            row.addView(value, in: .leading)
        }
        return row
    }

    private func buttonRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        row.addView(spacer, in: .leading)

        // Deliberately: the action button is built first (leftmost) and Cancel
        // last (rightmost, default). Open never sits under a stray Return.
        if verdict.isOpenable, let actionLabel = verdict.actionLabel {
            let action = NSButton(title: actionLabel, target: self, action: #selector(approve))
            action.bezelStyle = .rounded
            action.keyEquivalent = ""
            row.addView(action, in: .leading)
        }

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyPayload))
        copy.bezelStyle = .rounded
        copy.keyEquivalent = ""
        row.addView(copy, in: .leading)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        // Return denies. Escape also denies, via DenyingPanel. Focus starts
        // here, so a stray Space cannot press Open.
        cancel.keyEquivalent = "\r"
        row.addView(cancel, in: .leading)
        panel.initialFirstResponder = cancel
        return row
    }

    // MARK: actions

    @objc private func approve() {
        // A custom scheme hands the payload to an unknown local app, so it costs
        // a second, separate confirmation.
        if verdict.openability == .confirmTwice, !confirmHandoff() { return }
        decision = .open
        NSApp.stopModal()
    }

    @objc private func copyPayload() {
        decision = .copy
        NSApp.stopModal()
    }

    @objc private func cancel() {
        decision = .cancelled
        NSApp.stopModal()
    }

    @objc private func revealSecrets() {
        revealedSecrets = true
        rebuildDetails(visible: true)
    }

    @objc private func toggleDetails() {
        guard let details = detailsStack else { return }
        rebuildDetails(visible: details.isHidden)
    }

    private func rebuildDetails(visible: Bool) {
        guard let details = detailsStack else { return }
        details.views.forEach { details.removeView($0) }
        verdict.details.forEach { details.addView(detailRow($0), in: .leading) }
        details.isHidden = !visible
        fitPanel()
    }

    private func confirmHandoff() -> Bool {
        let scheme = (verdict.openURL?.scheme ?? "unknown") + ":"
        let confirm = DenyingPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        confirm.title = "Confirm handoff"
        var allowed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        let message = NSTextField(wrappingLabelWithString:
            "This hands the payload to whichever app claims \"\(scheme)\". QR Reader cannot see what that app will do with it.")
        message.preferredMaxLayoutWidth = 380
        stack.addView(message, in: .leading)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let go = NSButton(title: "Hand It Over", target: nil, action: nil)
        go.bezelStyle = .rounded
        go.keyEquivalent = ""
        let back = NSButton(title: "Back", target: nil, action: nil)
        back.bezelStyle = .rounded
        back.keyEquivalent = "\r"

        let handler = ButtonHandler { isGo in
            allowed = isGo
            NSApp.stopModal()
        }
        go.target = handler; go.action = #selector(ButtonHandler.yes)
        back.target = handler; back.action = #selector(ButtonHandler.no)
        row.addView(go, in: .leading)
        row.addView(back, in: .leading)
        stack.addView(row, in: .leading)

        confirm.contentView = stack
        confirm.setContentSize(stack.fittingSize)
        confirm.initialFirstResponder = back
        confirm.onCancel = { allowed = false; NSApp.stopModal() }
        confirm.center()
        NSApp.runModal(for: confirm)
        confirm.orderOut(nil)
        return allowed
    }

    @objc private func resolveRedirects() {
        guard let url = verdict.openURL, let label = redirectLabel else { return }
        label.isHidden = false
        label.stringValue = "Resolving…"
        fitPanel()
        RedirectResolver.resolve(url) { [weak self] result in
            label.stringValue = result
            self?.fitPanel()
        }
    }

    // MARK: NSWindowDelegate

    /// Closing the window is a deny, never a silent approval.
    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === panel {
            decision = .cancelled
            NSApp.stopModal()
        }
    }
}

/// Small target holder so the secondary confirmation can use two plain buttons.
private final class ButtonHandler: NSObject {
    private let callback: (Bool) -> Void
    init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
    @objc func yes() { callback(true) }
    @objc func no() { callback(false) }
}
