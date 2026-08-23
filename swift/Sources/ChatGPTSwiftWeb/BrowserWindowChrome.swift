import AppKit
import Foundation
import WebKit

private enum NativeToolbarMetrics {
    static let statusHorizontalPadding: CGFloat = 12
    static let statusHeight: CGFloat = 24
    static let progressWidth: CGFloat = 48
    static let progressSpacing: CGFloat = 8
    static let statusMinWidth: CGFloat = 160
    static let statusMaxWidth: CGFloat = 220
}

extension NSToolbarItem.Identifier {
    static let chatGPTBack = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Back")
    static let chatGPTForward = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Forward")
    static let chatGPTReload = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Reload")
    static let chatGPTStatus = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Status")
}

extension BrowserWindowController {
    func configureNativeToolbar() {
        let toolbar = NSToolbar(identifier: "ChatGPTSwiftWeb.NativeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
    }

    func observeWebViewState() {
        webViewObservations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                self?.scheduleNativeChromeStatusUpdate()
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                self?.scheduleNativeChromeStatusUpdate()
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                self?.scheduleNativeChromeStatusUpdate()
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                self?.scheduleNativeChromeStatusUpdate()
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                self?.scheduleNativeChromeStatusUpdate()
            }
        ]
    }

    func scheduleNativeChromeStatusUpdate() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleNativeChromeStatusUpdate()
            }
            return
        }
        guard !isNativeChromeUpdateScheduled else {
            return
        }
        isNativeChromeUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isNativeChromeUpdateScheduled = false
            guard !self.isDisposing else {
                return
            }
            self.updateNativeChromeStatus()
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .chatGPTBack,
            .chatGPTForward,
            .chatGPTReload,
            .chatGPTStatus,
            .flexibleSpace,
            .space
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .chatGPTBack,
            .chatGPTForward,
            .chatGPTReload,
            .flexibleSpace,
            .chatGPTStatus
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .chatGPTBack:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "后退",
                symbolName: "chevron.left",
                action: #selector(goBack(_:))
            )
        case .chatGPTForward:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "前进",
                symbolName: "chevron.right",
                action: #selector(goForward(_:))
            )
        case .chatGPTReload:
            return makeToolbarItem(
                identifier: itemIdentifier,
                label: "重新加载",
                symbolName: "arrow.clockwise",
                action: #selector(reload(_:))
            )
        case .chatGPTStatus:
            return makeStatusToolbarItem(identifier: itemIdentifier)
        default:
            return nil
        }
    }

    func updateNativeChromeStatus() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateNativeChromeStatus()
            }
            return
        }

        toolbarItems[.chatGPTBack]?.isEnabled = webView.canGoBack
        toolbarItems[.chatGPTForward]?.isEnabled = webView.canGoForward

        let reloadItem = toolbarItems[.chatGPTReload]
        if isShowingBlankContent {
            reloadItem?.label = "恢复"
            reloadItem?.paletteLabel = "恢复"
            reloadItem?.toolTip = "恢复空白页面"
        } else {
            reloadItem?.label = "重新加载"
            reloadItem?.paletteLabel = "重新加载"
            reloadItem?.toolTip = "重新加载"
        }

        if webView.isLoading {
            let percent = max(1, min(99, Int(webView.estimatedProgress * 100)))
            setStatus("加载中 \(percent)%", showsProgress: true)
        } else if isCloudflareChallengeActive {
            setStatus("正在完成人机验证…", showsProgress: false)
        } else if lastRenderProbeWasBlank {
            setStatus("页面空白，点击恢复", showsProgress: false)
        } else {
            let location = Self.statusLocationText(for: webView.url)
            let zoom = Int(round(currentZoom * 100))
            setStatus("\(location) · \(zoom)%", showsProgress: false)
        }

        window.toolbar?.validateVisibleItems()
    }

    static func statusLocationText(for url: URL?) -> String {
        if let host = url?.host, !host.isEmpty {
            return host
        }
        if let scheme = url?.scheme, !scheme.isEmpty {
            return "\(scheme.lowercased()):"
        }
        return "未载入"
    }

    func setStatus(_ text: String, showsProgress: Bool) {
        let progressPercent = showsProgress
            ? max(3, min(100, Int(round(webView.estimatedProgress * 100))))
            : 0
        if statusLabel != nil {
            guard text != lastPresentedStatusText
                    || showsProgress != lastPresentedStatusShowsProgress
                    || progressPercent != lastPresentedProgressPercent else {
                return
            }
            lastPresentedStatusText = text
            lastPresentedStatusShowsProgress = showsProgress
            lastPresentedProgressPercent = progressPercent
        }

        statusLabel?.stringValue = text
        statusLabel?.setAccessibilityLabel(text)
        statusContainer?.setAccessibilityLabel(text)
        progressIndicator?.isHidden = !showsProgress
        statusProgressWidthConstraint?.constant = showsProgress ? NativeToolbarMetrics.progressWidth : 0
        statusProgressLabelSpacingConstraint?.constant = showsProgress ? NativeToolbarMetrics.progressSpacing : 0
        let statusWidth = Self.statusToolbarWidth(
            label: statusLabel,
            showsProgress: showsProgress,
            fallbackText: text
        )
        statusWidthConstraint?.constant = statusWidth
        statusContainer?.setFrameSize(NSSize(width: statusWidth, height: NativeToolbarMetrics.statusHeight))
        if showsProgress {
            progressIndicator?.doubleValue = Double(progressPercent) / 100
        } else {
            progressIndicator?.doubleValue = 0
        }
    }

    private func makeToolbarItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbolName: String,
        image: NSImage? = nil,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.image = image ?? NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        toolbarItems[identifier] = item
        return item
    }

    private func makeStatusToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.controlSize = .small
        progress.isHidden = true
        progress.setContentCompressionResistancePriority(.required, for: .horizontal)
        progress.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "chatgpt.com · 100%")
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityLabel("chatgpt.com · 100%")
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let statusWidth = Self.statusToolbarWidth(
            label: label,
            showsProgress: false,
            fallbackText: label.stringValue
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: statusWidth, height: NativeToolbarMetrics.statusHeight))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.staticText)
        container.setAccessibilityLabel("chatgpt.com · 100%")
        container.addSubview(progress)
        container.addSubview(label)

        let widthConstraint = container.widthAnchor.constraint(equalToConstant: statusWidth)
        let progressWidthConstraint = progress.widthAnchor.constraint(equalToConstant: 0)
        let progressLabelSpacingConstraint = label.leadingAnchor.constraint(
            equalTo: progress.trailingAnchor,
            constant: 0
        )

        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: NativeToolbarMetrics.statusHorizontalPadding
            ),
            progress.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            progressWidthConstraint,

            progressLabelSpacingConstraint,
            label.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -NativeToolbarMetrics.statusHorizontalPadding
            ),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            widthConstraint,
            container.heightAnchor.constraint(equalToConstant: NativeToolbarMetrics.statusHeight)
        ])

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "状态"
        item.paletteLabel = "状态"
        item.view = container
        progressIndicator = progress
        statusLabel = label
        statusContainer = container
        statusWidthConstraint = widthConstraint
        statusProgressWidthConstraint = progressWidthConstraint
        statusProgressLabelSpacingConstraint = progressLabelSpacingConstraint
        toolbarItems[identifier] = item
        return item
    }

    private static func statusToolbarWidth(
        label: NSTextField?,
        showsProgress: Bool,
        fallbackText: String
    ) -> CGFloat {
        let statusFont = label?.font ?? .systemFont(ofSize: 12, weight: .regular)
        let fallbackWidth = ceil((fallbackText as NSString).size(withAttributes: [.font: statusFont]).width)
        let measuredText = max(ceil(label?.intrinsicContentSize.width ?? 0), fallbackWidth)
        let progressWidth = showsProgress
            ? NativeToolbarMetrics.progressWidth + NativeToolbarMetrics.progressSpacing
            : 0
        let contentWidth = measuredText + progressWidth + NativeToolbarMetrics.statusHorizontalPadding * 2 + 4
        let minimumWidth = showsProgress ? 0 : NativeToolbarMetrics.statusMinWidth
        let preferredWidth = max(contentWidth, minimumWidth)
        return min(preferredWidth, NativeToolbarMetrics.statusMaxWidth)
    }
}
