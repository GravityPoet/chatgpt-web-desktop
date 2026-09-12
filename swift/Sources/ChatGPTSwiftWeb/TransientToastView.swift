import AppKit

final class TransientToastView: NSVisualEffectView {
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制诊断信息", target: nil, action: nil)
    private let dismissButton = NSButton(title: "关闭", target: nil, action: nil)
    private var dismissWorkItem: DispatchWorkItem?
    private var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        setAccessibilityRole(.group)

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .labelColor
        messageLabel.maximumNumberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.isHidden = true
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(actionPressed(_:))

        let actions = NSStackView(views: [actionButton, copyButton, dismissButton])
        actions.spacing = 8
        for button in [copyButton, dismissButton] { button.bezelStyle = .rounded; button.controlSize = .small; button.target = self }
        copyButton.action = #selector(copyDiagnostics)
        dismissButton.action = #selector(dismissToast)
        let stack = NSStackView(views: [messageLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            messageLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480)
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(message: String, actionTitle: String? = nil, action: (() -> Void)? = nil, duration: TimeInterval = 5) {
        dismissWorkItem?.cancel()
        messageLabel.stringValue = message
        actionButton.title = actionTitle ?? ""
        actionButton.isHidden = actionTitle == nil
        copyButton.isHidden = actionTitle == nil || actionTitle == "复制诊断信息"
        dismissButton.setAccessibilityLabel("关闭提示")
        self.action = action
        setAccessibilityLabel(message)
        isHidden = false
        alphaValue = 1
        if duration > 0 {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            dismissWorkItem = work
            let delay = NSWorkspace.shared.isVoiceOverEnabled ? max(30, duration) : duration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isHidden = true
        action = nil
        onDismiss?()
    }

    @objc private func actionPressed(_ sender: Any?) {
        let callback = action
        dismiss()
        callback?()
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(messageLabel.stringValue, forType: .string)
        copyButton.title = "已复制"
    }

    @objc private func dismissToast() { dismiss() }
}
