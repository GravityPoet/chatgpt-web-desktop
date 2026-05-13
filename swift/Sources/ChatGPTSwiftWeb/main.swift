import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import WebKit

private let chatGPTURL = URL(string: "https://chatgpt.com/")!
private let appBundleIdentifier = "local.chatgpt-web.swift"
private let mainFrameDefaultsKey = "ChatGPTSwiftWeb.MainWindowFrame"
private let webZoomDefaultsKey = "ChatGPTSwiftWeb.WebViewZoom"
private let minimumWebZoom: CGFloat = 0.85
private let maximumWebZoom: CGFloat = 1.40
private let webZoomStep: CGFloat = 0.05
private let maximumCookieImportBytes = 2 * 1024 * 1024
private let cookieImportErrorDomain = "ChatGPTSwiftWeb.CookieImport"
private let profilesDefaultsKey = "ChatGPTSwiftWeb.Profiles"
private let currentProfileDefaultsKey = "ChatGPTSwiftWeb.CurrentProfileID"
private let defaultProfileID = "default"
private let profileHomepageDefaultsPrefix = "ChatGPTSwiftWeb.ProfileHomepage."
private let profileFingerprintDefaultsPrefix = "ChatGPTSwiftWeb.ProfileFingerprint."
private let profileEnhancedPrivacyDefaultsPrefix = "ChatGPTSwiftWeb.ProfileEnhancedPrivacy."
private let webRTCProtectionDefaultsKey = "ChatGPTSwiftWeb.WebRTCProtectionEnabled"
private var singleInstanceLockFileDescriptor: CInt = -1

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var mainController: BrowserWindowController?
    private var incognitoControllers: [BrowserWindowController] = []
    private var keyMonitor: Any?
    private var profilesMenu: NSMenu?
    private var webRTCProtectionItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        installKeyboardZoomShortcuts()
        let needsIsolationFallbackNotice = reconcileProfileIsolationOnLaunch()

        let profile = ProfileStore.currentProfile()
        let controller = BrowserWindowController(
            initialURL: ProfileStore.homepageURL(for: profile.id),
            title: mainWindowTitle(for: profile),
            isPopup: false,
            persistent: true,
            profileID: profile.id
        )
        mainController = controller
        controller.show()
        NSApp.activate(ignoringOtherApps: true)

        if needsIsolationFallbackNotice {
            DispatchQueue.main.async { [weak self] in
                self?.presentIsolationFallbackNotice()
            }
        }
    }

    private func reconcileProfileIsolationOnLaunch() -> Bool {
        if #available(macOS 14.0, *) {
            return false
        }
        let currentID = ProfileStore.currentProfileID()
        guard currentID != defaultProfileID else {
            return false
        }
        ProfileStore.setCurrentProfileID(defaultProfileID)
        return true
    }

    private func presentIsolationFallbackNotice() {
        let alert = NSAlert()
        alert.messageText = "已回退到默认账号空间"
        alert.informativeText = "多账号隔离需要 macOS 14 或更新版本。当前系统版本不支持隔离，已自动切回默认空间，避免不同空间共享同一份本地数据。\n\n要使用独立账号空间，请升级到 macOS 14 或更新版本。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainController?.show()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainController?.persistMainWindowFrame()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 ChatGPT Swift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 ChatGPT Swift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let importCookiesItem = fileMenu.addItem(withTitle: "导入 Cookies...", action: #selector(importCookiesMenu(_:)), keyEquivalent: "")
        importCookiesItem.target = self
        let exportCookiesItem = fileMenu.addItem(withTitle: "导出 Cookies...", action: #selector(exportCookiesMenu(_:)), keyEquivalent: "")
        exportCookiesItem.target = self
        let clearWebsiteDataItem = fileMenu.addItem(withTitle: "清空当前账号空间网站数据...", action: #selector(clearChatGPTWebsiteData(_:)), keyEquivalent: "")
        clearWebsiteDataItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        let goToURLItem = fileMenu.addItem(withTitle: "前往网址...", action: #selector(goToURLAction(_:)), keyEquivalent: "l")
        goToURLItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        let profilesItem = fileMenu.addItem(withTitle: "账号空间", action: nil, keyEquivalent: "")
        let profilesSubmenu = NSMenu(title: "账号空间")
        profilesSubmenu.delegate = self
        profilesSubmenu.autoenablesItems = false
        profilesItem.submenu = profilesSubmenu
        profilesMenu = profilesSubmenu
        let incognitoItem = fileMenu.addItem(withTitle: "新建无痕窗口", action: #selector(openIncognitoWindow(_:)), keyEquivalent: "n")
        incognitoItem.keyEquivalentModifierMask = [.command, .shift]
        incognitoItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        viewMenu.addItem(withTitle: "重新加载", action: #selector(BrowserWindowController.reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "放大", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "缩小", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "实际大小", action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let privacyItem = NSMenuItem()
        let privacyMenu = NSMenu(title: "隐私")
        let webRTCItem = privacyMenu.addItem(withTitle: "启用 WebRTC 防护", action: #selector(toggleWebRTCProtection(_:)), keyEquivalent: "")
        webRTCItem.target = self
        webRTCProtectionItem = webRTCItem
        updateWebRTCProtectionMenuItem()
        privacyMenu.addItem(NSMenuItem.separator())
        let privacyStatusItem = privacyMenu.addItem(withTitle: "隐私状态...", action: #selector(showPrivacyStatus(_:)), keyEquivalent: "")
        privacyStatusItem.target = self
        let fingerprintTestItem = privacyMenu.addItem(withTitle: "打开指纹检测页", action: #selector(openFingerprintTestPage(_:)), keyEquivalent: "")
        fingerprintTestItem.target = self
        privacyItem.submenu = privacyMenu
        mainMenu.addItem(privacyItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func installKeyboardZoomShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.isCommandOnlyShortcut(event) else {
                return event
            }

            guard let controller = BrowserWindowController.keyWindowController() else {
                return event
            }

            switch event.charactersIgnoringModifiers {
            case "=", "+":
                controller.zoomIn(nil)
                return nil
            case "-":
                controller.zoomOut(nil)
                return nil
            case "0":
                controller.resetZoom(nil)
                return nil
            default:
                return event
            }
        }
    }

    private static func isCommandOnlyShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
            && !flags.contains(.control)
            && !flags.contains(.option)
    }

    @objc private func importCookiesMenu(_ sender: Any?) {
        mainController?.importCookiesFromPanel()
    }

    @objc private func exportCookiesMenu(_ sender: Any?) {
        mainController?.exportCookiesViaPanel()
    }

    @objc private func clearChatGPTWebsiteData(_ sender: Any?) {
        mainController?.confirmClearWebsiteData()
    }

    @objc private func toggleWebRTCProtection(_ sender: Any?) {
        let enabled = !PrivacySettings.isWebRTCProtectionRequested()
        PrivacySettings.setWebRTCProtectionEnabled(enabled)
        updateWebRTCProtectionMenuItem()

        let currentURL = mainController?.currentURL()
        rebuildMainController(initialURL: currentURL)
    }

    @objc private func showPrivacyStatus(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        let fingerprint = ProfileStore.fingerprint(for: profile.id)
        let fingerprintText = fingerprint?.displayName ?? "默认 Safari（不混淆）"
        let enhancedPrivacyText = ProfileStore.isEnhancedPrivacyEnabled(for: profile.id) ? "开启" : "关闭"
        let webRTCText = PrivacySettings.isWebRTCProtectionEnabled(profileID: profile.id)
            ? (fingerprint == nil ? "开启" : "开启（当前指纹预设强制）")
            : "关闭"
        let isolation: String
        if #available(macOS 14.0, *) {
            isolation = profile.id == defaultProfileID ? "默认空间使用本 App 默认 WebView 数据仓库" : "当前空间使用独立 WKWebsiteDataStore"
        } else {
            isolation = "当前系统不支持多账号持久数据仓库隔离"
        }

        let alert = NSAlert()
        alert.messageText = "隐私状态"
        alert.informativeText = """
        当前空间：\(profile.name)
        数据隔离：\(isolation)
        指纹预设：\(fingerprintText)
        增强隐私模式：\(enhancedPrivacyText)
        WebRTC 防护：\(webRTCText)
        GPC：JS 信号开启；主导航请求头 Sec-GPC 开启
        URL 追踪参数清理：开启，仅处理顶层导航
        Referrer 控制：开启，跨站顶层导航最多保留来源站点 origin
        Accept-Language：仅 JS 层覆盖；HTTP Accept-Language 仍由 WKWebView / 系统决定
        Tracker blocking：未启用
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func openFingerprintTestPage(_ sender: Any?) {
        mainController?.loadFingerprintTestPage()
    }

    @objc private func goToURLAction(_ sender: Any?) {
        guard let controller = mainController else {
            return
        }
        let initial = controller.currentURL()?.absoluteString ?? ""
        promptForURL(
            title: "前往网址",
            message: "输入 https:// 开头的网址。该网址将在当前账号空间内加载，cookie 和登录态与其他空间相互隔离。",
            initial: initial
        ) { [weak self] url in
            guard let url else {
                return
            }
            self?.mainController?.navigate(to: url)
        }
    }

    @objc private func setProfileHomepageAction(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        let initial = UserDefaults.standard.string(forKey: profileHomepageDefaultsPrefix + profile.id) ?? ""
        promptForURL(
            title: "设置空间 \"\(profile.name)\" 的首页",
            message: "下次启动或切换到本空间时将自动加载该网址。仅支持 https://。留空可以保持当前设置。",
            initial: initial
        ) { [weak self] url in
            guard let self, let url else {
                return
            }
            ProfileStore.setHomepage(url, for: profile.id)
            self.mainController?.navigate(to: url)
        }
    }

    @objc private func resetProfileHomepageAction(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        ProfileStore.removeHomepage(for: profile.id)
    }

    @objc private func openIncognitoWindow(_ sender: Any?) {
        let controller = BrowserWindowController(
            initialURL: chatGPTURL,
            title: "ChatGPT Swift · 无痕",
            isPopup: true,
            persistent: false,
            profileID: nil,
            closeHandler: { [weak self] in
                self?.incognitoControllers.removeAll { $0.window.isVisible == false }
            }
        )
        incognitoControllers.append(controller)
        controller.show()
    }

    @objc private func switchToProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        if id == ProfileStore.currentProfileID() {
            return
        }
        ProfileStore.setCurrentProfileID(id)
        updateWebRTCProtectionMenuItem()
        rebuildMainController()
    }

    @objc private func selectFingerprintPreset(_ sender: NSMenuItem) {
        guard let presetID = sender.representedObject as? String else {
            return
        }
        let profileID = ProfileStore.currentProfileID()
        if presetID == FingerprintCatalog.offPresetID {
            ProfileStore.setFingerprint(nil, for: profileID)
        } else if let preset = FingerprintCatalog.preset(for: presetID) {
            ProfileStore.setFingerprint(preset, for: profileID)
        }
        updateWebRTCProtectionMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
    }

    @objc private func randomizeCurrentFingerprint(_ sender: Any?) {
        let profileID = ProfileStore.currentProfileID()
        ProfileStore.setFingerprint(FingerprintCatalog.randomProfile(), for: profileID)
        updateWebRTCProtectionMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
    }

    @objc private func toggleEnhancedPrivacy(_ sender: Any?) {
        let profileID = ProfileStore.currentProfileID()
        let enabled = !ProfileStore.isEnhancedPrivacyEnabled(for: profileID)
        ProfileStore.setEnhancedPrivacyEnabled(enabled, for: profileID)
        rebuildMainController(initialURL: mainController?.currentURL())
    }

    @objc private func cloneCurrentProfileAction(_ sender: Any?) {
        guard ensureIsolationAvailable() else {
            return
        }
        let source = ProfileStore.currentProfile()
        let defaultName = "\(source.name) 副本"

        let alert = NSAlert()
        alert.messageText = "克隆当前空间"
        alert.informativeText = "会复制首页和增强隐私设置，并自动为新空间生成稳定随机指纹。默认不复制 cookies，可按需勾选。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "克隆")
        alert.addButton(withTitle: "取消")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = uniqueProfileName(defaultName)
        textField.placeholderString = "新空间名称"
        stack.addArrangedSubview(textField)

        let copyCookiesButton = NSButton(checkboxWithTitle: "同时复制 cookies", target: nil, action: nil)
        copyCookiesButton.state = .off
        stack.addArrangedSubview(copyCookiesButton)

        alert.accessoryView = stack
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }
        guard !Self.profileNameExists(name, in: ProfileStore.loadProfiles(), excluding: nil) else {
            presentDuplicateNameAlert(name: name)
            return
        }

        createProfileFromCurrent(named: name, copyCookies: copyCookiesButton.state == .on)
    }

    @objc private func exportCurrentProfileAction(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        let panel = NSSavePanel()
        panel.title = "Export Profile"
        panel.message = "导出当前空间配置：名称、首页、指纹预设和增强隐私设置。不会导出 cookies 或网站数据。"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name)-profile.json"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.exportCurrentProfile(to: url)
        }
    }

    @objc private func importProfileAction(_ sender: Any?) {
        guard ensureIsolationAvailable() else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import Profile"
        panel.message = "选择之前导出的 profile JSON。导入会创建一个新的账号空间，不会覆盖现有空间。"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.importProfile(from: url)
        }
    }

    @objc private func showFingerprintAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "指纹混淆能挡什么，不能挡什么"
        alert.informativeText = """
        能挡：UA、屏幕、硬件信息、触控信息、时区这类简单 hash 拼出的设备 ID。

        挡不住：
        - TLS 指纹（JA3 / JA4）：WKWebView 使用系统网络栈，App 无法逐站点修改。
        - HTTP/2 帧顺序、ClientHints 缺失：仍会暴露 WebKit 引擎特征。
        - Canvas / WebGL / AudioContext 像素级指纹：本期不做噪声注入。
        - IP 地址：同一出口 IP 仍可能把不同账号关联到同一网络环境。

        HTTP Accept-Language 没有公开的 WKWebView per-profile API，本期只覆盖 JS 层 navigator.language / navigator.languages。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func addProfileAction(_ sender: Any?) {
        guard ensureIsolationAvailable() else {
            return
        }
        promptForName(title: "新建账号空间", initial: "") { [weak self] name in
            guard let self, let name else {
                return
            }
            var profiles = ProfileStore.loadProfiles()
            if Self.profileNameExists(name, in: profiles, excluding: nil) {
                self.presentDuplicateNameAlert(name: name)
                return
            }
            let profile = WebProfile(id: UUID().uuidString, name: name, createdAt: Date())
            profiles.append(profile)
            ProfileStore.save(profiles)
            ProfileStore.setCurrentProfileID(profile.id)
            self.rebuildMainController()
        }
    }

    @objc private func renameCurrentProfileAction(_ sender: Any?) {
        let currentID = ProfileStore.currentProfileID()
        guard currentID != defaultProfileID else {
            return
        }
        var profiles = ProfileStore.loadProfiles()
        guard let idx = profiles.firstIndex(where: { $0.id == currentID }) else {
            return
        }
        promptForName(title: "重命名当前空间", initial: profiles[idx].name) { [weak self] name in
            guard let self, let name else {
                return
            }
            if Self.profileNameExists(name, in: profiles, excluding: currentID) {
                self.presentDuplicateNameAlert(name: name)
                return
            }
            profiles[idx].name = name
            ProfileStore.save(profiles)
            self.mainController?.window.title = self.mainWindowTitle(for: profiles[idx])
        }
    }

    private static func profileNameExists(_ name: String, in profiles: [WebProfile], excluding excludedID: String?) -> Bool {
        let normalized = name.lowercased()
        return profiles.contains { profile in
            profile.id != excludedID && profile.name.lowercased() == normalized
        }
    }

    private func presentDuplicateNameAlert(name: String) {
        let alert = NSAlert()
        alert.messageText = "已存在同名账号空间"
        alert.informativeText = "已经有一个名为「\(name)」的账号空间。请换一个名字。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func deleteCurrentProfileAction(_ sender: Any?) {
        let currentID = ProfileStore.currentProfileID()
        guard currentID != defaultProfileID else {
            return
        }
        var profiles = ProfileStore.loadProfiles()
        guard let idx = profiles.firstIndex(where: { $0.id == currentID }) else {
            return
        }
        let profile = profiles[idx]
        let alert = NSAlert()
        alert.messageText = "删除账号空间 \"\(profile.name)\"？"
        alert.informativeText = "本空间的所有 cookie、登录态、缓存与本地存储将被永久删除。其他空间不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        profiles.remove(at: idx)
        ProfileStore.save(profiles)
        ProfileStore.removeHomepage(for: profile.id)
        ProfileStore.setFingerprint(nil, for: profile.id)
        ProfileStore.setEnhancedPrivacyEnabled(false, for: profile.id)
        ProfileStore.setCurrentProfileID(defaultProfileID)
        rebuildMainController()
        if #available(macOS 14.0, *), let uuid = UUID(uuidString: profile.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === profilesMenu else {
            return
        }
        rebuildProfilesMenu(menu)
    }

    private func rebuildProfilesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let isolationAvailable: Bool
        if #available(macOS 14.0, *) {
            isolationAvailable = true
        } else {
            isolationAvailable = false
        }

        let currentID = ProfileStore.currentProfileID()
        for profile in ProfileStore.loadProfiles() {
            let item = menu.addItem(withTitle: profile.name, action: #selector(switchToProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == currentID ? .on : .off
            item.isEnabled = isolationAvailable || profile.id == defaultProfileID
        }
        menu.addItem(NSMenuItem.separator())
        let fingerprintItem = menu.addItem(withTitle: "指纹预设", action: nil, keyEquivalent: "")
        let fingerprintMenu = NSMenu(title: "指纹预设")
        rebuildFingerprintMenu(fingerprintMenu, profileID: currentID)
        fingerprintItem.submenu = fingerprintMenu
        let enhancedItem = menu.addItem(withTitle: "增强隐私模式（当前空间）", action: #selector(toggleEnhancedPrivacy(_:)), keyEquivalent: "")
        enhancedItem.target = self
        enhancedItem.state = ProfileStore.isEnhancedPrivacyEnabled(for: currentID) ? .on : .off
        let testItem = menu.addItem(withTitle: "打开指纹检测页", action: #selector(openFingerprintTestPage(_:)), keyEquivalent: "")
        testItem.target = self
        menu.addItem(NSMenuItem.separator())
        let setHomeItem = menu.addItem(withTitle: "设置当前空间首页…", action: #selector(setProfileHomepageAction(_:)), keyEquivalent: "")
        setHomeItem.target = self
        let resetHomeItem = menu.addItem(withTitle: "清除当前空间首页", action: #selector(resetProfileHomepageAction(_:)), keyEquivalent: "")
        resetHomeItem.target = self
        let hasHomepage = UserDefaults.standard.string(forKey: profileHomepageDefaultsPrefix + currentID) != nil
        resetHomeItem.isEnabled = hasHomepage
        menu.addItem(NSMenuItem.separator())
        let addItem = menu.addItem(withTitle: "新建账号空间…", action: #selector(addProfileAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = isolationAvailable
        let cloneItem = menu.addItem(withTitle: "克隆当前空间…", action: #selector(cloneCurrentProfileAction(_:)), keyEquivalent: "")
        cloneItem.target = self
        cloneItem.isEnabled = isolationAvailable
        let exportItem = menu.addItem(withTitle: "导出当前空间配置…", action: #selector(exportCurrentProfileAction(_:)), keyEquivalent: "")
        exportItem.target = self
        let importItem = menu.addItem(withTitle: "导入空间配置…", action: #selector(importProfileAction(_:)), keyEquivalent: "")
        importItem.target = self
        importItem.isEnabled = isolationAvailable
        let renameItem = menu.addItem(withTitle: "重命名当前空间…", action: #selector(renameCurrentProfileAction(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.isEnabled = isolationAvailable && currentID != defaultProfileID
        let deleteItem = menu.addItem(withTitle: "删除当前空间…", action: #selector(deleteCurrentProfileAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = isolationAvailable && currentID != defaultProfileID

        if !isolationAvailable {
            menu.addItem(NSMenuItem.separator())
            let hint = menu.addItem(withTitle: "账号空间隔离需要 macOS 14 或更新版本", action: nil, keyEquivalent: "")
            hint.isEnabled = false
        }
    }

    private func rebuildFingerprintMenu(_ menu: NSMenu, profileID: String) {
        menu.removeAllItems()
        let currentFingerprint = ProfileStore.fingerprint(for: profileID)
        let currentPresetID = currentFingerprint?.presetID ?? FingerprintCatalog.offPresetID

        let offTitle = currentPresetID == FingerprintCatalog.offPresetID
            ? "● 默认 Safari（不混淆）"
            : "  默认 Safari（不混淆）"
        let offItem = menu.addItem(withTitle: offTitle, action: #selector(selectFingerprintPreset(_:)), keyEquivalent: "")
        offItem.target = self
        offItem.representedObject = FingerprintCatalog.offPresetID

        for preset in FingerprintCatalog.presets {
            let isSelected = preset.presetID == currentPresetID
            let item = menu.addItem(withTitle: "\(isSelected ? "●" : " ") \(preset.displayName)", action: #selector(selectFingerprintPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.presetID
        }

        if let currentFingerprint, currentFingerprint.presetID.hasPrefix("random-") {
            menu.addItem(NSMenuItem.separator())
            let randomItem = menu.addItem(withTitle: "● \(currentFingerprint.displayName)", action: nil, keyEquivalent: "")
            randomItem.isEnabled = false
        }

        menu.addItem(NSMenuItem.separator())
        let randomizeItem = menu.addItem(withTitle: "重新随机化（当前空间）", action: #selector(randomizeCurrentFingerprint(_:)), keyEquivalent: "")
        randomizeItem.target = self
        menu.addItem(NSMenuItem.separator())
        let aboutItem = menu.addItem(withTitle: "关于指纹混淆…", action: #selector(showFingerprintAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
    }

    private func rebuildMainController(initialURL: URL? = nil) {
        let oldController = mainController
        mainController = nil
        oldController?.dispose()

        let profile = ProfileStore.currentProfile()
        let controller = BrowserWindowController(
            initialURL: initialURL ?? ProfileStore.homepageURL(for: profile.id),
            title: mainWindowTitle(for: profile),
            isPopup: false,
            persistent: true,
            profileID: profile.id
        )
        mainController = controller
        controller.show()
        updateWebRTCProtectionMenuItem()
    }

    private func mainWindowTitle(for profile: WebProfile) -> String {
        profile.id == defaultProfileID ? "ChatGPT Swift" : "ChatGPT Swift · \(profile.name)"
    }

    private func ensureIsolationAvailable() -> Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "无法新建账号空间"
        alert.informativeText = "多账号隔离需要 macOS 14 或更新版本。当前系统版本只支持默认空间和无痕窗口。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
        return false
    }

    private func updateWebRTCProtectionMenuItem() {
        let profileID = ProfileStore.currentProfileID()
        let forced = ProfileStore.fingerprint(for: profileID) != nil
        webRTCProtectionItem?.title = forced ? "启用 WebRTC 防护（当前指纹强制开启）" : "启用 WebRTC 防护"
        webRTCProtectionItem?.state = PrivacySettings.isWebRTCProtectionEnabled(profileID: profileID) ? .on : .off
    }

    private func createProfileFromCurrent(named name: String, copyCookies: Bool) {
        let sourceID = ProfileStore.currentProfileID()
        let newProfile = WebProfile(id: UUID().uuidString, name: name, createdAt: Date())
        var profiles = ProfileStore.loadProfiles()
        profiles.append(newProfile)
        ProfileStore.save(profiles)

        if let homepage = ProfileStore.homepageString(for: sourceID),
           let url = URL(string: homepage) {
            ProfileStore.setHomepage(url, for: newProfile.id)
        }
        ProfileStore.setFingerprint(FingerprintCatalog.randomProfile(), for: newProfile.id)
        ProfileStore.setEnhancedPrivacyEnabled(ProfileStore.isEnhancedPrivacyEnabled(for: sourceID), for: newProfile.id)

        let switchToNewProfile = { [weak self] in
            ProfileStore.setCurrentProfileID(newProfile.id)
            self?.updateWebRTCProtectionMenuItem()
            self?.rebuildMainController()
        }

        guard copyCookies, let controller = mainController else {
            switchToNewProfile()
            return
        }

        controller.copyCookies(toProfileID: newProfile.id) { [weak self] count in
            switchToNewProfile()
            self?.presentInfo("已克隆空间「\(name)」，并复制 \(count) 个 cookie。")
        }
    }

    private func exportCurrentProfile(to url: URL) {
        let profile = ProfileStore.currentProfile()
        let document = ProfileExportDocument(
            schemaVersion: 1,
            exportedAt: Date(),
            sourceProfileID: profile.id,
            name: profile.name,
            homepage: ProfileStore.homepageString(for: profile.id),
            fingerprint: ProfileStore.fingerprint(for: profile.id),
            enhancedPrivacyEnabled: ProfileStore.isEnhancedPrivacyEnabled(for: profile.id)
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
            presentInfo("已导出当前空间配置到 \(url.lastPathComponent)。")
        } catch {
            presentError("Profile 导出失败：\(error.localizedDescription)")
        }
    }

    private func importProfile(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(ProfileExportDocument.self, from: data)
            guard document.schemaVersion == 1 else {
                presentError("Profile JSON 版本不支持。")
                return
            }

            let name = uniqueProfileName(document.name.isEmpty ? "导入空间" : document.name)
            let profile = WebProfile(id: UUID().uuidString, name: name, createdAt: Date())
            var profiles = ProfileStore.loadProfiles()
            profiles.append(profile)
            ProfileStore.save(profiles)

            if let homepage = document.homepage,
               let url = URL(string: homepage),
               url.scheme?.lowercased() == "https" {
                ProfileStore.setHomepage(url, for: profile.id)
            }
            ProfileStore.setFingerprint(document.fingerprint, for: profile.id)
            ProfileStore.setEnhancedPrivacyEnabled(document.enhancedPrivacyEnabled, for: profile.id)
            ProfileStore.setCurrentProfileID(profile.id)
            updateWebRTCProtectionMenuItem()
            rebuildMainController()
            presentInfo("已导入空间配置「\(name)」。")
        } catch {
            presentError("Profile 导入失败：\(error.localizedDescription)")
        }
    }

    private func uniqueProfileName(_ baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "新空间" : trimmed
        let profiles = ProfileStore.loadProfiles()
        if !Self.profileNameExists(base, in: profiles, excluding: nil) {
            return base
        }

        var index = 2
        while true {
            let candidate = "\(base) \(index)"
            if !Self.profileNameExists(candidate, in: profiles, excluding: nil) {
                return candidate
            }
            index += 1
        }
    }

    private func presentError(_ text: String) {
        presentAlert(text, style: .warning)
    }

    private func presentInfo(_ text: String) {
        presentAlert(text, style: .informational)
    }

    private func presentAlert(_ text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = "ChatGPT Swift"
        alert.informativeText = text
        alert.alertStyle = style
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func promptForURL(title: String, message: String, initial: String, completion: @escaping (URL?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往")
        alert.addButton(withTitle: "取消")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        textField.stringValue = initial
        textField.placeholderString = "https://example.com"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard response == .alertFirstButtonReturn, !trimmed.isEmpty else {
            completion(nil)
            return
        }
        guard let url = Self.validatedExternalURL(trimmed) else {
            let warn = NSAlert()
            warn.messageText = "网址无效"
            warn.informativeText = "请输入完整的 https:// 网址，例如 https://example.com。仅支持 https，明文 http 已拒绝。"
            warn.alertStyle = .warning
            warn.addButton(withTitle: "知道了")
            warn.runModal()
            completion(nil)
            return
        }
        completion(url)
    }

    private static func validatedExternalURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") {
            return nil
        }
        let candidate: String
        if lower.hasPrefix("https://") {
            candidate = trimmed
        } else if lower.contains("://") {
            return nil
        } else {
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              host.contains(".") else {
            return nil
        }
        return url
    }

    private func promptForName(title: String, initial: String, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = initial
        textField.placeholderString = "例如：工作号 / 私人号"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        let trimmed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if response == .alertFirstButtonReturn, !trimmed.isEmpty {
            completion(trimmed)
        } else {
            completion(nil)
        }
    }
}

final class BrowserWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private static var controllers: [BrowserWindowController] = []

    private(set) var window: NSWindow!
    private(set) var webView: WKWebView!
    private var childControllers: [BrowserWindowController] = []
    private let isPopup: Bool
    private let persistent: Bool
    private let profileID: String?
    private var closeHandler: (() -> Void)?
    private var currentZoom: CGFloat = BrowserWindowController.savedWebZoom()

    init(
        initialURL: URL?,
        title: String,
        isPopup: Bool,
        persistent: Bool = true,
        profileID: String? = nil,
        configuration: WKWebViewConfiguration? = nil,
        closeHandler: (() -> Void)? = nil
    ) {
        self.isPopup = isPopup
        self.persistent = persistent
        self.profileID = profileID
        self.closeHandler = closeHandler
        super.init()
        Self.controllers.append(self)

        let webConfiguration = configuration ?? Self.makeConfiguration(messageHandler: self, persistent: persistent, profileID: profileID)

        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        if let fingerprint = ProfileStore.fingerprint(for: profileID) {
            webView.customUserAgent = fingerprint.userAgent
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = false
        webView.pageZoom = currentZoom

        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let defaultRect = isPopup
            ? NSRect(x: 120, y: 120, width: 1100, height: 780)
            : NSRect(x: 80, y: 80, width: 1280, height: 900)
        let restoredFrame = isPopup ? nil : Self.restoredMainWindowFrame()
        window = NSWindow(contentRect: restoredFrame ?? defaultRect, styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.delegate = self
        window.contentView = webView
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 640)
        window.tabbingMode = .disallowed
        if isPopup || restoredFrame == nil {
            window.center()
        }

        webView.autoresizingMask = [.width, .height]

        if let initialURL {
            webView.load(Self.privacyRequest(for: initialURL, sourceURL: nil))
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func reload(_ sender: Any?) {
        webView.reload()
    }

    func navigate(to url: URL) {
        webView.load(Self.privacyRequest(for: url, sourceURL: webView.url))
    }

    func currentURL() -> URL? {
        webView.url
    }

    func loadFingerprintTestPage() {
        webView.loadHTMLString(Self.fingerprintTestHTML, baseURL: nil)
    }

    func copyCookies(toProfileID targetProfileID: String, completion: @escaping (Int) -> Void) {
        let sourceStore = webView.configuration.websiteDataStore.httpCookieStore
        let targetStore = Self.resolveDataStore(persistent: true, profileID: targetProfileID).httpCookieStore

        sourceStore.getAllCookies { cookies in
            guard !cookies.isEmpty else {
                DispatchQueue.main.async {
                    completion(0)
                }
                return
            }

            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                targetStore.setCookie(cookie) {
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                completion(cookies.count)
            }
        }
    }

    func importCookiesFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Cookies"
        panel.message = "选择从浏览器导出的 cookie JSON 文件。将导入到当前账号空间。"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }

            self?.importCookies(from: url)
        }
    }

    func exportCookiesViaPanel() {
        let panel = NSSavePanel()
        panel.title = "Export Cookies"
        panel.message = "导出当前账号空间内所有 cookie 到 JSON 文件。"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = Self.suggestedExportFilename()

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }

            self?.exportCookies(to: url)
        }
    }

    private func exportCookies(to url: URL) {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else {
                return
            }

            guard !cookies.isEmpty else {
                self.presentError("当前账号空间内没有可导出的 cookie。")
                return
            }

            let exported = cookies.map { ExportedBrowserCookie(cookie: $0) }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(exported)
                try data.write(to: url, options: [.atomic])
                self.presentInfo("已导出 \(cookies.count) 个 cookie 到 \(url.lastPathComponent)。")
            } catch {
                self.presentError("Cookie 导出失败：\(error.localizedDescription)")
            }
        }
    }

    private static func suggestedExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "cookies-\(formatter.string(from: Date())).json"
    }

    func confirmClearWebsiteData() {
        let alert = NSAlert()
        alert.messageText = "清空当前账号空间网站数据？"
        alert.informativeText = "这会删除当前账号空间在本 App WebView 内**所有站点**的 cookie、登录态、缓存、localStorage、IndexedDB、Service Worker 等数据，并重新加载首页。不会影响其他账号空间，也不会删除 Chrome/Safari 数据或服务器上的账号资料。\n\n注意：本操作无法阻止站点通过 IP 地址、User-Agent、设备指纹或账号信息（手机号 / 支付方式 / 恢复邮箱）将不同账号关联到同一设备。要彻底切分账号，请配合不同出口 IP（VPN / 代理）使用，或改用「新建无痕窗口」做一次性登录。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空并重新加载")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }

            self?.clearWebsiteDataAndReload()
        }
    }

    @objc func zoomIn(_ sender: Any?) {
        setWebZoom(currentZoom + webZoomStep)
    }

    @objc func zoomOut(_ sender: Any?) {
        setWebZoom(currentZoom - webZoomStep)
    }

    @objc func resetZoom(_ sender: Any?) {
        setWebZoom(1.0)
        clearInjectedZoomState()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isPopup || !persistent {
            return true
        }

        persistMainWindowFrame()
        window.orderOut(nil)
        return false
    }

    func dispose() {
        childControllers.forEach { $0.window.close() }
        childControllers.removeAll()
        closeHandler = nil
        window.close()
    }

    func windowDidMove(_ notification: Notification) {
        persistMainWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistMainWindowFrame()
    }

    func windowWillClose(_ notification: Notification) {
        persistMainWindowFrame()
        Self.controllers.removeAll { $0 === self }
        closeHandler?()
    }

    func persistMainWindowFrame() {
        guard !isPopup, window != nil else {
            return
        }

        let frame = window.frame
        UserDefaults.standard.set([
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height,
        ], forKey: mainFrameDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let cleanedURL = Self.cleanTrackingParameters(from: url)

        if navigationAction.targetFrame == nil {
            if Self.shouldOpenInsideApp(cleanedURL) {
                openPopup(url: cleanedURL)
            } else {
                NSWorkspace.shared.open(cleanedURL)
            }
            decisionHandler(.cancel)
            return
        }

        if Self.shouldOpenInsideApp(cleanedURL) {
            if navigationAction.targetFrame?.isMainFrame == true,
               Self.canRewriteForPrivacy(navigationAction.request),
               Self.needsPrivacyRewrite(request: navigationAction.request, cleanedURL: cleanedURL, sourceURL: webView.url) {
                webView.load(Self.privacyRequest(for: cleanedURL, sourceURL: webView.url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(cleanedURL)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.pageZoom = currentZoom
        clearInjectedZoomState()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let host = navigationAction.request.url?.host ?? "ChatGPT"
        let child = BrowserWindowController(
            initialURL: nil,
            title: makePopupTitle(host: host),
            isPopup: true,
            persistent: persistent,
            profileID: profileID,
            configuration: configuration
        ) { [weak self] in
            self?.childControllers.removeAll { $0.window.isVisible == false }
        }
        childControllers.append(child)
        child.show()
        return child.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if isPopup {
            window.close()
        }
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    @available(macOS 11.3, *)
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    @available(macOS 11.3, *)
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        completionHandler(uniqueDownloadURL(suggestedFilename: suggestedFilename))
    }

    @available(macOS 11.3, *)
    func downloadDidFinish(_ download: WKDownload) {
        NSSound.beep()
    }

    @available(macOS 11.3, *)
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        presentError("下载失败：\(error.localizedDescription)")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "downloadBlob",
              let payload = message.body as? [String: Any],
              let dataURL = payload["dataURL"] as? String
        else {
            return
        }

        let suggestedName = (payload["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let outputURL = uniqueDownloadURL(suggestedFilename: suggestedName?.isEmpty == false ? suggestedName! : "chatgpt-download")
            let data = try decodeDataURL(dataURL)
            try data.write(to: outputURL, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } catch {
            presentError("保存下载失败：\(error.localizedDescription)")
        }
    }

    private func clearInjectedZoomState() {
        let script = """
        try {
          localStorage.removeItem('chatgptWebZoom');
          localStorage.removeItem('htmlZoom');
          document.documentElement.style.zoom = '';
          if (document.body) document.body.style.zoom = '';
          window.dispatchEvent(new Event('resize'));
        } catch (_) {}
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func setWebZoom(_ zoom: CGFloat) {
        let clamped = min(max(zoom, minimumWebZoom), maximumWebZoom)
        currentZoom = clamped
        webView.pageZoom = clamped
        UserDefaults.standard.set(Double(clamped), forKey: webZoomDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    private func openPopup(url: URL) {
        let host = url.host ?? "ChatGPT"
        let child = BrowserWindowController(
            initialURL: url,
            title: makePopupTitle(host: host),
            isPopup: true,
            persistent: persistent,
            profileID: profileID
        ) { [weak self] in
            self?.childControllers.removeAll { $0.window.isVisible == false }
        }
        childControllers.append(child)
        child.show()
    }

    private func profileDisplayName() -> String? {
        guard let profileID, profileID != defaultProfileID else {
            return nil
        }
        return ProfileStore.loadProfiles().first(where: { $0.id == profileID })?.name
    }

    private func makePopupTitle(host: String) -> String {
        if !persistent {
            return "\(host) · 无痕"
        }
        if let name = profileDisplayName() {
            return "\(host) · \(name)"
        }
        return host
    }

    private func presentError(_ text: String) {
        presentAlert(text, style: .warning)
    }

    private func presentInfo(_ text: String) {
        presentAlert(text, style: .informational)
    }

    private func presentAlert(_ text: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = "ChatGPT Swift"
        alert.informativeText = text
        alert.alertStyle = style
        alert.beginSheetModal(for: window)
    }

    private func importCookies(from url: URL) {
        do {
            let cookies = try Self.loadCookieExport(from: url)
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let group = DispatchGroup()

            for cookie in cookies {
                group.enter()
                cookieStore.setCookie(cookie) {
                    group.leave()
                }
            }

            group.notify(queue: .main) { [weak self] in
                self?.presentInfo("已导入 \(cookies.count) 个 cookie，正在刷新页面。")
                self?.webView.reload()
            }
        } catch {
            presentError("Cookie 导入失败：\(Self.safeCookieImportMessage(error))")
        }
    }

    private func clearWebsiteDataAndReload() {
        let dataStore = webView.configuration.websiteDataStore
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let group = DispatchGroup()

        group.enter()
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {
            group.leave()
        }

        group.enter()
        dataStore.httpCookieStore.getAllCookies { cookies in
            guard !cookies.isEmpty else {
                group.leave()
                return
            }

            let cookieGroup = DispatchGroup()
            for cookie in cookies {
                cookieGroup.enter()
                dataStore.httpCookieStore.delete(cookie) {
                    cookieGroup.leave()
                }
            }

            cookieGroup.notify(queue: .main) {
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else {
                return
            }

            URLCache.shared.removeAllCachedResponses()
            let children = self.childControllers
            self.childControllers.removeAll()
            children.forEach { $0.window.close() }
            self.currentZoom = 1.0
            UserDefaults.standard.removeObject(forKey: webZoomDefaultsKey)
            UserDefaults.standard.synchronize()
            self.webView.pageZoom = self.currentZoom
            let target = ProfileStore.homepageURL(for: self.profileID ?? defaultProfileID)
            self.webView.load(Self.privacyRequest(for: target, sourceURL: nil, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
            self.presentInfo("已清空当前账号空间在本 App 内的数据，页面已恢复为空白登录态。其他账号空间不受影响。")
        }
    }

    private static func loadCookieExport(from url: URL) throws -> [HTTPCookie] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumCookieImportBytes {
            throw cookieImportError("JSON 文件过大")
        }

        let data = try Data(contentsOf: url)
        let exportedCookies = try JSONDecoder().decode([ExportedBrowserCookie].self, from: data)
        let cookies = try exportedCookies.map { try $0.makeCookie() }
        guard !cookies.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }
        return cookies
    }

    private static func safeCookieImportMessage(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .dataCorrupted:
                return "JSON 内容无效"
            case .keyNotFound:
                return "JSON 缺少必要字段"
            case .typeMismatch, .valueNotFound:
                return "JSON 字段类型不匹配"
            @unknown default:
                return "JSON 解析失败"
            }
        }

        let nsError = error as NSError
        if nsError.domain == cookieImportErrorDomain, let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String {
            return message
        }

        return error.localizedDescription
    }

    fileprivate static func cookieImportError(_ message: String) -> NSError {
        NSError(domain: cookieImportErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func decodeDataURL(_ dataURL: String) throws -> Data {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 1, userInfo: [NSLocalizedDescriptionKey: "不是有效的 data URL"])
        }

        let header = dataURL[..<commaIndex]
        let body = String(dataURL[dataURL.index(after: commaIndex)...])
        if header.contains(";base64") {
            guard let data = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
                throw NSError(domain: "ChatGPTSwiftWeb", code: 2, userInfo: [NSLocalizedDescriptionKey: "Base64 数据无法解码"])
            }
            return data
        }

        guard let decoded = body.removingPercentEncoding,
              let data = decoded.data(using: .utf8)
        else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 3, userInfo: [NSLocalizedDescriptionKey: "文本数据无法解码"])
        }
        return data
    }

    private func uniqueDownloadURL(suggestedFilename: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let sanitized = sanitizeFilename(suggestedFilename)
        let ext = URL(fileURLWithPath: sanitized).pathExtension
        let stem = URL(fileURLWithPath: sanitized).deletingPathExtension().lastPathComponent
        var candidate = downloads.appendingPathComponent(sanitized)
        var index = 1

        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            candidate = downloads.appendingPathComponent(nextName)
            index += 1
        }

        return candidate
    }

    private func sanitizeFilename(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "chatgpt-download" : cleaned
    }

    private static func makeConfiguration(messageHandler: WKScriptMessageHandler, persistent: Bool, profileID: String?) -> WKWebViewConfiguration {
        let userContentController = WKUserContentController()
        userContentController.add(messageHandler, name: "downloadBlob")
        userContentController.addUserScript(WKUserScript(source: downloadBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        userContentController.addUserScript(WKUserScript(source: privacySignalsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if let fingerprint = ProfileStore.fingerprint(for: profileID) {
            userContentController.addUserScript(WKUserScript(source: FingerprintCatalog.script(for: fingerprint), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if ProfileStore.isEnhancedPrivacyEnabled(for: profileID) {
            let script = FingerprintCatalog.enhancedPrivacyScript(profileID: profileID, fingerprint: ProfileStore.fingerprint(for: profileID))
            userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if PrivacySettings.isWebRTCProtectionEnabled(profileID: profileID) {
            userContentController.addUserScript(WKUserScript(source: webRTCBlockerScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = resolveDataStore(persistent: persistent, profileID: profileID)
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.allowsAirPlayForMediaPlayback = true

        if #available(macOS 14.0, *) {
            configuration.upgradeKnownHostsToHTTPS = true
        }

        return configuration
    }

    private static func resolveDataStore(persistent: Bool, profileID: String?) -> WKWebsiteDataStore {
        if !persistent {
            return .nonPersistent()
        }

        guard let profileID, profileID != defaultProfileID, let uuid = UUID(uuidString: profileID) else {
            return .default()
        }

        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: uuid)
        }
        return .default()
    }

    private static func shouldOpenInsideApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        if ["about", "blob", "data"].contains(scheme) {
            return true
        }

        guard ["http", "https"].contains(scheme),
              let host = url.host?.lowercased()
        else {
            return false
        }

        let internalDomains = [
            "chatgpt.com",
            "chat.openai.com",
            "openai.com",
            "auth.openai.com",
            "auth0.openai.com",
            "platform.openai.com",
            "login.openai.com",
            "accounts.google.com",
            "appleid.apple.com",
            "login.microsoftonline.com",
            "github.com",
        ]

        return internalDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func canRewriteForPrivacy(_ request: URLRequest) -> Bool {
        let method = request.httpMethod?.uppercased() ?? "GET"
        return method == "GET" || method == "HEAD"
    }

    private static func needsPrivacyRewrite(request: URLRequest, cleanedURL: URL, sourceURL: URL?) -> Bool {
        guard let originalURL = request.url else {
            return false
        }
        if cleanedURL.absoluteString != originalURL.absoluteString {
            return true
        }
        if request.value(forHTTPHeaderField: "Sec-GPC") != "1" {
            return true
        }
        guard shouldTrimReferrer(from: sourceURL, to: cleanedURL) else {
            return false
        }
        return request.value(forHTTPHeaderField: "Referer") != originReferrer(from: sourceURL)
    }

    private static func privacyRequest(
        for url: URL,
        sourceURL: URL?,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) -> URLRequest {
        let cleanedURL = cleanTrackingParameters(from: url)
        var request = URLRequest(url: cleanedURL, cachePolicy: cachePolicy)
        request.setValue("1", forHTTPHeaderField: "Sec-GPC")
        if shouldTrimReferrer(from: sourceURL, to: cleanedURL),
           let origin = originReferrer(from: sourceURL) {
            request.setValue(origin, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private static func shouldTrimReferrer(from sourceURL: URL?, to destinationURL: URL) -> Bool {
        guard let sourceHost = sourceURL?.host?.lowercased(),
              let destinationHost = destinationURL.host?.lowercased(),
              ["http", "https"].contains(destinationURL.scheme?.lowercased() ?? "")
        else {
            return false
        }
        return sourceHost != destinationHost
    }

    private static func originReferrer(from url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased()
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port {
            components.port = port
        }
        return components.url?.absoluteString
    }

    private static func cleanTrackingParameters(from url: URL) -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else {
            return url
        }

        let filteredItems = queryItems.filter { !isTrackingQueryParameter($0.name) }
        if filteredItems.count == queryItems.count {
            return url
        }

        components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        return components.url ?? url
    }

    private static func isTrackingQueryParameter(_ name: String) -> Bool {
        let normalized = name.lowercased()
        if normalized.hasPrefix("utm_") {
            return true
        }

        let knownTrackingParameters: Set<String> = [
            "_hsenc",
            "_hsmi",
            "dclid",
            "fbclid",
            "gbraid",
            "gclid",
            "igshid",
            "li_fat_id",
            "mc_cid",
            "mc_eid",
            "mkt_tok",
            "msclkid",
            "oly_anon_id",
            "oly_enc_id",
            "rb_clickid",
            "scid",
            "ttclid",
            "twclid",
            "vero_id",
            "wbraid",
            "yclid",
        ]
        return knownTrackingParameters.contains(normalized)
    }

    private static func restoredMainWindowFrame() -> NSRect? {
        guard let raw = UserDefaults.standard.dictionary(forKey: mainFrameDefaultsKey),
              let x = raw["x"] as? CGFloat,
              let y = raw["y"] as? CGFloat,
              let width = raw["width"] as? CGFloat,
              let height = raw["height"] as? CGFloat
        else {
            return nil
        }

        let frame = NSRect(x: x, y: y, width: max(width, 900), height: max(height, 640))
        return clampToVisibleScreen(frame)
    }

    private static func savedWebZoom() -> CGFloat {
        let value = UserDefaults.standard.double(forKey: webZoomDefaultsKey)
        if value == 0 {
            return 1.0
        }
        return min(max(CGFloat(value), minimumWebZoom), maximumWebZoom)
    }

    static func keyWindowController() -> BrowserWindowController? {
        if let keyController = controllers.first(where: { $0.window.isKeyWindow }) {
            return keyController
        }
        return controllers.first(where: { $0.window.isVisible && !$0.isPopup })
    }

    private static func clampToVisibleScreen(_ frame: NSRect) -> NSRect {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else {
            return frame
        }

        let visible = screen.visibleFrame
        var clamped = frame
        clamped.size.width = min(max(clamped.size.width, 900), visible.size.width)
        clamped.size.height = min(max(clamped.size.height, 640), visible.size.height)

        if clamped.maxX > visible.maxX {
            clamped.origin.x = visible.maxX - clamped.size.width
        }
        if clamped.minX < visible.minX {
            clamped.origin.x = visible.minX
        }
        if clamped.maxY > visible.maxY {
            clamped.origin.y = visible.maxY - clamped.size.height
        }
        if clamped.minY < visible.minY {
            clamped.origin.y = visible.minY
        }

        return clamped.integral
    }

    private static let fingerprintTestHTML = """
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>指纹检测页</title>
      <style>
        :root { color-scheme: light dark; }
        body {
          margin: 0;
          padding: 28px;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
          background: Canvas;
          color: CanvasText;
        }
        main { max-width: 1040px; margin: 0 auto; }
        h1 { font-size: 24px; margin: 0 0 8px; }
        p { margin: 0 0 18px; color: color-mix(in srgb, CanvasText 72%, transparent); line-height: 1.5; }
        table { width: 100%; border-collapse: collapse; border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); }
        th, td {
          border-bottom: 1px solid color-mix(in srgb, CanvasText 14%, transparent);
          padding: 9px 10px;
          text-align: left;
          vertical-align: top;
          font-size: 13px;
        }
        th { width: 260px; font-weight: 650; }
        code { word-break: break-all; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .ok { color: #15803d; }
        .warn { color: #b45309; }
      </style>
    </head>
    <body>
      <main>
        <h1>指纹检测页</h1>
        <p>这个页面在当前账号空间内运行，用来检查 UA、navigator、screen、WebRTC、Canvas、WebGL 和 AudioContext 暴露值。切换指纹预设或增强隐私模式后重新打开即可对比。</p>
        <table>
          <tbody id="report"></tbody>
        </table>
      </main>
      <script>
        const text = (value) => {
          if (value === undefined) return 'undefined';
          if (value === null) return 'null';
          if (Array.isArray(value)) return JSON.stringify(value);
          if (typeof value === 'object') {
            try { return JSON.stringify(value); } catch (_) { return String(value); }
          }
          return String(value);
        };
        const hashString = (value) => {
          let hash = 2166136261;
          const raw = String(value);
          for (let i = 0; i < raw.length; i += 1) {
            hash ^= raw.charCodeAt(i);
            hash = Math.imul(hash, 16777619);
          }
          return (hash >>> 0).toString(16).padStart(8, '0');
        };
        const canvasHash = () => {
          try {
            const canvas = document.createElement('canvas');
            canvas.width = 240;
            canvas.height = 80;
            const ctx = canvas.getContext('2d');
            ctx.fillStyle = '#f5f5f5';
            ctx.fillRect(0, 0, canvas.width, canvas.height);
            ctx.fillStyle = '#123456';
            ctx.font = '18px -apple-system, Arial';
            ctx.fillText('ChatGPT Swift 指纹检测 123', 12, 32);
            ctx.strokeStyle = '#c2410c';
            ctx.beginPath();
            ctx.arc(180, 42, 22, 0, Math.PI * 2);
            ctx.stroke();
            return hashString(canvas.toDataURL());
          } catch (error) {
            return 'error: ' + error.message;
          }
        };
        const webglInfo = () => {
          try {
            const canvas = document.createElement('canvas');
            const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
            if (!gl) return { available: false };
            const debug = gl.getExtension('WEBGL_debug_renderer_info');
            return {
              available: true,
              vendor: debug ? gl.getParameter(debug.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
              renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
              version: gl.getParameter(gl.VERSION)
            };
          } catch (error) {
            return { error: error.message };
          }
        };
        const audioHash = async () => {
          try {
            const Offline = window.OfflineAudioContext || window.webkitOfflineAudioContext;
            if (!Offline) return 'unavailable';
            const ctx = new Offline(1, 4410, 44100);
            const oscillator = ctx.createOscillator();
            const compressor = ctx.createDynamicsCompressor();
            oscillator.type = 'triangle';
            oscillator.frequency.value = 10000;
            compressor.threshold.value = -50;
            compressor.knee.value = 40;
            compressor.ratio.value = 12;
            compressor.attack.value = 0;
            compressor.release.value = 0.25;
            oscillator.connect(compressor);
            compressor.connect(ctx.destination);
            oscillator.start(0);
            const buffer = await ctx.startRendering();
            const data = buffer.getChannelData(0);
            let sum = 0;
            for (let i = 0; i < data.length; i += 37) sum += Math.abs(data[i]);
            return hashString(sum.toFixed(12));
          } catch (error) {
            return 'error: ' + error.message;
          }
        };
        const rows = [];
        const add = (key, value) => rows.push([key, text(value)]);

        add('URL', location.href);
        add('User-Agent', navigator.userAgent);
        add('navigator.platform', navigator.platform);
        add('navigator.language', navigator.language);
        add('navigator.languages', Array.from(navigator.languages || []));
        add('navigator.hardwareConcurrency', navigator.hardwareConcurrency);
        add('navigator.deviceMemory', navigator.deviceMemory);
        add('navigator.maxTouchPoints', navigator.maxTouchPoints);
        add('navigator.userAgentData', navigator.userAgentData);
        add('plugins.length', navigator.plugins ? navigator.plugins.length : 'undefined');
        add('mimeTypes.length', navigator.mimeTypes ? navigator.mimeTypes.length : 'undefined');
        add('TouchEvent', 'TouchEvent' in window ? 'present' : 'absent');
        add('screen', {
          width: screen.width,
          height: screen.height,
          availWidth: screen.availWidth,
          availHeight: screen.availHeight,
          colorDepth: screen.colorDepth,
          pixelDepth: screen.pixelDepth,
          orientation: screen.orientation ? { type: screen.orientation.type, angle: screen.orientation.angle } : undefined
        });
        add('window size', {
          innerWidth,
          innerHeight,
          outerWidth,
          outerHeight,
          devicePixelRatio
        });
        add('timezone', Intl.DateTimeFormat().resolvedOptions().timeZone);
        add('WebRTC constructors', {
          RTCPeerConnection: typeof RTCPeerConnection,
          webkitRTCPeerConnection: typeof webkitRTCPeerConnection,
          RTCIceCandidate: typeof RTCIceCandidate
        });
        add('mediaDevices.enumerateDevices', navigator.mediaDevices && navigator.mediaDevices.enumerateDevices ? 'present' : 'absent');
        add('Canvas hash', canvasHash());
        add('WebGL', webglInfo());

        audioHash().then((audio) => {
          add('Audio hash', audio);
          document.getElementById('report').innerHTML = rows.map(([key, value]) => {
            const cls = value === 'undefined' || value === 'absent' ? 'warn' : 'ok';
            return `<tr><th>${key}</th><td class="${cls}"><code>${value.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]))}</code></td></tr>`;
          }).join('');
        });
      </script>
    </body>
    </html>
    """

    private static let downloadBridgeScript = """
    (() => {
      if (window.__chatgptSwiftDownloadBridge) return;
      window.__chatgptSwiftDownloadBridge = true;

      const blobURLs = new Map();
      const originalCreateObjectURL = URL.createObjectURL.bind(URL);
      URL.createObjectURL = (value) => {
        const url = originalCreateObjectURL(value);
        try {
          if (value instanceof Blob) blobURLs.set(url, value);
        } catch (_) {}
        return url;
      };

      function readBlob(blob) {
        return new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = () => reject(reader.error || new Error('Unable to read blob'));
          reader.readAsDataURL(blob);
        });
      }

      async function resolveDataURL(href) {
        if (href.startsWith('data:')) return href;
        const cached = blobURLs.get(href);
        if (cached) return await readBlob(cached);
        const response = await fetch(href);
        return await readBlob(await response.blob());
      }

      document.addEventListener('click', async (event) => {
        const target = event.target && event.target.closest ? event.target.closest('a[href]') : null;
        if (!target) return;

        const href = target.href || '';
        if (!href.startsWith('blob:') && !href.startsWith('data:')) return;

        event.preventDefault();
        event.stopImmediatePropagation();

        try {
          const dataURL = await resolveDataURL(href);
          window.webkit.messageHandlers.downloadBlob.postMessage({
            filename: target.download || 'chatgpt-download',
            dataURL
          });
        } catch (error) {
          console.error('[ChatGPT Swift] blob download bridge failed', error);
        }
      }, true);
    })();
    """
}

private struct ExportedBrowserCookie: Codable {
    let domain: String
    let expirationDate: Double?
    let hostOnly: Bool?
    let httpOnly: Bool?
    let name: String
    let path: String
    let sameSite: String?
    let secure: Bool?
    let session: Bool?
    let value: String

    init(cookie: HTTPCookie) {
        self.domain = cookie.domain
        self.name = cookie.name
        self.value = cookie.value
        self.path = cookie.path.isEmpty ? "/" : cookie.path
        self.secure = cookie.isSecure
        self.httpOnly = cookie.isHTTPOnly
        self.session = cookie.isSessionOnly
        self.hostOnly = !cookie.domain.hasPrefix(".")
        if cookie.isSessionOnly {
            self.expirationDate = nil
        } else {
            self.expirationDate = cookie.expiresDate?.timeIntervalSince1970
        }
        self.sameSite = Self.sameSiteString(from: cookie)
    }

    static func sameSiteString(from cookie: HTTPCookie) -> String? {
        if let raw = cookie.properties?[HTTPCookiePropertyKey("SameSite")] as? String {
            switch raw.lowercased() {
            case "lax":
                return "lax"
            case "strict":
                return "strict"
            case "none", "no_restriction":
                return "no_restriction"
            default:
                break
            }
        }
        if #available(macOS 10.15, *) {
            switch cookie.sameSitePolicy {
            case HTTPCookieStringPolicy.sameSiteLax:
                return "lax"
            case HTTPCookieStringPolicy.sameSiteStrict:
                return "strict"
            default:
                return nil
            }
        }
        return nil
    }

    func makeCookie() throws -> HTTPCookie {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cookiePath = path.isEmpty ? "/" : path

        guard !trimmedName.isEmpty else {
            throw BrowserWindowController.cookieImportError("cookie 名称为空")
        }
        guard !trimmedDomain.isEmpty else {
            throw BrowserWindowController.cookieImportError("cookie 域名为空")
        }
        guard cookiePath.hasPrefix("/") else {
            throw BrowserWindowController.cookieImportError("cookie path 无效")
        }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: trimmedName,
            .value: value,
            .domain: trimmedDomain,
            .path: cookiePath,
            .version: "0",
        ]

        if secure == true {
            properties[.secure] = "TRUE"
        }
        if httpOnly == true {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        if let sameSiteValue = normalizedSameSiteValue(sameSite) {
            properties[HTTPCookiePropertyKey("SameSite")] = sameSiteValue
        }
        if session != true, let expirationDate {
            properties[.expires] = Date(timeIntervalSince1970: expirationDate)
        }

        guard let cookie = HTTPCookie(properties: properties) else {
            throw BrowserWindowController.cookieImportError("cookie 数据无法转换")
        }

        return cookie
    }

    private func normalizedSameSiteValue(_ rawValue: String?) -> String? {
        switch rawValue?.lowercased() {
        case "lax":
            return "Lax"
        case "strict":
            return "Strict"
        case "none", "no_restriction":
            return "None"
        default:
            return nil
        }
    }
}

private struct WebProfile: Codable {
    let id: String
    var name: String
    var createdAt: Date
}

private struct ProfileExportDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let sourceProfileID: String
    let name: String
    let homepage: String?
    let fingerprint: FingerprintProfile?
    let enhancedPrivacyEnabled: Bool
}

private struct FingerprintProfile: Codable {
    let presetID: String
    let displayName: String
    let userAgent: String
    let acceptLanguages: [String]
    let platform: String
    let hardwareConcurrency: Int
    let deviceMemory: Int
    let screenWidth: Int
    let screenHeight: Int
    let colorDepth: Int
    let devicePixelRatio: Double
    let maxTouchPoints: Int
    let timezone: String?
}

private enum FingerprintCatalog {
    static let offPresetID = "off"

    private static let macSafari17UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    private static let iPadSafari17UserAgent = "Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
    private static let iPhoneSafari17UserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
    private static let defaultLanguages = ["zh-CN", "en-US"]

    static let presets: [FingerprintProfile] = [
        FingerprintProfile(
            presetID: "mba13",
            displayName: "MacBook Air 13\" M2",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultLanguages,
            platform: "MacIntel",
            hardwareConcurrency: 8,
            deviceMemory: 8,
            screenWidth: 1470,
            screenHeight: 956,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 0,
            timezone: nil
        ),
        FingerprintProfile(
            presetID: "mbp14",
            displayName: "MacBook Pro 14\" M3",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultLanguages,
            platform: "MacIntel",
            hardwareConcurrency: 10,
            deviceMemory: 16,
            screenWidth: 1512,
            screenHeight: 982,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 0,
            timezone: nil
        ),
        FingerprintProfile(
            presetID: "imac5k",
            displayName: "iMac 27\" 5K",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultLanguages,
            platform: "MacIntel",
            hardwareConcurrency: 10,
            deviceMemory: 32,
            screenWidth: 2560,
            screenHeight: 1440,
            colorDepth: 30,
            devicePixelRatio: 2.0,
            maxTouchPoints: 0,
            timezone: nil
        ),
        FingerprintProfile(
            presetID: "ipad13",
            displayName: "iPad Pro 12.9\"",
            userAgent: iPadSafari17UserAgent,
            acceptLanguages: defaultLanguages,
            platform: "iPad",
            hardwareConcurrency: 8,
            deviceMemory: 8,
            screenWidth: 1024,
            screenHeight: 1366,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 10,
            timezone: nil
        ),
        FingerprintProfile(
            presetID: "iphone15pro",
            displayName: "iPhone 15 Pro",
            userAgent: iPhoneSafari17UserAgent,
            acceptLanguages: defaultLanguages,
            platform: "iPhone",
            hardwareConcurrency: 6,
            deviceMemory: 6,
            screenWidth: 393,
            screenHeight: 852,
            colorDepth: 24,
            devicePixelRatio: 3.0,
            maxTouchPoints: 5,
            timezone: nil
        ),
    ]

    static func preset(for id: String) -> FingerprintProfile? {
        presets.first { $0.presetID == id }
    }

    static func randomProfile() -> FingerprintProfile {
        let weightedClass = Int.random(in: 0..<10)
        if weightedClass < 7 {
            return randomMacProfile()
        }
        if weightedClass < 9 {
            return randomIpadProfile()
        }
        return randomIphoneProfile()
    }

    static func script(for fingerprint: FingerprintProfile) -> String {
        let languagesJSON = jsonLiteral(fingerprint.acceptLanguages)
        let primaryLanguage = fingerprint.acceptLanguages.first ?? "en-US"
        let timezoneBlock: String
        if let timezone = fingerprint.timezone {
            timezoneBlock = """
              const OrigDTF = Intl.DateTimeFormat;
              const TZ = \(jsonLiteral(timezone));
              const Override = function(loc, opts) {
                const o = Object.assign({}, opts || {});
                if (!o.timeZone) o.timeZone = TZ;
                return new OrigDTF(loc, o);
              };
              Override.prototype = OrigDTF.prototype;
              Intl.DateTimeFormat = Override;
            """
        } else {
            timezoneBlock = ""
        }

        return """
        (() => {
          if (window.__chatgptSwiftFingerprint) return;
          window.__chatgptSwiftFingerprint = true;

          const def = (obj, key, val) => {
            try { Object.defineProperty(obj, key, { get: () => val, configurable: true }); } catch (_) {}
          };

          const langs = Object.freeze(\(languagesJSON).slice ? \(languagesJSON).slice() : \(languagesJSON));

          def(navigator, 'platform', \(jsonLiteral(fingerprint.platform)));
          def(navigator, 'language', \(jsonLiteral(primaryLanguage)));
          def(navigator, 'languages', langs);
          def(navigator, 'hardwareConcurrency', \(fingerprint.hardwareConcurrency));
          def(navigator, 'deviceMemory', \(fingerprint.deviceMemory));
          def(navigator, 'maxTouchPoints', \(fingerprint.maxTouchPoints));

          def(screen, 'width', \(fingerprint.screenWidth));
          def(screen, 'height', \(fingerprint.screenHeight));
          def(screen, 'availWidth', \(fingerprint.screenWidth));
          def(screen, 'availHeight', \(fingerprint.screenHeight));
          def(screen, 'colorDepth', \(fingerprint.colorDepth));
          def(screen, 'pixelDepth', \(fingerprint.colorDepth));

          def(window, 'devicePixelRatio', \(fingerprint.devicePixelRatio));

        \(timezoneBlock)
        })();
        """
    }

    static func enhancedPrivacyScript(profileID: String?, fingerprint: FingerprintProfile?) -> String {
        let seed = stableSeed(from: [profileID ?? "incognito", fingerprint?.presetID ?? "safari", "enhanced-privacy"].joined(separator: ":"))
        let maxTouchPoints = fingerprint?.maxTouchPoints ?? 0
        let orientationType: String
        if let fingerprint, fingerprint.screenHeight >= fingerprint.screenWidth {
            orientationType = "portrait-primary"
        } else {
            orientationType = "landscape-primary"
        }
        let orientationAngle = orientationType.hasPrefix("portrait") ? 0 : 90
        let webGLRenderer = maxTouchPoints > 0 ? "Apple GPU" : "Apple M-Series GPU"

        return """
        (() => {
          if (window.__chatgptSwiftEnhancedPrivacy) return;
          try {
            Object.defineProperty(window, '__chatgptSwiftEnhancedPrivacy', { value: true, configurable: false, writable: false });
          } catch (_) {}

          const seed = \(seed);
          const maxTouchPoints = \(maxTouchPoints);
          const def = (obj, key, val) => {
            try { Object.defineProperty(obj, key, { get: () => val, configurable: true }); } catch (_) {}
          };
          const defValue = (obj, key, val) => {
            try { Object.defineProperty(obj, key, { value: val, configurable: true, writable: false }); } catch (_) {}
          };
          const noise = (i) => {
            let x = (seed + Math.imul(i + 1, 374761393)) | 0;
            x = Math.imul(x ^ (x >>> 13), 1274126177);
            return ((x ^ (x >>> 16)) & 1) ? 1 : -1;
          };

          def(navigator, 'userAgentData', undefined);

          const emptyArray = Object.freeze([]);
          def(navigator, 'plugins', emptyArray);
          def(navigator, 'mimeTypes', emptyArray);

          if (maxTouchPoints > 0) {
            try {
              if (!('ontouchstart' in window)) def(window, 'ontouchstart', null);
              if (!window.TouchEvent && window.UIEvent) defValue(window, 'TouchEvent', window.UIEvent);
            } catch (_) {}
          }

          const orientation = Object.freeze({
            type: \(jsonLiteral(orientationType)),
            angle: \(orientationAngle),
            onchange: null,
            addEventListener: () => {},
            removeEventListener: () => {},
            dispatchEvent: () => true
          });
          def(screen, 'orientation', orientation);

          try {
            if (navigator.permissions && navigator.permissions.query) {
              const originalQuery = navigator.permissions.query.bind(navigator.permissions);
              navigator.permissions.query = (descriptor) => {
                try {
                  return originalQuery(descriptor).catch(() => Promise.resolve({ state: 'prompt', onchange: null }));
                } catch (_) {
                  return Promise.resolve({ state: 'prompt', onchange: null });
                }
              };
            }
          } catch (_) {}

          try {
            if (!navigator.mediaDevices) {
              def(navigator, 'mediaDevices', {
                enumerateDevices: () => Promise.resolve([])
              });
            } else if (navigator.mediaDevices.enumerateDevices) {
              const originalEnumerateDevices = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
              navigator.mediaDevices.enumerateDevices = () => originalEnumerateDevices().catch(() => []);
            }
          } catch (_) {}

          const applyCanvasNoise = (imageData, offset) => {
            try {
              const data = imageData && imageData.data;
              if (!data) return imageData;
              for (let i = offset || 0; i < data.length; i += 97) {
                data[i] = Math.max(0, Math.min(255, data[i] + noise(i)));
              }
            } catch (_) {}
            return imageData;
          };
          const perturbCanvas = (canvas) => {
            try {
              if (!canvas || !canvas.width || !canvas.height) return;
              const ctx = canvas.getContext('2d', { willReadFrequently: true });
              if (!ctx) return;
              const width = Math.min(8, canvas.width);
              const height = Math.min(8, canvas.height);
              const imageData = ctx.getImageData(0, 0, width, height);
              applyCanvasNoise(imageData, 3);
              ctx.putImageData(imageData, 0, 0);
            } catch (_) {}
          };
          try {
            const canvas2D = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
            if (canvas2D && canvas2D.getImageData) {
              const originalGetImageData = canvas2D.getImageData;
              canvas2D.getImageData = function(...args) {
                return applyCanvasNoise(originalGetImageData.apply(this, args), 7);
              };
            }
            if (window.HTMLCanvasElement) {
              const originalToDataURL = HTMLCanvasElement.prototype.toDataURL;
              if (originalToDataURL) {
                HTMLCanvasElement.prototype.toDataURL = function(...args) {
                  perturbCanvas(this);
                  return originalToDataURL.apply(this, args);
                };
              }
              const originalToBlob = HTMLCanvasElement.prototype.toBlob;
              if (originalToBlob) {
                HTMLCanvasElement.prototype.toBlob = function(...args) {
                  perturbCanvas(this);
                  return originalToBlob.apply(this, args);
                };
              }
            }
          } catch (_) {}

          const patchWebGL = (proto) => {
            if (!proto) return;
            try {
              const originalGetParameter = proto.getParameter;
              proto.getParameter = function(parameter) {
                if (parameter === 37445) return 'Apple Inc.';
                if (parameter === 37446) return \(jsonLiteral(webGLRenderer));
                return originalGetParameter.apply(this, arguments);
              };
            } catch (_) {}
            try {
              const originalReadPixels = proto.readPixels;
              proto.readPixels = function(...args) {
                const result = originalReadPixels.apply(this, args);
                const pixels = args[6];
                if (pixels && typeof pixels.length === 'number') {
                  for (let i = 0; i < pixels.length; i += 101) {
                    pixels[i] = Math.max(0, Math.min(255, pixels[i] + noise(i + 11)));
                  }
                }
                return result;
              };
            } catch (_) {}
          };
          patchWebGL(window.WebGLRenderingContext && WebGLRenderingContext.prototype);
          patchWebGL(window.WebGL2RenderingContext && WebGL2RenderingContext.prototype);

          try {
            if (window.AudioBuffer && AudioBuffer.prototype.getChannelData) {
              const originalGetChannelData = AudioBuffer.prototype.getChannelData;
              AudioBuffer.prototype.getChannelData = function(...args) {
                const data = originalGetChannelData.apply(this, args);
                try {
                  for (let i = 0; i < data.length; i += 113) {
                    data[i] += noise(i + 23) * 0.0000001;
                  }
                } catch (_) {}
                return data;
              };
            }
            if (window.AnalyserNode && AnalyserNode.prototype.getFloatFrequencyData) {
              const originalGetFloatFrequencyData = AnalyserNode.prototype.getFloatFrequencyData;
              AnalyserNode.prototype.getFloatFrequencyData = function(array) {
                const result = originalGetFloatFrequencyData.apply(this, arguments);
                try {
                  for (let i = 0; i < array.length; i += 127) {
                    array[i] += noise(i + 31) * 0.0001;
                  }
                } catch (_) {}
                return result;
              };
            }
          } catch (_) {}
        })();
        """
    }

    private static func randomMacProfile() -> FingerprintProfile {
        let cores = [4, 6, 8, 10, 12].randomElement() ?? 8
        let memory = [8, 16, 32].randomElement() ?? 16
        let screen = [
            (1280, 800),
            (1470, 956),
            (1512, 982),
            (1920, 1080),
            (2560, 1440),
            (3024, 1964),
        ].randomElement() ?? (1470, 956)

        return FingerprintProfile(
            presetID: "random-\(UUID().uuidString)",
            displayName: "随机：MacBook Air-ish",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultLanguages,
            platform: "MacIntel",
            hardwareConcurrency: cores,
            deviceMemory: memory,
            screenWidth: screen.0,
            screenHeight: screen.1,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 0,
            timezone: nil
        )
    }

    private static func randomIpadProfile() -> FingerprintProfile {
        let cores = [6, 8].randomElement() ?? 8
        let memory = [6, 8].randomElement() ?? 8
        let screen = [
            (820, 1180),
            (834, 1194),
            (1024, 1366),
        ].randomElement() ?? (1024, 1366)

        return FingerprintProfile(
            presetID: "random-\(UUID().uuidString)",
            displayName: "随机：iPad-ish",
            userAgent: iPadSafari17UserAgent,
            acceptLanguages: defaultLanguages,
            platform: "iPad",
            hardwareConcurrency: cores,
            deviceMemory: memory,
            screenWidth: screen.0,
            screenHeight: screen.1,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 10,
            timezone: nil
        )
    }

    private static func randomIphoneProfile() -> FingerprintProfile {
        let cores = [4, 6].randomElement() ?? 6
        let memory = [4, 6, 8].randomElement() ?? 6
        let screen = [
            (390, 844),
            (393, 852),
            (430, 932),
        ].randomElement() ?? (393, 852)

        return FingerprintProfile(
            presetID: "random-\(UUID().uuidString)",
            displayName: "随机：iPhone-ish",
            userAgent: iPhoneSafari17UserAgent,
            acceptLanguages: defaultLanguages,
            platform: "iPhone",
            hardwareConcurrency: cores,
            deviceMemory: memory,
            screenWidth: screen.0,
            screenHeight: screen.1,
            colorDepth: 24,
            devicePixelRatio: 3.0,
            maxTouchPoints: 5,
            timezone: nil
        )
    }

    private static func jsonLiteral<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    private static func stableSeed(from value: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash == 0 ? 1 : hash
    }
}

private enum ProfileStore {
    static func loadProfiles() -> [WebProfile] {
        var profiles: [WebProfile] = []
        if let data = UserDefaults.standard.data(forKey: profilesDefaultsKey),
           let decoded = try? JSONDecoder().decode([WebProfile].self, from: data) {
            profiles = decoded
        }
        if !profiles.contains(where: { $0.id == defaultProfileID }) {
            profiles.insert(WebProfile(id: defaultProfileID, name: "默认", createdAt: Date()), at: 0)
            save(profiles)
        }
        return profiles
    }

    static func save(_ profiles: [WebProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        UserDefaults.standard.set(data, forKey: profilesDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func currentProfileID() -> String {
        UserDefaults.standard.string(forKey: currentProfileDefaultsKey) ?? defaultProfileID
    }

    static func setCurrentProfileID(_ id: String) {
        UserDefaults.standard.set(id, forKey: currentProfileDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func currentProfile() -> WebProfile {
        let profiles = loadProfiles()
        let id = currentProfileID()
        return profiles.first(where: { $0.id == id }) ?? profiles[0]
    }

    static func homepageURL(for profileID: String) -> URL {
        let key = profileHomepageDefaultsPrefix + profileID
        if let raw = UserDefaults.standard.string(forKey: key),
           let url = URL(string: raw),
           url.scheme?.lowercased() == "https" {
            return url
        }
        return chatGPTURL
    }

    static func homepageString(for profileID: String) -> String? {
        UserDefaults.standard.string(forKey: profileHomepageDefaultsPrefix + profileID)
    }

    static func setHomepage(_ url: URL?, for profileID: String) {
        let key = profileHomepageDefaultsPrefix + profileID
        if let url, url.scheme?.lowercased() == "https" {
            UserDefaults.standard.set(url.absoluteString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
    }

    static func removeHomepage(for profileID: String) {
        UserDefaults.standard.removeObject(forKey: profileHomepageDefaultsPrefix + profileID)
        UserDefaults.standard.synchronize()
    }

    static func isEnhancedPrivacyEnabled(for profileID: String?) -> Bool {
        guard let profileID else {
            return false
        }
        return UserDefaults.standard.bool(forKey: profileEnhancedPrivacyDefaultsPrefix + profileID)
    }

    static func setEnhancedPrivacyEnabled(_ enabled: Bool, for profileID: String) {
        let key = profileEnhancedPrivacyDefaultsPrefix + profileID
        if enabled {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.synchronize()
    }

    static func fingerprint(for profileID: String?) -> FingerprintProfile? {
        guard let profileID else {
            return nil
        }
        let key = profileFingerprintDefaultsPrefix + profileID
        guard let data = UserDefaults.standard.data(forKey: key),
              let fingerprint = try? JSONDecoder().decode(FingerprintProfile.self, from: data) else {
            return nil
        }
        return fingerprint
    }

    static func setFingerprint(_ fingerprint: FingerprintProfile?, for profileID: String) {
        let key = profileFingerprintDefaultsPrefix + profileID
        guard let fingerprint else {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.synchronize()
            return
        }
        guard let data = try? JSONEncoder().encode(fingerprint) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.synchronize()
    }
}

private enum PrivacySettings {
    static func isWebRTCProtectionRequested() -> Bool {
        if UserDefaults.standard.object(forKey: webRTCProtectionDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: webRTCProtectionDefaultsKey)
    }

    static func isWebRTCProtectionEnabled(profileID: String? = ProfileStore.currentProfileID()) -> Bool {
        isWebRTCProtectionRequested() || ProfileStore.fingerprint(for: profileID) != nil
    }

    static func setWebRTCProtectionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: webRTCProtectionDefaultsKey)
        UserDefaults.standard.synchronize()
    }
}

private let webRTCBlockerScript = """
(() => {
  if (window.__chatgptSwiftWebRTCBlocked) return;
  try {
    Object.defineProperty(window, '__chatgptSwiftWebRTCBlocked', { value: true, configurable: false, writable: false });
  } catch (_) {}
  try {
    const names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection', 'RTCIceCandidate', 'RTCSessionDescription', 'RTCDataChannel'];
    for (const name of names) {
      try {
        Object.defineProperty(window, name, { value: undefined, configurable: false, writable: false });
      } catch (_) {}
    }
    if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
      const original = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
      navigator.mediaDevices.enumerateDevices = () => original().then(() => []);
    }
  } catch (_) {}
})();
"""

private let privacySignalsScript = """
(() => {
  if (window.__chatgptSwiftPrivacySignals) return;
  try {
    Object.defineProperty(window, '__chatgptSwiftPrivacySignals', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const defineBooleanGetter = (target, key, value) => {
    try {
      Object.defineProperty(target, key, { get: () => value, configurable: true });
    } catch (_) {}
  };

  defineBooleanGetter(Navigator.prototype, 'globalPrivacyControl', true);
  defineBooleanGetter(navigator, 'globalPrivacyControl', true);
})();
"""

@main
enum Main {
    private static let delegate = AppDelegate()

    static func main() {
        SingleInstance.activateExistingInstanceOrAcquireLock()

        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }
}

enum SingleInstance {
    static func activateExistingInstanceOrAcquireLock() {
        let lockPath = lockFileURL().path
        let fileDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard fileDescriptor >= 0 else {
            return
        }

        if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            singleInstanceLockFileDescriptor = fileDescriptor
            return
        }

        close(fileDescriptor)
        activateExistingInstance()
        exit(0)
    }

    private static func lockFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = supportDirectory.appendingPathComponent(appBundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent("single-instance.lock")
    }

    private static func activateExistingInstance() {
        let currentPID = getpid()
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
        let existingApp = runningApps.first { $0.processIdentifier != currentPID }
        existingApp?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}
