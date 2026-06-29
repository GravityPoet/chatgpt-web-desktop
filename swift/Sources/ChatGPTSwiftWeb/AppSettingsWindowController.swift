import AppKit

struct AppSettingsState {
    let appVersion: String
    let currentProfileName: String
    let startupProfileName: String
    let homepage: String
    let promptDraftRestoreEnabled: Bool
    let promptDraftSummary: String
    let profileIsolation: String
    let fingerprintName: String
    let enhancedPrivacyEnabled: Bool
    let webRTCProtectionEnabled: Bool
    let keepThirdPartyLinksInApp: Bool
    let notesAutomationStatus: String
    let updateStatus: String
    let distributionStatus: String
}

struct AppSettingsCallbacks {
    let setPromptDraftRestore: (Bool) -> Void
    let setWebRTCProtection: (Bool) -> Void
    let setThirdPartyLinksInApp: (Bool) -> Void
    let setEnhancedPrivacy: (Bool) -> Void
    let openNotesAutomationPrivacy: () -> Void
    let showDiagnostics: () -> Void
    let checkForUpdates: () -> Void
    let openReleasePage: () -> Void
}

final class AppSettingsWindowController: NSWindowController {
    private enum Section: Int, CaseIterable {
        case general
        case privacy
        case notes
        case distribution

        var title: String {
            switch self {
            case .general:
                return "通用"
            case .privacy:
                return "隐私"
            case .notes:
                return "备忘录"
            case .distribution:
                return "分发"
            }
        }
    }

    private var state: AppSettingsState
    private let callbacks: AppSettingsCallbacks
    private var selectedSection = Section.general
    private let sidebarStack = NSStackView()
    private let contentStack = NSStackView()
    private var sectionButtons: [NSButton] = []

    init(state: AppSettingsState, callbacks: AppSettingsCallbacks) {
        self.state = state
        self.callbacks = callbacks

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.minSize = NSSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }

