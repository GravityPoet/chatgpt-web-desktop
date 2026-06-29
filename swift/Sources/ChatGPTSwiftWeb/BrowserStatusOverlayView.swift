import AppKit

enum BrowserStatusOverlayMode: Equatable {
    case hidden
    case slowLoading(progress: Int)
    case recovering(String)
    case blank(String)
    case failed(String)

    var isVisible: Bool {
        self != .hidden
    }

    var title: String {
        switch self {
        case .hidden:
            return ""
        case let .slowLoading(progress):
            return "ChatGPT 仍在加载 \(progress)%"
        case .recovering:
            return "正在恢复页面"
        case .blank:
            return "页面显示为空"
        case .failed:
            return "页面加载失败"
        }
    }

    var detail: String {
        switch self {
        case .hidden:
            return ""
        case .slowLoading:
            return "网页脚本或网络响应偏慢，可以继续等待或重新加载。"
        case let .recovering(reason):
            return reason
        case let .blank(reason):
            return reason
        case let .failed(message):
            return message
        }
    }

    var showsProgress: Bool {
        switch self {
        case .slowLoading, .recovering:
            return true
        case .hidden, .blank, .failed:
            return false
        }
    }

    var primaryButtonTitle: String? {
        switch self {
        case .hidden:
            return nil
        case .slowLoading, .failed:
            return "重新加载"
        case .recovering, .blank:
            return "恢复"
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .hidden:
            return "hidden"
        case let .slowLoading(progress):
            return "slowLoading progress=\(progress)"
        case let .recovering(reason):
            return "recovering \(reason)"
        case let .blank(reason):
            return "blank \(reason)"
        case let .failed(message):
            return "failed \(message)"
        }
    }
}

final class BrowserStatusOverlayView: NSVisualEffectView {
    var primaryAction: (() -> Void)?

    private let progressIndicator = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(mode: BrowserStatusOverlayMode) {
        isHidden = !mode.isVisible
        guard mode.isVisible else {
            progressIndicator.stopAnimation(nil)
            return
        }

        titleLabel.stringValue = mode.title
        detailLabel.stringValue = mode.detail
        setAccessibilityLabel("\(mode.title)。\(mode.detail)")

        progressIndicator.isHidden = !mode.showsProgress
        if mode.showsProgress {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }

        if let title = mode.primaryButtonTitle {
            primaryButton.title = title
            primaryButton.isHidden = false
        } else {
            primaryButton.isHidden = true
        }
    }

    private func configure() {
        material = .popover
        blendingMode = .withinWindow
        state = .active
        isHidden = true
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .small
        primaryButton.target = self
        primaryButton.action = #selector(runPrimaryAction(_:))
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)

        let root = NSStackView()
        root.orientation = .horizontal
        root.alignment = .centerY
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(progressIndicator)
        root.addArrangedSubview(textStack)
        root.addArrangedSubview(primaryButton)
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),

            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            textStack.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
    }

    @objc private func runPrimaryAction(_ sender: Any?) {
        primaryAction?()
    }
}
