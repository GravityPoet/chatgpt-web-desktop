import AppKit
import Foundation
import WebKit

private enum NativeToolbarMetrics {
    static let statusHorizontalPadding: CGFloat = 12
    static let statusHeight: CGFloat = 24
    static let progressWidth: CGFloat = 48
    static let progressSpacing: CGFloat = 8
    static let statusMinWidth: CGFloat = 96
    static let statusMaxWidth: CGFloat = 112
    static let progressStatusMaxWidth: CGFloat = 180
}

private func actionToolbarContainer(for button: NSButton) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 48, height: 32))
    container.translatesAutoresizingMaskIntoConstraints = false
    button.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(button)
    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalTo: button.widthAnchor, constant: 4),
        container.heightAnchor.constraint(equalToConstant: 32),
        button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
}

enum NativeToolbarLayout {
    static let versionKey = "ChatGPTSwiftWeb.Toolbar.LayoutVersion"
    static let currentVersion = 5
}

extension NSToolbarItem.Identifier {
    static let chatGPTNavigation = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Navigation")
    static let chatGPTBack = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Back")
    static let chatGPTForward = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Forward")
    static let chatGPTReload = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Reload")
    static let chatGPTDownloads = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Downloads")
    static let chatGPTProfile = NSToolbarItem.Identifier("ChatGPTSwiftWeb.Toolbar.Profile")
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
        // Upgrade the saved toolbar once; future user customizations remain untouched.
        if persistent && !UserDefaults.standard.bool(forKey: "ChatGPTSwiftWeb.Toolbar.DownloadsIntroduced") {
            if !toolbar.items.contains(where: { $0.itemIdentifier == .chatGPTDownloads }) {
                let flexibleIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == .flexibleSpace })
                let insertAt = flexibleIndex.map { $0 + 1 } ?? min(3, toolbar.items.count)
                toolbar.insertItem(withItemIdentifier: .chatGPTDownloads, at: min(insertAt, toolbar.items.count))
            }
            UserDefaults.standard.set(true, forKey: "ChatGPTSwiftWeb.Toolbar.DownloadsIntroduced")
        }
        if persistent { migrateToolbarLayoutIfNeeded(toolbar) }
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }
        window.titleVisibility = toolbar.items.contains(where: { $0.itemIdentifier == .chatGPTProfile }) ? .hidden : .visible
    }

    /// Move the account entry once while preserving other customized and removed items.
    func migrateToolbarLayoutIfNeeded(_ toolbar: NSToolbar, defaults: UserDefaults = .standard) {
        let stored = defaults.integer(forKey: NativeToolbarLayout.versionKey)
        if stored >= NativeToolbarLayout.currentVersion {
            return
        }
        let currentIDs = toolbar.items.map(\.itemIdentifier)
        // Fresh toolbars have no saved items yet; AppKit will query the new defaults below.
        if currentIDs.isEmpty {
            defaults.set(NativeToolbarLayout.currentVersion, forKey: NativeToolbarLayout.versionKey)
            return
        }
        let original: [NSToolbarItem.Identifier] = [.chatGPTBack, .chatGPTForward, .chatGPTReload,
            .chatGPTDownloads, .chatGPTProfile, .flexibleSpace, .chatGPTStatus]
        let versionTwo: [NSToolbarItem.Identifier] = [.chatGPTBack, .chatGPTForward, .chatGPTReload,
            .flexibleSpace, .chatGPTDownloads, .chatGPTProfile, .chatGPTStatus]
        let versionThree: [NSToolbarItem.Identifier] = [.chatGPTBack, .chatGPTForward, .chatGPTReload,
            .flexibleSpace, .chatGPTStatus, .chatGPTDownloads, .chatGPTProfile]
        let versionFour: [NSToolbarItem.Identifier] = [.chatGPTNavigation, .flexibleSpace,
            .chatGPTStatus, .chatGPTDownloads, .chatGPTProfile]
        let newOrder = toolbarDefaultItemIdentifiers(toolbar)
        if currentIDs == original || currentIDs == versionTwo || currentIDs == versionThree || currentIDs == versionFour {
            while toolbar.items.count > 0 {
                toolbar.removeItem(at: 0)
            }
            for (index, identifier) in newOrder.enumerated() {
                toolbar.insertItem(withItemIdentifier: identifier, at: index)
            }
        } else if currentIDs.contains(where: { [.chatGPTBack, .chatGPTForward, .chatGPTReload].contains($0) }) {
            var mapped: [NSToolbarItem.Identifier] = []
            var inserted = currentIDs.contains(.chatGPTNavigation)
            for identifier in currentIDs {
                if [.chatGPTBack, .chatGPTForward, .chatGPTReload].contains(identifier) {
                    if !inserted { mapped.append(.chatGPTNavigation); inserted = true }
                } else {
                    mapped.append(identifier)
                }
            }
            while toolbar.items.count > 0 { toolbar.removeItem(at: 0) }
            for (index, identifier) in mapped.enumerated() {
                toolbar.insertItem(withItemIdentifier: identifier, at: index)
            }
        }
        // Move the account entry once, preserving every other customized item.
        if let profileIndex = toolbar.items.firstIndex(where: { $0.itemIdentifier == .chatGPTProfile }) {
            let destination = toolbar.items.firstIndex(where: { $0.itemIdentifier == .chatGPTNavigation }).map { $0 + 1 } ?? 0
            if profileIndex != destination {
                toolbar.removeItem(at: profileIndex)
                let insertAt = toolbar.items.firstIndex(where: { $0.itemIdentifier == .chatGPTNavigation }).map { $0 + 1 } ?? 0
                toolbar.insertItem(withItemIdentifier: .chatGPTProfile, at: insertAt)
            }
        }
        defaults.set(NativeToolbarLayout.currentVersion, forKey: NativeToolbarLayout.versionKey)
    }

    func toolbarWillAddItem(_ notification: Notification) {
        guard notification.object as? NSToolbar === window.toolbar,
              let item = notification.userInfo?["item"] as? NSToolbarItem,
              item.itemIdentifier == .chatGPTProfile else { return }
        window.titleVisibility = .hidden
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
        guard let toolbar = notification.object as? NSToolbar, toolbar === window.toolbar else { return }
        window.titleVisibility = toolbar.items.contains(where: { $0.itemIdentifier == .chatGPTProfile }) ? .hidden : .visible
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
                DispatchQueue.main.async { self?.configureDraftExperience() }
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
        var identifiers: [NSToolbarItem.Identifier] = [
            .chatGPTNavigation,
            .chatGPTDownloads,
            .chatGPTProfile,
            .chatGPTStatus,
            .flexibleSpace,
            .space
        ]
        // Keep legacy identifiers available only long enough for a saved pre-group layout
        // to be read and migrated; never expose them in the current customization palette.
        if UserDefaults.standard.integer(forKey: NativeToolbarLayout.versionKey) < NativeToolbarLayout.currentVersion {
            identifiers.insert(contentsOf: [.chatGPTBack, .chatGPTForward, .chatGPTReload], at: 1)
        }
        return identifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Keep the account switcher beside navigation.
        [
            .chatGPTNavigation,
            .chatGPTProfile,
            .flexibleSpace,
            .chatGPTStatus,
            .chatGPTDownloads
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .chatGPTNavigation:
            return makeNavigationToolbarItem(identifier: itemIdentifier)
        case .chatGPTBack:
            let item = makeToolbarItem(
                identifier: itemIdentifier,
                label: "后退",
                symbolName: "chevron.left",
                action: #selector(goBack(_:))
            )
            item.visibilityPriority = .high
            return item
        case .chatGPTForward:
            let item = makeToolbarItem(
                identifier: itemIdentifier,
                label: "前进",
                symbolName: "chevron.right",
                action: #selector(goForward(_:))
            )
            item.visibilityPriority = .high
            return item
        case .chatGPTReload:
            let item = makeToolbarItem(
                identifier: itemIdentifier,
                label: "重新加载",
                symbolName: "arrow.clockwise",
                action: #selector(reload(_:))
            )
            item.visibilityPriority = .high
            return item
        case .chatGPTProfile:
            return makeProfileToolbarItem(identifier: itemIdentifier)
        case .chatGPTDownloads:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "下载中心"
            item.paletteLabel = item.label
            item.visibilityPriority = .standard
            // Compact icon-first buttons: full meaning lives in tooltip/AX/menu, not in
            // a persistent long title that squeezes the toolbar at ~900-1038px.
            let button = NSButton(title: "", target: self,
                                  action: #selector(showDownloads(_:)))
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "下载中心")
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 32)
            ])
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setAccessibilityLabel(item.label)
            button.toolTip = item.label
            // Keep breathing room around the hit target and download counts.
            item.view = actionToolbarContainer(for: button)
            let menuItem = NSMenuItem(title: "打开下载中心", action: #selector(showDownloads(_:)), keyEquivalent: "")
            menuItem.target = self
            item.menuFormRepresentation = menuItem
            downloadButton = button
            toolbarItems[itemIdentifier] = item
            updateDownloadButton()
            return item
        case .chatGPTStatus:
            let item = makeStatusToolbarItem(identifier: itemIdentifier)
            item.visibilityPriority = .low
            return item
        default:
            return nil
        }
    }

    private func makeProfileToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "账号空间"
        item.paletteLabel = item.label
        item.visibilityPriority = .high

        let button = NSButton(title: "", target: self, action: #selector(showProfileSwitcher(_:)))
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: 13)
        button.imageScaling = .scaleProportionallyDown
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.widthAnchor.constraint(lessThanOrEqualToConstant: isQuickWindow ? 100 : 240),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])

        let group = NSStackView(views: [button])
        group.orientation = .horizontal
        group.alignment = .centerY
        group.spacing = 6
        group.translatesAutoresizingMaskIntoConstraints = false
        group.heightAnchor.constraint(equalToConstant: 32).isActive = true
        item.view = group
        let menuItem = NSMenuItem(title: "账号空间", action: #selector(showProfileSwitcher(_:)), keyEquivalent: "")
        menuItem.target = self
        item.menuFormRepresentation = menuItem
        profileButton = button
        toolbarItems[identifier] = item
        updateProfileButton()
        return item
    }

    func updateNativeChromeStatus() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.updateNativeChromeStatus()
            }
            return
        }

        navigationBackButton?.isEnabled = webView.canGoBack
        navigationForwardButton?.isEnabled = webView.canGoForward
        toolbarItems[.chatGPTBack]?.isEnabled = webView.canGoBack
        toolbarItems[.chatGPTForward]?.isEnabled = webView.canGoForward
        updateRefreshButtonAppearance()
        if let menuItems = toolbarItems[.chatGPTNavigation]?.menuFormRepresentation?.submenu?.items {
            menuItems[0].isEnabled = webView.canGoBack
            menuItems[1].isEnabled = webView.canGoForward
        }

        if let blockedNavigationStatus {
            setStatus(blockedNavigationStatus, showsProgress: false)
        } else if NetworkStatusMonitor.shared.availability == .offline {
            setStatus("网络已断开", showsProgress: false)
        } else if let lastFailureStatus {
            setStatus(lastFailureStatus, showsProgress: false)
        } else if isCloudflareChallengeActive {
            let waiting = cloudflareChallengeLastReason.hasPrefix("等待超过")
                ? "人机验证等待中，请保持当前网络和窗口不变"
                : "正在完成人机验证…"
            setStatus(waiting, showsProgress: false)
        } else if dataLoadState.requiresVerification {
            setStatus("需要完成安全验证，点击验证并重试", showsProgress: false)
        } else if dataLoadState.hasFailure {
            setStatus("\(dataLoadState.summary)加载失败，点击重试", showsProgress: false)
        } else if modelLoadFailureActive {
            setStatus("模型列表加载失败，点击导航栏重试", showsProgress: false)
        } else if webView.isLoading {
            let percent = max(1, min(99, Int(webView.estimatedProgress * 100)))
            setStatus("加载中 \(percent)%", showsProgress: true)
        } else if lastRenderProbeWasBlank {
            setStatus("页面空白，点击恢复", showsProgress: false)
        } else {
            let location = Self.statusLocationText(for: webView.url)
            // The normal state must never display the WebView zoom as if it were
            // a loading percentage. Loading progress is shown only above while
            // WebKit is actually loading.
            let zoom = Int(round(currentZoom * 100))
            setStatus(location, showsProgress: false,
                      quiet: Self.canInjectPromptContent(into: webView.url) && zoom == 100)
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

    func setStatus(_ text: String, showsProgress: Bool, quiet: Bool = false) {
        if blockedNavigationStatus != nil, text != blockedNavigationStatus {
            clearBlockedNavigationStatus()
        }
        let progressPercent = showsProgress
            ? max(3, min(100, Int(round(webView.estimatedProgress * 100))))
            : 0
        if statusLabel != nil {
            guard text != lastPresentedStatusText
                    || showsProgress != lastPresentedStatusShowsProgress
                    || quiet != lastPresentedStatusIsQuiet
                    || progressPercent != lastPresentedProgressPercent else {
                return
            }
            lastPresentedStatusText = text
            lastPresentedStatusShowsProgress = showsProgress
            lastPresentedStatusIsQuiet = quiet
            lastPresentedProgressPercent = progressPercent
        }

        statusLabel?.stringValue = quiet ? "" : text
        statusLabel?.setAccessibilityLabel(text)
        statusContainer?.setAccessibilityLabel(text)
        toolbarItems[.chatGPTStatus]?.menuFormRepresentation?.title = text
        toolbarItems[.chatGPTStatus]?.toolTip = text
        if #available(macOS 15.0, *) {
            toolbarItems[.chatGPTStatus]?.isHidden = quiet
        }
        statusContainer?.isHidden = quiet
        for (index, constraint) in statusInsetConstraints.enumerated() {
            constraint.constant = quiet ? 0 : (index == 0 ? 1 : -1) * NativeToolbarMetrics.statusHorizontalPadding
        }
        progressIndicator?.isHidden = !showsProgress
        statusProgressWidthConstraint?.constant = showsProgress ? NativeToolbarMetrics.progressWidth : 0
        statusProgressLabelSpacingConstraint?.constant = showsProgress ? NativeToolbarMetrics.progressSpacing : 0
        let statusWidth = quiet ? 0 : Self.statusToolbarWidth(
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

    private func makeNavigationToolbarItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "导航"
        item.paletteLabel = "导航"
        item.toolTip = "后退、前进、重新加载"
        item.visibilityPriority = .high
        item.isNavigational = true

        // Three 28 pt targets, two 2 pt gaps, and breathing room before the window title.
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 104, height: 28))
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 104),
            stack.heightAnchor.constraint(equalToConstant: 28)
        ])
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityLabel("导航")

        func makeButton(_ label: String, _ symbol: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: "", target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.isBordered = true
            button.showsBorderOnlyWhileMouseInside = true
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28)
            ])
            return button
        }

        let back = makeButton("后退", "chevron.backward", #selector(goBack(_:)))
        let forward = makeButton("前进", "chevron.forward", #selector(goForward(_:)))
        let reload = makeButton("重新加载", "arrow.clockwise", #selector(reload(_:)))
        back.isEnabled = webView.canGoBack
        forward.isEnabled = webView.canGoForward
        navigationBackButton = back
        navigationForwardButton = forward
        navigationReloadButton = reload
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        reload.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: reload.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: reload.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16)
        ])
        navigationReloadSpinner = spinner
        stack.addArrangedSubview(back)
        stack.addArrangedSubview(forward)
        stack.addArrangedSubview(reload)
        let menu = NSMenu(title: "导航")
        menu.autoenablesItems = false
        for button in [back, forward, reload] {
            let entry = NSMenuItem(title: button.toolTip ?? "", action: button.action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = button.isEnabled
            menu.addItem(entry)
        }
        let menuItem = NSMenuItem(title: "导航", action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        item.menuFormRepresentation = menuItem
        item.view = stack
        toolbarItems[identifier] = item
        updateRefreshButtonAppearance()
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

        let label = NSTextField(labelWithString: "chatgpt.com")
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.setAccessibilityLabel("chatgpt.com")
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
        container.setAccessibilityLabel("chatgpt.com")
        container.addSubview(progress)
        container.addSubview(label)

        let widthConstraint = container.widthAnchor.constraint(equalToConstant: statusWidth)
        let progressWidthConstraint = progress.widthAnchor.constraint(equalToConstant: 0)
        let progressLabelSpacingConstraint = label.leadingAnchor.constraint(
            equalTo: progress.trailingAnchor,
            constant: 0
        )

        let leadingInset = progress.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: NativeToolbarMetrics.statusHorizontalPadding
            )
        let trailingInset = label.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -NativeToolbarMetrics.statusHorizontalPadding
            )
        statusInsetConstraints = [leadingInset, trailingInset]
        NSLayoutConstraint.activate([
            leadingInset,
            progress.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            progressWidthConstraint,

            progressLabelSpacingConstraint,
            trailingInset,
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            widthConstraint,
            container.heightAnchor.constraint(equalToConstant: NativeToolbarMetrics.statusHeight)
        ])

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "状态"
        item.paletteLabel = "状态"
        item.toolTip = label.stringValue
        item.view = container
        let menuItem = NSMenuItem(title: label.stringValue, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        item.menuFormRepresentation = menuItem
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
        return min(preferredWidth, showsProgress ? NativeToolbarMetrics.progressStatusMaxWidth : NativeToolbarMetrics.statusMaxWidth)
    }
}