        super.init(window: window)
        setupContent()
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: AppSettingsState) {
        self.state = state
        render()
    }

    override func showWindow(_ sender: Any?) {
        window?.centerSettingsWindowBeforeFirstShow()
        super.showWindow(sender)
    }

    private func setupContent() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)

        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 4
        sidebarStack.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 14, right: 10)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)

        for section in Section.allCases {
            let button = NSButton(title: section.title, target: self, action: #selector(selectSection(_:)))
            button.tag = section.rawValue
            button.isBordered = false
            button.alignment = .left
            button.setButtonType(.momentaryChange)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.widthAnchor.constraint(equalToConstant: 128).isActive = true
            sidebarStack.addArrangedSubview(button)
            sectionButtons.append(button)
        }

        let contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentArea)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        contentStack.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 24, right: 28)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(contentStack)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 156),

            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor),

            contentArea.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentArea.topAnchor.constraint(equalTo: root.topAnchor),
            contentArea.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: contentArea.topAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentArea.bottomAnchor)
        ])
    }

    @objc private func selectSection(_ sender: NSButton) {
        guard let section = Section(rawValue: sender.tag) else {
            return
        }
        selectedSection = section
        render()
    }

    private func render() {
        for (index, button) in sectionButtons.enumerated() {
            let section = Section(rawValue: index)
            let isSelected = section == selectedSection
            button.title = "\(isSelected ? "●" : " ") \(section?.title ?? "")"
            button.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
            button.contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
        }

        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch selectedSection {
        case .general:
            renderGeneral()
        case .privacy:
            renderPrivacy()
        case .notes:
            renderNotes()
        case .distribution:
            renderDistribution()
        }
    }

    private func renderGeneral() {
        addHeader("通用", "当前窗口仍然只加载 chatgpt.com，原生层负责窗口、状态、隐私和系统集成。")
        addKeyValue("版本", state.appVersion)
        addKeyValue("当前账号空间", state.currentProfileName)
        addKeyValue("启动默认空间", state.startupProfileName)
        addKeyValue("当前空间首页", state.homepage)
        addToggle(
            "恢复输入草稿（本机）",
            detail: "刷新、白屏恢复或 WebKit 进程重启后，尽量把当前空间未发送的输入还原到 ChatGPT 输入框。",
            state: state.promptDraftRestoreEnabled,
            action: #selector(togglePromptDraftRestore(_:))
        )
        addKeyValue("当前草稿", state.promptDraftSummary)
        addKeyValue("数据隔离", state.profileIsolation)
        addActionButton("打开诊断", action: #selector(showDiagnostics(_:)))
    }

    private func renderPrivacy() {
        addHeader("隐私", "这些设置直接复用当前隐私菜单，改动会立即写入本机偏好。")
        addToggle(
            "WebRTC 防护",
            detail: "关闭 WebRTC 构造器暴露；会重建当前 WebView 才能完整生效。",
            state: state.webRTCProtectionEnabled,
            action: #selector(toggleWebRTC(_:))
        )
        addToggle(
            "第三方链接在 App 内打开",
            detail: "关闭后，用户点击的非 OpenAI 链接会交给系统浏览器。",
            state: state.keepThirdPartyLinksInApp,
            action: #selector(toggleThirdPartyLinks(_:))
        )
        addToggle(
            "增强隐私模式（当前空间）",
            detail: "开启 GPC、追踪参数清理、Referrer 降级等当前空间策略。",
            state: state.enhancedPrivacyEnabled,
            action: #selector(toggleEnhancedPrivacy(_:))
        )
        addKeyValue("指纹预设", state.fingerprintName)
    }

    private func renderNotes() {
        addHeader("备忘录", "只读取 Apple Notes 当前选中的文本，并插入网页输入框；不读取 IDE、Terminal 或代码工程。")
        addKeyValue("自动化权限", state.notesAutomationStatus)
        addActionButton("打开系统自动化设置", action: #selector(openNotesAutomationPrivacy(_:)))
    }

    private func renderDistribution() {
        addHeader("分发", "这里显示真实分发状态。自动安装更新需要 Sparkle appcast 和签名 feed，当前只提供发布页检查入口。")
        addKeyValue("更新状态", state.updateStatus)
        addKeyValue("签名 / notarization", state.distributionStatus)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(makeButton("检查更新", action: #selector(checkForUpdates(_:))))
        buttonRow.addArrangedSubview(makeButton("打开发行页", action: #selector(openReleasePage(_:))))
        contentStack.addArrangedSubview(buttonRow)
    }

    private func addHeader(_ title: String, _ detail: String) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(titleLabel)

        let detailLabel = wrappingLabel(detail, color: .secondaryLabelColor)
        contentStack.addArrangedSubview(detailLabel)

        addSpacer(height: 4)
    }

    private func addKeyValue(_ key: String, _ value: String) {
        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        keyLabel.textColor = .secondaryLabelColor

        let valueLabel = wrappingLabel(value, color: .labelColor)
        valueLabel.font = .systemFont(ofSize: 13, weight: .regular)

        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(valueLabel)
        contentStack.addArrangedSubview(row)
    }

    private func addToggle(_ title: String, detail: String, state: Bool, action: Selector) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        button.font = .systemFont(ofSize: 13, weight: .regular)
        button.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = wrappingLabel(detail, color: .secondaryLabelColor)
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)

        stack.addArrangedSubview(button)
        stack.addArrangedSubview(detailLabel)
        contentStack.addArrangedSubview(stack)
    }

    private func addActionButton(_ title: String, action: Selector) {
        contentStack.addArrangedSubview(makeButton(title, action: action))
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        return button
    }

    private func wrappingLabel(_ text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = color
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func addSpacer(height: CGFloat) {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        contentStack.addArrangedSubview(spacer)
    }

    @objc private func toggleWebRTC(_ sender: NSButton) {
        callbacks.setWebRTCProtection(sender.state == .on)
    }

    @objc private func togglePromptDraftRestore(_ sender: NSButton) {
        callbacks.setPromptDraftRestore(sender.state == .on)
    }

    @objc private func toggleThirdPartyLinks(_ sender: NSButton) {
        callbacks.setThirdPartyLinksInApp(sender.state == .on)
    }

    @objc private func toggleEnhancedPrivacy(_ sender: NSButton) {
        callbacks.setEnhancedPrivacy(sender.state == .on)
    }

    @objc private func openNotesAutomationPrivacy(_ sender: Any?) {
        callbacks.openNotesAutomationPrivacy()
    }

    @objc private func showDiagnostics(_ sender: Any?) {
        callbacks.showDiagnostics()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        callbacks.checkForUpdates()
    }

    @objc private func openReleasePage(_ sender: Any?) {
        callbacks.openReleasePage()
    }
}

private extension NSWindow {
    func centerSettingsWindowBeforeFirstShow() {
        guard !isVisible else {
            return
        }
        center()
    }
}
