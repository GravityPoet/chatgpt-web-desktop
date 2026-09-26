import AppKit
import ChatGPTSwiftWebCore

extension BrowserWindowController {
    func showToast(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil, duration: TimeInterval = 5) {
        guard !isDisposing else { return }
        toastView.show(message: message, actionTitle: actionTitle, action: action, duration: duration)
    }

    @objc func showDownloads(_ sender: Any?) {
        if downloadWindowController == nil {
            downloadWindowController = DownloadCenterWindowController(center: .shared, profileID: downloadScope)
            downloadWindowController?.window?.center()
        }
        downloadWindowController?.render()
        downloadWindowController?.showWindow(sender)
        downloadWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    func observeUtilityState() {
        utilityObservers.append(NotificationCenter.default.addObserver(forName: .chatGPTSwiftDownloadCenterDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDownloadButton() }
        })
        utilityObservers.append(NotificationCenter.default.addObserver(forName: .chatGPTSwiftNetworkDidChange, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                self?.networkChanged(restored: note.userInfo?["restored"] as? Bool == true)
            }
        })
        updateDownloadButton()
        updateProfileButton()
    }

    func stopUtilityObservers() {
        utilityObservers.forEach(NotificationCenter.default.removeObserver)
        utilityObservers.removeAll()
        downloadWindowController?.close()
        downloadWindowController = nil
    }

    func updateDownloadButton() {
        let records = DownloadCenter.shared.records.filter { $0.profileID == downloadScope }
        let active = records.filter { $0.state == .downloading }
        let fractions = active.compactMap(\.progress)
        let percent = fractions.isEmpty ? "" : " · \(Int(fractions.reduce(0, +) / Double(fractions.count) * 100))%"
        // Compact: icon-only when idle-empty, short count otherwise. Never a persistent
        // long "下载 0" title that squeezes the toolbar at narrow widths.
        let title: String
        let accessibility: String
        let toolTip: String
        if !active.isEmpty {
            title = active.count > 99 ? "99+" : "\(active.count)"
            accessibility = "下载中心，\(active.count) 项正在下载\(percent)"
            toolTip = "打开下载中心（\(active.count) 项正在下载\(percent)）"
        } else if !records.isEmpty {
            title = "\(records.count)"
            accessibility = "下载中心，\(records.count) 项记录"
            toolTip = "打开下载中心（\(records.count) 项记录）"
        } else {
            title = ""
            accessibility = "下载中心，无记录"
            toolTip = "打开下载中心"
        }
        downloadButton?.title = title
        downloadButton?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        downloadButton?.setAccessibilityLabel(accessibility)
        downloadButton?.toolTip = toolTip
        toolbarItems[.chatGPTDownloads]?.label = "下载中心"
        toolbarItems[.chatGPTDownloads]?.toolTip = toolTip
        toolbarItems[.chatGPTDownloads]?.menuFormRepresentation?.title = toolTip
    }

    func updateProfileButton() {
        let currentID = profileID ?? defaultProfileID
        let name = ProfileStore.loadProfiles().first(where: { $0.id == currentID })?.name
            ?? (currentID == defaultProfileID ? "默认" : "账号空间")
        // Compact icon/dot: full space name lives in tooltip/AX/menu, never as a
        // persistent long toolbar title.
        profileButton?.title = ""
        profileButton?.imagePosition = .imageOnly
        profileButton?.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "账号空间")
        let toolTip = "账号空间：\(name) — 点击切换"
        let accessibility = "账号空间，当前\(name)，点击切换账号空间"
        profileButton?.toolTip = toolTip
        profileButton?.setAccessibilityLabel(accessibility)
        toolbarItems[.chatGPTProfile]?.label = "账号空间"
        toolbarItems[.chatGPTProfile]?.paletteLabel = "账号空间"
        toolbarItems[.chatGPTProfile]?.toolTip = toolTip
        toolbarItems[.chatGPTProfile]?.menuFormRepresentation?.title = toolTip
    }

    func networkChanged(restored: Bool) {
        guard !isDisposing else { return }
        if NetworkStatusMonitor.shared.availability == .offline {
            networkRetryUsed = false
            if hasFailedNavigation { networkRetryPending = true }
        }
        if restored, networkRetryPending, !networkRetryUsed, hasFailedNavigation,
           !isAssistantResponseInProgress, ProfileStore.pendingDataMutation == nil {
            networkRetryUsed = true
            networkRetryPending = false
            showToast("网络已恢复，正在重新加载")
            hardReload()
        }
        updateNativeChromeStatus()
    }

    @objc func showProfileSwitcher(_ sender: Any?) {
        guard persistent else { showToast("无痕窗口使用独立的临时空间"); return }
        let menu = NSMenu(title: "账号空间")
        let currentID = profileID ?? defaultProfileID
        let startupID = ProfileStore.startupProfileID()
        for profile in ProfileStore.loadProfiles() {
            let badges = [profile.id == currentID ? "当前" : nil, profile.id == startupID ? "启动默认" : nil].compactMap { $0 }
            let item = NSMenuItem(title: profile.name + (badges.isEmpty ? "" : "（\(badges.joined(separator: "、"))）"),
                                 action: #selector(AppDelegate.switchToProfile(_:)), keyEquivalent: "")
            item.target = NSApp.delegate
            item.representedObject = profile.id
            item.state = profile.id == currentID ? .on : .off
            item.image = Self.profileColorImage(id: profile.id)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "账号空间管理在“文件”菜单中", action: nil, keyEquivalent: "")
        manage.isEnabled = false
        menu.addItem(manage)
        if let button = profileButton, button.window != nil {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            // Overflow items have no visible button to anchor to.
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    static func profileColorImage(id: String) -> NSImage {
        let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        let index = id.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            colors[index].setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}
