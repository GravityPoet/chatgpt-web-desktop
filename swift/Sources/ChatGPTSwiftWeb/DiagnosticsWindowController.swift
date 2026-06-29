import AppKit

struct AppDiagnosticsState {
    let generatedAt: String
    let report: String
}

struct AppDiagnosticsCallbacks {
    let refresh: () -> AppDiagnosticsState
    let exportPackage: (AppDiagnosticsState) -> Void
}

final class DiagnosticsWindowController: NSWindowController {
    private var state: AppDiagnosticsState
    private let callbacks: AppDiagnosticsCallbacks
    private let generatedLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()

    init(state: AppDiagnosticsState, callbacks: AppDiagnosticsCallbacks) {
        self.state = state
        self.callbacks = callbacks

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "诊断"
        window.minSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }

        super.init(window: window)
        setupContent()
        update(state: state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        window?.centerDiagnosticsWindowBeforeFirstShow()
        super.showWindow(sender)
    }

    func update(state: AppDiagnosticsState) {
        self.state = state
        generatedLabel.stringValue = "生成时间：\(state.generatedAt)"
        textView.string = state.report
    }

    private func setupContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "运行诊断")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .labelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshReport(_:)))
        refreshButton.bezelStyle = .rounded

        let copyButton = NSButton(title: "复制诊断信息", target: self, action: #selector(copyReport(_:)))
        copyButton.bezelStyle = .rounded

        let exportButton = NSButton(title: "导出诊断包…", target: self, action: #selector(exportPackage(_:)))
        exportButton.bezelStyle = .rounded

        header.addArrangedSubview(title)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(refreshButton)
        header.addArrangedSubview(copyButton)
        header.addArrangedSubview(exportButton)
        root.addArrangedSubview(header)

        generatedLabel.font = .systemFont(ofSize: 12, weight: .regular)
        generatedLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(generatedLabel)

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        root.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
    }

    @objc private func refreshReport(_ sender: Any?) {
        update(state: callbacks.refresh())
    }

    @objc private func copyReport(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.report, forType: .string)
    }

    @objc private func exportPackage(_ sender: Any?) {
        callbacks.exportPackage(state)
    }
}

private extension NSWindow {
    func centerDiagnosticsWindowBeforeFirstShow() {
        if !isVisible {
            center()
        }
    }
}
