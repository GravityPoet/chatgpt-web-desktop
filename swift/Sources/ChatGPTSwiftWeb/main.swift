import AppKit
import Darwin
import Foundation
import OSLog
import UniformTypeIdentifiers
import UserNotifications
import WebKit

private let chatGPTURL = URL(string: "https://chatgpt.com/")!
private let appBundleIdentifier = "local.chatgpt-web.swift"
private let releasePageURL = URL(string: "https://github.com/GravityPoet/chatgpt-web-desktop/releases")!
private let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/GravityPoet/chatgpt-web-desktop/releases/latest")!
private let browserLogger = Logger(subsystem: appBundleIdentifier, category: "Browser")
private let mainFrameDefaultsKey = "ChatGPTSwiftWeb.MainWindowFrame"
private let webZoomDefaultsKey = "ChatGPTSwiftWeb.WebViewZoom"
private let promptDraftRestoreDefaultsKey = "ChatGPTSwiftWeb.PromptDraftRestoreEnabled"
private let promptDraftDefaultsPrefix = "ChatGPTSwiftWeb.PromptDraft."
private let backgroundCompletionNotificationsDefaultsKey = "ChatGPTSwiftWeb.BackgroundCompletionNotificationsEnabled"
private let lastRunStartedAtDefaultsKey = "ChatGPTSwiftWeb.LastRunStartedAt"
private let lastRunEndedAtDefaultsKey = "ChatGPTSwiftWeb.LastRunEndedAt"
private let lastRunCleanExitDefaultsKey = "ChatGPTSwiftWeb.LastRunCleanExit"
private let minimumWebZoom: CGFloat = 0.85
private let maximumWebZoom: CGFloat = 1.40
private let webZoomStep: CGFloat = 0.05
private let maximumPromptDraftCharacters = 12_000
private let maximumCookieImportBytes = 2 * 1024 * 1024
private let maximumChatGPTCookieHeaderBytes = 6 * 1024
private let maximumBridgeDownloadBytes = 200 * 1024 * 1024
private let maximumBridgeDownloadPayloadCharacters = maximumBridgeDownloadBytes * 2 + 4096
private let cookieImportErrorDomain = "ChatGPTSwiftWeb.CookieImport"
private let defaultHeaderCookieImportDomain = ".chatgpt.com"
private let profilesDefaultsKey = "ChatGPTSwiftWeb.Profiles"
private let currentProfileDefaultsKey = "ChatGPTSwiftWeb.CurrentProfileID"
private let startupProfileDefaultsKey = "ChatGPTSwiftWeb.StartupProfileID"
private let defaultProfileID = "default"
private let profileHomepageDefaultsPrefix = "ChatGPTSwiftWeb.ProfileHomepage."
private let profileFingerprintDefaultsPrefix = "ChatGPTSwiftWeb.ProfileFingerprint."
private let profileFingerprintDisabledDefaultsPrefix = "ChatGPTSwiftWeb.ProfileFingerprintDisabled."
private let profileEnhancedPrivacyDefaultsPrefix = "ChatGPTSwiftWeb.ProfileEnhancedPrivacy."
private let webRTCProtectionDefaultsKey = "ChatGPTSwiftWeb.WebRTCProtectionEnabled"
private let keepThirdPartyLinksInAppDefaultsKey = "ChatGPTSwiftWeb.KeepThirdPartyLinksInApp"
// WKWebView's native user agent stops at "(KHTML, like Gecko)" with no "Version/.. Safari/.."
// token. Cloudflare reads that truncated UA as a non-standard client and issues repeated
// challenges. This is the complete, engine-consistent Safari UA used when no fingerprint preset
// overrides it, so the WebKit engine presents as the real Safari it actually is.
private let defaultSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"
private let processStartedAt = Date()
private var singleInstanceLockFileDescriptor: CInt = -1

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: String?
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

private struct ProcessRunResult {
    let exitCode: Int32
    let output: String
    let errorOutput: String
}

private enum PromptDraftStore {
    static func isRestoreEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: promptDraftRestoreDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: promptDraftRestoreDefaultsKey)
    }

    static func setRestoreEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: promptDraftRestoreDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func draft(for profileID: String?) -> String {
        UserDefaults.standard.string(forKey: draftKey(profileID: profileID)) ?? ""
    }

    static func draftSummary(for profileID: String?) -> String {
        let draft = draft(for: profileID)
        guard !draft.isEmpty else {
            return "无"
        }
        return "\(draft.count) 个字符，仅保存在本机偏好中"
    }

    static func saveDraft(_ rawText: String, profileID: String?) {
        let text = normalizedDraft(rawText)
        let key = draftKey(profileID: profileID)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(text, forKey: key)
        }
    }

    static func clearDraft(for profileID: String?) {
        UserDefaults.standard.removeObject(forKey: draftKey(profileID: profileID))
        UserDefaults.standard.synchronize()
    }

    private static func draftKey(profileID: String?) -> String {
        promptDraftDefaultsPrefix + (profileID ?? defaultProfileID)
    }

    private static func normalizedDraft(_ rawText: String) -> String {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        if text.count <= maximumPromptDraftCharacters {
            return text
        }
        return String(text.prefix(maximumPromptDraftCharacters))
    }
}

private enum BackgroundCompletionNotifications {
    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: backgroundCompletionNotificationsDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: backgroundCompletionNotificationsDefaultsKey)
        UserDefaults.standard.synchronize()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var mainController: BrowserWindowController?
    private var incognitoControllers: [BrowserWindowController] = []
    private var keyMonitor: Any?
    private var profilesMenu: NSMenu?
    private var privacyMenu: NSMenu?
    private var webRTCProtectionItem: NSMenuItem?
    private var enhancedPrivacyItem: NSMenuItem?
    private var settingsWindowController: AppSettingsWindowController?
    private var diagnosticsWindowController: DiagnosticsWindowController?
    private var updateCheckStatus = "未检查；当前只提供 GitHub Releases 检查入口，完整自动更新需要 Sparkle appcast、EdDSA key 和签名发布流。"
    private var didApplyLaunchGeoIP = false
    private var didFinishLaunchingAt: Date?
    private var previousRunSummary = "未记录"
    private var notificationPermissionStatus = "未检查"

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunchingAt = Date()
        capturePreviousRunState()
        markRunStarted()
        UNUserNotificationCenter.current().delegate = self
        refreshNotificationPermissionStatus()
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        installKeyboardZoomShortcuts()
        let needsIsolationFallbackNotice = reconcileProfileIsolationOnLaunch()
        ProfileStore.applyStartupProfileIfAvailable()
        ProfileStore.ensurePrivacyBaseline()

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

        primeExitTimezoneAlignment()

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
        alert.informativeText = "多账号隔离需要 macOS 14 或更新版本。当前系统版本不支持隔离，已自动切回内置空间，避免不同空间共享同一份本地数据。\n\n要使用独立账号空间，请升级到 macOS 14 或更新版本。"
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
        markRunEndedCleanly()
        mainController?.persistMainWindowFrame()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func capturePreviousRunState() {
        let defaults = UserDefaults.standard
        let started = defaults.object(forKey: lastRunStartedAtDefaultsKey) as? Date
        let ended = defaults.object(forKey: lastRunEndedAtDefaultsKey) as? Date
        let hadCleanFlag = defaults.object(forKey: lastRunCleanExitDefaultsKey) != nil
        let clean = defaults.bool(forKey: lastRunCleanExitDefaultsKey)

        guard let started else {
            previousRunSummary = "首次运行或无历史记录"
            return
        }

        if hadCleanFlag, clean {
            previousRunSummary = "干净退出；开始 \(Self.timestampString(started))，结束 \(ended.map(Self.timestampString) ?? "未知")"
        } else {
            previousRunSummary = "可能非正常退出；上次开始 \(Self.timestampString(started))"
        }
    }

    private func markRunStarted() {
        let defaults = UserDefaults.standard
        defaults.set(processStartedAt, forKey: lastRunStartedAtDefaultsKey)
        defaults.removeObject(forKey: lastRunEndedAtDefaultsKey)
        defaults.set(false, forKey: lastRunCleanExitDefaultsKey)
        defaults.synchronize()
    }

    private func markRunEndedCleanly() {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: lastRunEndedAtDefaultsKey)
        defaults.set(true, forKey: lastRunCleanExitDefaultsKey)
        defaults.synchronize()
    }

    private func refreshNotificationPermissionStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.notificationPermissionStatus = Self.notificationStatusText(settings.authorizationStatus)
                if settings.authorizationStatus == .denied, BackgroundCompletionNotifications.isEnabled() {
                    BackgroundCompletionNotifications.setEnabled(false)
                }
                self.refreshNativeUtilityWindows()
            }
        }
    }

    private static func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "未请求"
        case .denied:
            return "已拒绝"
        case .authorized:
            return "已授权"
        case .provisional:
            return "临时授权"
        case .ephemeral:
            return "临时会话授权"
        @unknown default:
            return "未知"
        }
    }

    func postBackgroundCompletionNotification(from controller: BrowserWindowController) {
        guard BackgroundCompletionNotifications.isEnabled() else {
            return
        }

        UNUserNotificationCenter.current().getNotificationSettings { [weak self, weak controller] settings in
            guard let self,
                  let controller else {
                return
            }

            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                DispatchQueue.main.async {
                    self.notificationPermissionStatus = Self.notificationStatusText(settings.authorizationStatus)
                    if settings.authorizationStatus == .denied {
                        BackgroundCompletionNotifications.setEnabled(false)
                    }
                    self.refreshNativeUtilityWindows()
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "ChatGPT 回复完成"
            content.body = controller.notificationContextText()
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "chatgpt-swift-completion-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    browserLogger.error("Failed to post background completion notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 ChatGPT Swift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(openAppSettingsAction(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let updateItem = appMenu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdatesAction(_:)), keyEquivalent: "")
        updateItem.target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 ChatGPT Swift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let importCookiesItem = fileMenu.addItem(withTitle: "导入 Cookies...", action: #selector(importCookiesMenu(_:)), keyEquivalent: "")
        importCookiesItem.target = self
        let pasteCookiesItem = fileMenu.addItem(withTitle: "粘贴 Cookies...", action: #selector(pasteCookiesMenu(_:)), keyEquivalent: "")
        pasteCookiesItem.target = self
        let exportCookiesItem = fileMenu.addItem(withTitle: "导出 Cookies...", action: #selector(exportCookiesMenu(_:)), keyEquivalent: "")
        exportCookiesItem.target = self
        let clearWebsiteDataItem = fileMenu.addItem(withTitle: "焚烧当前空间...", action: #selector(burnCurrentProfileData(_:)), keyEquivalent: "")
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
        editMenu.addItem(NSMenuItem.separator())
        let notesContextItem = editMenu.addItem(withTitle: "插入备忘录上下文", action: #selector(insertNotesContextAction(_:)), keyEquivalent: "")
        notesContextItem.target = self
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let navigationItem = NSMenuItem()
        let navigationMenu = NSMenu(title: "导航")
        let focusPromptItem = navigationMenu.addItem(withTitle: "聚焦输入框", action: #selector(focusPromptAction(_:)), keyEquivalent: "")
        focusPromptItem.target = self
        navigationMenu.addItem(NSMenuItem.separator())
        let backItem = navigationMenu.addItem(withTitle: "后退", action: #selector(goBackAction(_:)), keyEquivalent: "[")
        backItem.target = self
        let forwardItem = navigationMenu.addItem(withTitle: "前进", action: #selector(goForwardAction(_:)), keyEquivalent: "]")
        forwardItem.target = self
        let homeItem = navigationMenu.addItem(withTitle: "回到主页", action: #selector(goHomeAction(_:)), keyEquivalent: "h")
        homeItem.keyEquivalentModifierMask = [.command, .shift]
        homeItem.target = self
        navigationMenu.addItem(NSMenuItem.separator())
        let reloadItem = navigationMenu.addItem(withTitle: "重新加载", action: #selector(reloadAction(_:)), keyEquivalent: "r")
        reloadItem.target = self
        navigationMenu.addItem(NSMenuItem.separator())
        let openInBrowserItem = navigationMenu.addItem(withTitle: "在系统浏览器打开", action: #selector(openCurrentURLInBrowserAction(_:)), keyEquivalent: "o")
        openInBrowserItem.keyEquivalentModifierMask = [.command, .option]
        openInBrowserItem.target = self
        let copyURLItem = navigationMenu.addItem(withTitle: "复制当前页链接", action: #selector(copyCurrentURLAction(_:)), keyEquivalent: "c")
        copyURLItem.keyEquivalentModifierMask = [.command, .shift]
        copyURLItem.target = self
        navigationItem.submenu = navigationMenu
        mainMenu.addItem(navigationItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        viewMenu.addItem(withTitle: "放大", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "缩小", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "实际大小", action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let privacyItem = NSMenuItem()
        let privacyMenu = NSMenu(title: "隐私")
        privacyMenu.delegate = self
        privacyMenu.autoenablesItems = false
        rebuildPrivacyMenu(privacyMenu)
        privacyItem.submenu = privacyMenu
        self.privacyMenu = privacyMenu
        mainMenu.addItem(privacyItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        let diagnosticsItem = helpMenu.addItem(withTitle: "诊断…", action: #selector(showDiagnosticsWindow(_:)), keyEquivalent: "")
        diagnosticsItem.target = self
        let releaseItem = helpMenu.addItem(withTitle: "打开发行页", action: #selector(openReleasePageAction(_:)), keyEquivalent: "")
        releaseItem.target = self
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func installKeyboardZoomShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let controller = BrowserWindowController.keyWindowController() else {
                return event
            }

            if Self.isCommandShiftShortcut(event),
               event.charactersIgnoringModifiers?.lowercased() == "h" {
                controller.goHome(nil)
                return nil
            }

            guard Self.isCommandOnlyShortcut(event) else {
                return event
            }

            switch event.charactersIgnoringModifiers {
            case ",":
                self?.openAppSettingsAction(nil)
                return nil
            case "[":
                controller.goBack(nil)
                return nil
            case "]":
                controller.goForward(nil)
                return nil
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

    private static func isCommandShiftShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command)
            && flags.contains(.shift)
            && !flags.contains(.control)
            && !flags.contains(.option)
    }

    @objc func openAppSettingsAction(_ sender: Any?) {
        let controller: AppSettingsWindowController
        if let existing = settingsWindowController {
            controller = existing
        } else {
            controller = AppSettingsWindowController(
                state: makeAppSettingsState(),
                callbacks: AppSettingsCallbacks(
                    setPromptDraftRestore: { [weak self] enabled in
                        self?.setPromptDraftRestoreFromSettings(enabled)
                    },
                    setBackgroundCompletionNotifications: { [weak self] enabled in
                        self?.setBackgroundCompletionNotificationsFromSettings(enabled)
                    },
                    setWebRTCProtection: { [weak self] enabled in
                        self?.setWebRTCProtectionFromSettings(enabled)
                    },
                    setThirdPartyLinksInApp: { [weak self] enabled in
                        self?.setThirdPartyLinksInAppFromSettings(enabled)
                    },
                    setEnhancedPrivacy: { [weak self] enabled in
                        self?.setEnhancedPrivacyFromSettings(enabled)
                    },
                    openNotesAutomationPrivacy: { [weak self] in
                        self?.openNotesAutomationPrivacy()
                    },
                    showDiagnostics: { [weak self] in
                        self?.showDiagnosticsWindow(nil)
                    },
                    checkForUpdates: { [weak self] in
                        self?.checkForUpdates(showAlert: true)
                    },
                    openReleasePage: { [weak self] in
                        self?.openReleasePage()
                    }
                )
            )
            settingsWindowController = controller
        }

        controller.update(state: makeAppSettingsState())
        if let window = controller.window {
            if !window.isVisible {
                window.center()
            }
            window.makeKeyAndOrderFront(sender)
        } else {
            controller.showWindow(sender)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showPreferencesWindow(_ sender: Any?) {
        openAppSettingsAction(sender)
    }

    @objc private func showDiagnosticsWindow(_ sender: Any?) {
        let controller: DiagnosticsWindowController
        if let existing = diagnosticsWindowController {
            controller = existing
        } else {
            controller = DiagnosticsWindowController(
                state: makeDiagnosticsState(),
                callbacks: AppDiagnosticsCallbacks(
                    refresh: { [weak self] in
                        self?.makeDiagnosticsState() ?? AppDiagnosticsState(generatedAt: "unknown", report: "AppDelegate unavailable")
                    },
                    exportPackage: { [weak self] state in
                        self?.exportDiagnosticsPackage(state)
                    }
                )
            )
            diagnosticsWindowController = controller
        }

        controller.update(state: makeDiagnosticsState())
        controller.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdatesAction(_ sender: Any?) {
        checkForUpdates(showAlert: true)
    }

    @objc private func openReleasePageAction(_ sender: Any?) {
        openReleasePage()
    }

    private func setWebRTCProtectionFromSettings(_ enabled: Bool) {
        guard PrivacySettings.isWebRTCProtectionEnabled() != enabled else {
            refreshNativeUtilityWindows()
            return
        }
        PrivacySettings.setWebRTCProtectionEnabled(enabled)
        updateWebRTCProtectionMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
        refreshNativeUtilityWindows()
    }

    private func setPromptDraftRestoreFromSettings(_ enabled: Bool) {
        PromptDraftStore.setRestoreEnabled(enabled)
        if !enabled {
            PromptDraftStore.clearDraft(for: ProfileStore.currentProfileID())
        }
        mainController?.restorePromptDraftIfAvailable(reason: "settings toggled")
        refreshNativeUtilityWindows()
    }

    private func setBackgroundCompletionNotificationsFromSettings(_ enabled: Bool) {
        if !enabled {
            BackgroundCompletionNotifications.setEnabled(false)
            refreshNativeUtilityWindows()
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error {
                    BackgroundCompletionNotifications.setEnabled(false)
                    self?.notificationPermissionStatus = "请求失败：\(error.localizedDescription)"
                    self?.presentError("通知权限请求失败：\(error.localizedDescription)")
                } else {
                    BackgroundCompletionNotifications.setEnabled(granted)
                    self?.notificationPermissionStatus = granted ? "已授权" : "未授权"
                    if !granted {
                        self?.presentError("系统没有授予通知权限。可以到系统设置的通知里为 ChatGPT Swift 打开。")
                    }
                }
                self?.refreshNativeUtilityWindows()
            }
        }
    }

    private func setThirdPartyLinksInAppFromSettings(_ enabled: Bool) {
        PrivacySettings.setKeepThirdPartyLinksInApp(enabled)
        refreshNativeUtilityWindows()
    }

    private func setEnhancedPrivacyFromSettings(_ enabled: Bool) {
        let profileID = ProfileStore.currentProfileID()
        guard ProfileStore.isEnhancedPrivacyEnabled(for: profileID) != enabled else {
            refreshNativeUtilityWindows()
            return
        }
        ProfileStore.setEnhancedPrivacyEnabled(enabled, for: profileID)
        updateEnhancedPrivacyMenuItem()
        rebuildMainController(initialURL: mainController?.currentURL())
        refreshNativeUtilityWindows()
    }

    private func refreshNativeUtilityWindows() {
        settingsWindowController?.update(state: makeAppSettingsState())
        diagnosticsWindowController?.update(state: makeDiagnosticsState())
    }

    private func openNotesAutomationPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openReleasePage() {
        NSWorkspace.shared.open(releasePageURL)
    }

    private func checkForUpdates(showAlert: Bool) {
        updateCheckStatus = "正在检查 GitHub Releases…"
        refreshNativeUtilityWindows()

        var request = URLRequest(url: latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ChatGPTSwiftWeb", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if let error {
                    self.updateCheckStatus = "检查失败：\(error.localizedDescription)"
                    self.refreshNativeUtilityWindows()
                    if showAlert {
                        self.presentUpdateCheckResult(self.updateCheckStatus, canOpenReleasePage: true)
                    }
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard statusCode == 200, let data else {
                    self.updateCheckStatus = "没有可读取的 GitHub Release feed（HTTP \(statusCode)）。"
                    self.refreshNativeUtilityWindows()
                    if showAlert {
                        self.presentUpdateCheckResult(self.updateCheckStatus, canOpenReleasePage: true)
                    }
                    return
                }

                do {
                    let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                    let title = release.name?.isEmpty == false ? release.name! : release.tagName
                    let date = release.publishedAt?.isEmpty == false ? "，发布时间 \(release.publishedAt!)" : ""
                    self.updateCheckStatus = "最新发布：\(title)\(date)。当前版本：\(Self.appVersionText())。自动安装更新尚未启用。"
                    self.refreshNativeUtilityWindows()
                    if showAlert {
                        self.presentUpdateCheckResult(self.updateCheckStatus, canOpenReleasePage: release.htmlURL != nil)
                    }
                } catch {
                    self.updateCheckStatus = "Release feed 解析失败：\(error.localizedDescription)"
                    self.refreshNativeUtilityWindows()
                    if showAlert {
                        self.presentUpdateCheckResult(self.updateCheckStatus, canOpenReleasePage: true)
                    }
                }
            }
        }.resume()
    }

    private func presentUpdateCheckResult(_ message: String, canOpenReleasePage: Bool) {
        let alert = NSAlert()
        alert.messageText = "检查更新"
        alert.informativeText = message
        alert.alertStyle = .informational
        if canOpenReleasePage {
            alert.addButton(withTitle: "打开发行页")
            alert.addButton(withTitle: "关闭")
            if alert.runModal() == .alertFirstButtonReturn {
                openReleasePage()
            }
        } else {
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    private func makeAppSettingsState() -> AppSettingsState {
        let profile = ProfileStore.currentProfile()
        let startupID = ProfileStore.startupProfileID()
        let startupName = ProfileStore.loadProfiles().first(where: { $0.id == startupID })?.name ?? "默认"
        let fingerprintName = ProfileStore.fingerprint(for: profile.id)?.displayName ?? "默认 Safari（不混淆）"
        let isolation: String
        if #available(macOS 14.0, *) {
            isolation = profile.id == defaultProfileID ? "内置 WebView 数据仓库" : "独立 WKWebsiteDataStore"
        } else {
            isolation = "当前系统不支持多账号持久数据仓库隔离"
        }

        return AppSettingsState(
            appVersion: Self.appVersionText(),
            currentProfileName: profile.name,
            startupProfileName: startupName,
            homepage: ProfileStore.homepageURL(for: profile.id).absoluteString,
            promptDraftRestoreEnabled: PromptDraftStore.isRestoreEnabled(),
            promptDraftSummary: PromptDraftStore.draftSummary(for: profile.id),
            backgroundCompletionNotificationsEnabled: BackgroundCompletionNotifications.isEnabled(),
            notificationPermissionStatus: notificationPermissionStatus,
            profileIsolation: isolation,
            fingerprintName: fingerprintName,
            enhancedPrivacyEnabled: ProfileStore.isEnhancedPrivacyEnabled(for: profile.id),
            webRTCProtectionEnabled: PrivacySettings.isWebRTCProtectionEnabled(),
            keepThirdPartyLinksInApp: PrivacySettings.keepThirdPartyLinksInApp(),
            notesAutomationStatus: "按需请求；首次插入备忘录上下文时由 macOS 弹出授权。",
            updateStatus: updateCheckStatus,
            distributionStatus: "本地构建已走 codesign；Developer ID 分发需执行 packaging/notarize-dmg.sh 并 stapler。"
        )
    }

    private func makeDiagnosticsState() -> AppDiagnosticsState {
        let generatedAt = Self.timestampString(Date())
        return AppDiagnosticsState(generatedAt: generatedAt, report: makeDiagnosticsReport(generatedAt: generatedAt))
    }

    private func exportDiagnosticsPackage(_ state: AppDiagnosticsState) {
        let panel = NSSavePanel()
        panel.title = "导出诊断包"
        panel.message = "导出当前诊断信息和最近 10 分钟本 App 统一日志。不会导出 cookies、localStorage 或聊天内容。"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "chatgpt-swift-diagnostics-\(Self.filenameTimestamp(Date())).zip"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.writeDiagnosticsPackage(state, to: url)
        }
    }

    private func writeDiagnosticsPackage(_ state: AppDiagnosticsState, to destinationURL: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let fileManager = FileManager.default
                let tempRoot = fileManager.temporaryDirectory
                    .appendingPathComponent("ChatGPTSwiftDiagnostics-\(UUID().uuidString)", isDirectory: true)
                let packageDir = tempRoot.appendingPathComponent("ChatGPT Swift Diagnostics", isDirectory: true)
                try fileManager.createDirectory(at: packageDir, withIntermediateDirectories: true)

                try state.report.write(
                    to: packageDir.appendingPathComponent("diagnostics.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                let manifest = """
                generatedAt: \(state.generatedAt)
                bundleID: \(Bundle.main.bundleIdentifier ?? appBundleIdentifier)
                version: \(Self.appVersionText())
                process: \(ProcessInfo.processInfo.processName)
                note: This package excludes cookies, localStorage, IndexedDB, and chat transcript content.
                """
                try manifest.write(
                    to: packageDir.appendingPathComponent("manifest.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                let logResult = Self.runProcess(
                    executable: "/usr/bin/log",
                    arguments: [
                        "show",
                        "--predicate",
                        "process == \"ChatGPTSwiftWeb\" OR subsystem == \"\(appBundleIdentifier)\"",
                        "--last",
                        "10m",
                        "--style",
                        "compact"
                    ],
                    currentDirectory: nil
                )
                let logText = logResult.output.isEmpty ? logResult.errorOutput : logResult.output
                try logText.write(
                    to: packageDir.appendingPathComponent("recent-log.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                let zipResult = Self.runProcess(
                    executable: "/usr/bin/ditto",
                    arguments: [
                        "-c",
                        "-k",
                        "--sequesterRsrc",
                        "--keepParent",
                        packageDir.lastPathComponent,
                        destinationURL.path
                    ],
                    currentDirectory: tempRoot
                )
                try fileManager.removeItem(at: tempRoot)

                guard zipResult.exitCode == 0 else {
                    throw NSError(
                        domain: "ChatGPTSwiftWeb.DiagnosticsExport",
                        code: Int(zipResult.exitCode),
                        userInfo: [NSLocalizedDescriptionKey: zipResult.errorOutput.isEmpty ? "ditto 打包失败" : zipResult.errorOutput]
                    )
                }

                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                }
            } catch {
                DispatchQueue.main.async {
                    self?.presentError("导出诊断包失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func makeDiagnosticsReport(generatedAt: String) -> String {
        let profile = ProfileStore.currentProfile()
        let fingerprintName = ProfileStore.fingerprint(for: profile.id)?.displayName ?? "默认 Safari（不混淆）"
        let bundle = Bundle.main
        let process = ProcessInfo.processInfo
        var sections: [String] = []

        sections.append(Self.diagnosticSection("App", [
            ("生成时间", generatedAt),
            ("Bundle ID", bundle.bundleIdentifier ?? appBundleIdentifier),
            ("版本", Self.appVersionText()),
            ("进程", "\(process.processName) / pid \(process.processIdentifier)"),
            ("系统", process.operatingSystemVersionString),
            ("Bundle 路径", bundle.bundlePath),
            ("进程启动时间", Self.timestampString(processStartedAt)),
            ("App 完成启动时间", didFinishLaunchingAt.map(Self.timestampString) ?? "未知"),
            ("启动到 didFinishLaunching", Self.durationString(from: processStartedAt, to: didFinishLaunchingAt)),
            ("当前运行时长", Self.durationString(from: processStartedAt, to: Date())),
            ("上次运行", previousRunSummary),
        ]))

        sections.append(Self.diagnosticSection("账号空间 / 隐私", [
            ("当前空间", profile.name),
            ("首页", ProfileStore.homepageURL(for: profile.id).absoluteString),
            ("启动默认空间", ProfileStore.startupProfileID()),
            ("本机草稿恢复", PromptDraftStore.isRestoreEnabled() ? "开启" : "关闭"),
            ("当前空间草稿", PromptDraftStore.draftSummary(for: profile.id)),
            ("后台完成通知", BackgroundCompletionNotifications.isEnabled() ? "开启" : "关闭"),
            ("通知权限", notificationPermissionStatus),
            ("指纹预设", fingerprintName),
            ("增强隐私模式", ProfileStore.isEnhancedPrivacyEnabled(for: profile.id) ? "开启" : "关闭"),
            ("WebRTC 防护", PrivacySettings.isWebRTCProtectionEnabled() ? "开启" : "关闭"),
            ("第三方链接在 App 内打开", PrivacySettings.keepThirdPartyLinksInApp() ? "开启" : "关闭"),
        ]))

        if let controller = mainController {
            sections.append(controller.diagnosticsReport())
        } else {
            sections.append(Self.diagnosticSection("WebView", [("状态", "mainController 不存在")]))
        }

        sections.append(Self.diagnosticSection("分发", [
            ("更新检查", updateCheckStatus),
            ("发行页", releasePageURL.absoluteString),
            ("notarization", "运行时不能证明 DMG 是否已 stapled；用 packaging/notarize-dmg.sh / spctl / stapler 验证。"),
        ]))

        return sections.joined(separator: "\n\n")
    }

    private static func appVersionText() -> String {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?):
            return "\(short) (\(build))"
        case let (short?, nil):
            return short
        default:
            return "开发构建"
        }
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func durationString(from start: Date, to end: Date?) -> String {
        guard let end else {
            return "未知"
        }
        return String(format: "%.3fs", max(0, end.timeIntervalSince(start)))
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL?
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessRunResult(exitCode: 127, output: "", errorOutput: error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(exitCode: process.terminationStatus, output: output, errorOutput: errorOutput)
    }

    private static func diagnosticSection(_ title: String, _ rows: [(String, String)]) -> String {
        let body = rows.map { key, value in
            "\(key): \(value)"
        }.joined(separator: "\n")
        return "[\(title)]\n\(body)"
    }

    @objc private func importCookiesMenu(_ sender: Any?) {
        mainController?.importCookiesFromPanel()
    }

    @objc private func pasteCookiesMenu(_ sender: Any?) {
        mainController?.pasteCookiesFromDialog()
    }

    @objc private func exportCookiesMenu(_ sender: Any?) {
        mainController?.exportCookiesViaPanel()
    }

    @objc private func burnCurrentProfileData(_ sender: Any?) {
        mainController?.confirmBurnCurrentProfileData { [weak self] in
            guard let self else {
                return
            }
            let profileID = ProfileStore.currentProfileID()
            ProfileStore.disableFingerprint(for: profileID)
            self.rebuildMainController()
            self.presentInfo("已焚烧当前空间浏览现场，并恢复为默认 Safari 指纹。空间名称、首页和增强隐私设置已保留。")
        }
    }

    @objc private func toggleWebRTCProtection(_ sender: Any?) {
        let enabled = !PrivacySettings.isWebRTCProtectionRequested()
        PrivacySettings.setWebRTCProtectionEnabled(enabled)
        updateWebRTCProtectionMenuItem()

        let currentURL = mainController?.currentURL()
        rebuildMainController(initialURL: currentURL)
    }

    @objc private func toggleThirdPartyLinksInApp(_ sender: NSMenuItem) {
        let enabled = !PrivacySettings.keepThirdPartyLinksInApp()
        PrivacySettings.setKeepThirdPartyLinksInApp(enabled)
        sender.state = enabled ? .on : .off
    }

    @objc private func showPrivacyStatus(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        let fingerprint = ProfileStore.fingerprint(for: profile.id)
        let fingerprintText = fingerprint?.displayName ?? "默认 Safari（不混淆）"
        let enhancedPrivacyText = ProfileStore.isEnhancedPrivacyEnabled(for: profile.id) ? "开启" : "关闭"
        let webRTCText = PrivacySettings.isWebRTCProtectionEnabled() ? "开启" : "关闭"
        let assessment = FingerprintCatalog.privacyAssessment(
            fingerprint: fingerprint,
            enhancedPrivacyEnabled: ProfileStore.isEnhancedPrivacyEnabled(for: profile.id),
            webRTCProtectionEnabled: PrivacySettings.isWebRTCProtectionEnabled()
        )
        let isolation: String
        if #available(macOS 14.0, *) {
            isolation = profile.id == defaultProfileID ? "内置空间使用本 App 默认 WebView 数据仓库" : "当前空间使用独立 WKWebsiteDataStore"
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
        Accept-Language：JS 层覆盖；本 App 发起的顶层导航请求会带当前空间语言头，子资源仍由 WKWebView / 系统决定
        Tracker blocking：未启用

        一致性评估：
        \(assessment)
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
            self?.rebuildMainController(initialURL: url)
        }
    }

    @objc private func goBackAction(_ sender: Any?) {
        BrowserWindowController.keyWindowController()?.goBack(sender)
    }

    @objc private func goForwardAction(_ sender: Any?) {
        BrowserWindowController.keyWindowController()?.goForward(sender)
    }

    @objc private func goHomeAction(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        rebuildMainController(initialURL: ProfileStore.homepageURL(for: profile.id))
    }

    @objc private func reloadAction(_ sender: Any?) {
        guard let controller = BrowserWindowController.keyWindowController() ?? mainController else {
            return
        }
        controller.reload(sender)
    }

    @objc private func openCurrentURLInBrowserAction(_ sender: Any?) {
        (BrowserWindowController.keyWindowController() ?? mainController)?.openCurrentURLInSystemBrowser(sender)
    }

    @objc private func copyCurrentURLAction(_ sender: Any?) {
        guard let url = (BrowserWindowController.keyWindowController() ?? mainController)?.currentURL() else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
            self.rebuildMainController(initialURL: url)
        }
    }

    @objc private func resetProfileHomepageAction(_ sender: Any?) {
        let profile = ProfileStore.currentProfile()
        ProfileStore.removeHomepage(for: profile.id)
        rebuildMainController(initialURL: ProfileStore.homepageURL(for: profile.id))
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
        updateEnhancedPrivacyMenuItem()
        rebuildMainController()
    }

    @objc private func setCurrentProfileAsDefaultAction(_ sender: Any?) {
        setProfileAsDefault(id: ProfileStore.currentProfileID())
    }

    @objc private func setProfileAsDefaultAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        setProfileAsDefault(id: id)
    }

    private func setProfileAsDefault(id: String) {
        let previousCurrentID = ProfileStore.currentProfileID()
        guard ProfileStore.setStartupProfileID(id) else {
            presentError("设置启动默认空间失败：找不到目标空间。")
            return
        }
        profilesMenu.map(rebuildProfilesMenu(_:))
        if previousCurrentID != id {
            rebuildMainController()
        }
        let profileName = ProfileStore.loadProfiles().first(where: { $0.id == id })?.name ?? "目标空间"
        presentInfo("已将「\(profileName)」设为启动默认空间。")
    }

    @objc private func selectFingerprintPreset(_ sender: NSMenuItem) {
        guard let presetID = sender.representedObject as? String else {
            return
        }
        let profileID = ProfileStore.currentProfileID()
        if presetID == FingerprintCatalog.offPresetID {
            ProfileStore.disableFingerprint(for: profileID)
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
        updateEnhancedPrivacyMenuItem()
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
        能加强：每个空间固定一套 Safari/WebKit 家族指纹，覆盖 UA、navigator、screen、Intl、触控、Canvas、WebGL、AudioContext、GPC、WebRTC 暴露面等常见 JS 层信号。

        推荐做法：日常保持默认 Safari 指纹；只有明确需要隔离特征时，再手动选择或随机化当前空间指纹。不要频繁切换成完全不同设备。

        挡不住：
        - TLS 指纹（JA3 / JA4）：WKWebView 使用系统网络栈，App 无法逐站点修改。
        - HTTP/2 帧顺序和 WebKit 渲染细节：仍会暴露 Safari/WebKit 引擎特征。
        - Worker、字体、GPU、窗口尺寸、行为模式等强风控信号：只能降低暴露，不能保证隐藏。
        - 网络出口：同一出口网络仍可能把不同账号关联到同一环境。

        所以本 App 只做「Safari-only 一致性隐私指纹」，不做 Chrome / Firefox 跨引擎伪装。
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
            ProfileStore.disableFingerprint(for: profile.id)
            ProfileStore.setEnhancedPrivacyEnabled(false, for: profile.id)
            ProfileStore.setCurrentProfileID(profile.id)
            self.rebuildMainController()
        }
    }

    @objc private func renameCurrentProfileAction(_ sender: Any?) {
        let currentID = ProfileStore.currentProfileID()
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
        deleteProfile(id: ProfileStore.currentProfileID())
    }

    @objc private func deleteProfileAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        deleteProfile(id: id)
    }

    private func deleteProfile(id: String) {
        let currentID = ProfileStore.currentProfileID()
        var profiles = ProfileStore.loadProfiles()
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            presentError("删除失败：找不到目标空间。")
            return
        }
        let profile = profiles[idx]
        if profile.id == defaultProfileID {
            deleteDefaultProfile(profile, isCurrent: currentID == profile.id)
            return
        }

        let alert = NSAlert()
        alert.messageText = "删除账号空间 \"\(profile.name)\"？"
        let startupDefaultNote = profile.id == ProfileStore.startupProfileID()
            ? "\n\n此空间当前是启动默认空间；删除后启动默认会自动回到内置空间。"
            : ""
        alert.informativeText = "本空间的所有 cookie、登录态、缓存与本地存储将被永久删除。其他空间不受影响。\(startupDefaultNote)"
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
        ProfileStore.clearStartupProfileIfNeeded(profile.id)
        profilesMenu.map(rebuildProfilesMenu(_:))
        if currentID == profile.id {
            ProfileStore.setCurrentProfileID(defaultProfileID)
            rebuildMainController()
        }
        if #available(macOS 14.0, *), let uuid = UUID(uuidString: profile.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                WKWebsiteDataStore.remove(forIdentifier: uuid) { _ in }
            }
        }
    }

    private func deleteDefaultProfile(_ profile: WebProfile, isCurrent: Bool) {
        let alert = NSAlert()
        alert.messageText = "删除内置空间 \"\(profile.name)\"？"
        alert.informativeText = "内置空间使用本 App 的默认 WebView 数据仓库。删除后会清空它的 cookies、登录态、缓存与本地存储，并把名称、首页、指纹和增强隐私设置重建为一个全新的内置空间。其他独立空间不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除并新建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        WebsiteDataCleaner.removeAllData(from: WKWebsiteDataStore.default()) { [weak self] in
            guard let self else {
                return
            }
            ProfileStore.resetDefaultProfile()
            ProfileStore.setCurrentProfileID(isCurrent ? defaultProfileID : ProfileStore.currentProfileID())
            self.profilesMenu.map(self.rebuildProfilesMenu(_:))
            if isCurrent {
                self.rebuildMainController()
            }
            self.presentInfo("已删除并重新创建内置空间。")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === profilesMenu {
            rebuildProfilesMenu(menu)
        } else if menu === privacyMenu {
            rebuildPrivacyMenu(menu)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackAction(_:)):
            return BrowserWindowController.keyWindowController()?.canGoBack ?? false
        case #selector(goForwardAction(_:)):
            return BrowserWindowController.keyWindowController()?.canGoForward ?? false
        case #selector(switchToProfile(_:)):
            guard let id = menuItem.representedObject as? String else {
                return false
            }
            return canUseProfile(id) && id != ProfileStore.currentProfileID()
        case #selector(setProfileAsDefaultAction(_:)):
            guard let id = menuItem.representedObject as? String else {
                return false
            }
            return canUseProfile(id) && id != ProfileStore.startupProfileID()
        case #selector(setCurrentProfileAsDefaultAction(_:)):
            let currentID = ProfileStore.currentProfileID()
            return canUseProfile(currentID) && currentID != ProfileStore.startupProfileID()
        case #selector(addProfileAction(_:)), #selector(importProfileAction(_:)):
            return isProfileIsolationAvailable
        case #selector(renameCurrentProfileAction(_:)):
            return isProfileIsolationAvailable || ProfileStore.currentProfileID() == defaultProfileID
        case #selector(deleteProfileAction(_:)):
            guard let id = menuItem.representedObject as? String else {
                return false
            }
            return canDeleteProfile(id)
        case #selector(deleteCurrentProfileAction(_:)):
            return canDeleteProfile(ProfileStore.currentProfileID())
        default:
            return menuItem.isEnabled
        }
    }

    private func rebuildProfilesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let isolationAvailable = isProfileIsolationAvailable

        let currentID = ProfileStore.currentProfileID()
        let defaultID = ProfileStore.startupProfileID()
        let profiles = ProfileStore.loadProfiles()
        for profile in profiles {
            let title = profileMenuTitle(for: profile, currentID: currentID, startupID: defaultID)
            let profileItem = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let profileMenu = NSMenu(title: profile.name)

            let switchItem = profileMenu.addItem(withTitle: "切换到本空间", action: #selector(switchToProfile(_:)), keyEquivalent: "")
            switchItem.target = self
            switchItem.representedObject = profile.id
            switchItem.isEnabled = canUseProfile(profile.id) && profile.id != currentID

            let setDefaultTitle = profile.id == defaultID ? "已是启动默认空间" : "设为启动默认空间"
            let setDefaultItem = profileMenu.addItem(withTitle: setDefaultTitle, action: #selector(setProfileAsDefaultAction(_:)), keyEquivalent: "")
            setDefaultItem.target = self
            setDefaultItem.representedObject = profile.id
            setDefaultItem.isEnabled = canUseProfile(profile.id) && profile.id != defaultID

            profileMenu.addItem(NSMenuItem.separator())
            let deleteItem = profileMenu.addItem(withTitle: "删除本空间…", action: #selector(deleteProfileAction(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = profile.id
            deleteItem.isEnabled = canDeleteProfile(profile.id)
            if profile.id == defaultProfileID {
                deleteItem.toolTip = "删除内置空间会清空默认 WebView 数据仓库，并立即创建一个全新的内置空间。"
            }

            profileItem.submenu = profileMenu
        }
        menu.addItem(NSMenuItem.separator())
        let setHomeItem = menu.addItem(withTitle: "设置当前空间首页…", action: #selector(setProfileHomepageAction(_:)), keyEquivalent: "")
        setHomeItem.target = self
        let setDefaultTitle = currentID == defaultID ? "已是启动默认空间" : "设为启动默认空间"
        let setDefaultItem = menu.addItem(withTitle: setDefaultTitle, action: #selector(setCurrentProfileAsDefaultAction(_:)), keyEquivalent: "")
        setDefaultItem.target = self
        setDefaultItem.isEnabled = canUseProfile(currentID) && currentID != defaultID
        menu.addItem(NSMenuItem.separator())
        let addItem = menu.addItem(withTitle: "新建账号空间…", action: #selector(addProfileAction(_:)), keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = isolationAvailable
        let exportItem = menu.addItem(withTitle: "导出当前空间配置…", action: #selector(exportCurrentProfileAction(_:)), keyEquivalent: "")
        exportItem.target = self
        let importItem = menu.addItem(withTitle: "导入空间配置…", action: #selector(importProfileAction(_:)), keyEquivalent: "")
        importItem.target = self
        importItem.isEnabled = isolationAvailable
        let renameItem = menu.addItem(withTitle: "重命名当前空间…", action: #selector(renameCurrentProfileAction(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.isEnabled = isolationAvailable || currentID == defaultProfileID
        let deleteItem = menu.addItem(withTitle: "删除当前空间…", action: #selector(deleteCurrentProfileAction(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = canDeleteProfile(currentID)
        if currentID == defaultProfileID {
            deleteItem.toolTip = "删除内置空间会清空默认 WebView 数据仓库，并立即创建一个全新的内置空间。"
        }

        if !isolationAvailable {
            menu.addItem(NSMenuItem.separator())
            let hint = menu.addItem(withTitle: "账号空间隔离需要 macOS 14 或更新版本", action: nil, keyEquivalent: "")
            hint.isEnabled = false
        }
    }

    private var isProfileIsolationAvailable: Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        return false
    }

    private func canUseProfile(_ id: String) -> Bool {
        isProfileIsolationAvailable || id == defaultProfileID
    }

    private func canDeleteProfile(_ id: String) -> Bool {
        id == defaultProfileID || isProfileIsolationAvailable
    }

    private func profileMenuTitle(for profile: WebProfile, currentID: String, startupID: String) -> String {
        var badges: [String] = []
        if profile.id == startupID {
            badges.append("启动默认")
        }
        if profile.id == defaultProfileID {
            badges.append("内置")
        }
        let suffix = badges.isEmpty ? "" : "（\(badges.joined(separator: "，"))）"
        return "\(profile.id == currentID ? "●" : " ") \(profile.name)\(suffix)"
    }

    private func rebuildPrivacyMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let currentID = ProfileStore.currentProfileID()

        let webRTCItem = menu.addItem(withTitle: "启用 WebRTC 防护", action: #selector(toggleWebRTCProtection(_:)), keyEquivalent: "")
        webRTCItem.target = self
        webRTCProtectionItem = webRTCItem
        updateWebRTCProtectionMenuItem()

        let thirdPartyItem = menu.addItem(withTitle: "第三方链接在 App 内打开", action: #selector(toggleThirdPartyLinksInApp(_:)), keyEquivalent: "")
        thirdPartyItem.target = self
        thirdPartyItem.state = PrivacySettings.keepThirdPartyLinksInApp() ? .on : .off

        menu.addItem(NSMenuItem.separator())
        let fingerprintItem = menu.addItem(withTitle: "指纹预设", action: nil, keyEquivalent: "")
        let fingerprintMenu = NSMenu(title: "指纹预设")
        rebuildFingerprintMenu(fingerprintMenu, profileID: currentID)
        fingerprintItem.submenu = fingerprintMenu

        let enhancedItem = menu.addItem(withTitle: "增强隐私模式（当前空间）", action: #selector(toggleEnhancedPrivacy(_:)), keyEquivalent: "")
        enhancedItem.target = self
        enhancedPrivacyItem = enhancedItem
        updateEnhancedPrivacyMenuItem()

        menu.addItem(NSMenuItem.separator())
        let privacyStatusItem = menu.addItem(withTitle: "隐私状态...", action: #selector(showPrivacyStatus(_:)), keyEquivalent: "")
        privacyStatusItem.target = self
        let fingerprintTestItem = menu.addItem(withTitle: "打开指纹检测页", action: #selector(openFingerprintTestPage(_:)), keyEquivalent: "")
        fingerprintTestItem.target = self
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

    /// Resolve the network exit timezone (VPN egress) and align the injected fingerprint to it. With
    /// a cached value the first window is already aligned; the background lookup then keeps the cache
    /// fresh. When the lookup first discovers (or changes) the exit timezone, rebuild the main window
    /// once -- early in launch, before any Cloudflare challenge -- so the new timezone is injected at
    /// document start. Later exit changes (e.g. switching VPN nodes) apply on the next new window
    /// rather than yanking the current page out from under an in-progress challenge.
    private func primeExitTimezoneAlignment() {
        GeoIPResolver.refresh { [weak self] timezone, changed in
            guard let self, changed, timezone != nil, !self.didApplyLaunchGeoIP else {
                return
            }
            self.didApplyLaunchGeoIP = true
            self.rebuildMainController(initialURL: self.mainController?.currentURL())
        }
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
        updateEnhancedPrivacyMenuItem()
    }

    func recoverBlankContent(in controller: BrowserWindowController) {
        if controller === mainController {
            rebuildMainController(initialURL: controller.currentURL())
        } else {
            controller.hardReload(ignoringCache: true)
        }
    }

    private func mainWindowTitle(for profile: WebProfile) -> String {
        if profile.id == defaultProfileID && profile.name == "默认" {
            return "ChatGPT Swift"
        }
        return "ChatGPT Swift · \(profile.name)"
    }

    private func ensureIsolationAvailable() -> Bool {
        if #available(macOS 14.0, *) {
            return true
        }
        let alert = NSAlert()
        alert.messageText = "无法新建账号空间"
        alert.informativeText = "多账号隔离需要 macOS 14 或更新版本。当前系统版本只支持内置空间和无痕窗口。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
        return false
    }

    private func updateWebRTCProtectionMenuItem() {
        webRTCProtectionItem?.title = PrivacySettings.isWebRTCProtectionEnabled()
            ? "关闭 WebRTC 防护"
            : "启用 WebRTC 防护"
        webRTCProtectionItem?.state = .off
    }

    private func updateEnhancedPrivacyMenuItem() {
        let currentID = ProfileStore.currentProfileID()
        enhancedPrivacyItem?.title = "增强隐私模式（当前空间）"
        enhancedPrivacyItem?.state = ProfileStore.isEnhancedPrivacyEnabled(for: currentID) ? .on : .off
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
        ProfileStore.disableFingerprint(for: newProfile.id)
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
            fingerprintDisabled: ProfileStore.isFingerprintDisabled(for: profile.id),
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
            if let fingerprint = document.fingerprint {
                ProfileStore.setFingerprint(fingerprint, for: profile.id)
            } else {
                ProfileStore.disableFingerprint(for: profile.id)
            }
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}

final class BrowserWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private static var controllers: [BrowserWindowController] = []

    private(set) var window: NSWindow!
    private(set) var webView: WKWebView!
    private var contentContainer: NSView!
    private var statusOverlay: BrowserStatusOverlayView!
    private var childControllers: [BrowserWindowController] = []
    private let isPopup: Bool
    private let persistent: Bool
    private let profileID: String?
    private let controllerCreatedAt = Date()
    private var closeHandler: (() -> Void)?
    var currentZoom: CGFloat = BrowserWindowController.savedWebZoom()
    private var isDisposing = false
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private var renderProbeGeneration = 0
    var lastRenderProbeWasBlank = false
    private var blankRecoveryAttempts = 0
    private var webContentProcessTerminationCount = 0
    private var navigationFailureCount = 0
    private var lastNavigationFailureDescription = "无"
    private var lastRenderProbeSummary = "未运行"
    private var lastBlankRecoverySummary = "无"
    private var lastNavigationStartedAt: Date?
    private var lastNavigationFinishedAt: Date?
    private var firstNavigationFinishedAt: Date?
    private var loadingWatchdogGeneration = 0
    private var currentOverlayMode = BrowserStatusOverlayMode.hidden
    private var isAssistantResponseInProgress = false
    private var lastCompletionObservationSummary = "未运行"
    private var lastBackgroundCompletionNotificationAt: Date?
    var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    var statusLabel: NSTextField?
    var statusContainer: NSView?
    var statusWidthConstraint: NSLayoutConstraint?
    var statusProgressWidthConstraint: NSLayoutConstraint?
    var statusProgressLabelSpacingConstraint: NSLayoutConstraint?
    var progressIndicator: NSProgressIndicator?
    var webViewObservations: [NSKeyValueObservation] = []

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
        } else {
            // Default profile (no fingerprint preset): override the truncated native WKWebView UA
            // with a complete Safari UA. Setting it here on the web view covers the main window,
            // incognito windows, and OAuth popups, which all flow through this initializer.
            webView.customUserAgent = defaultSafariUserAgent
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
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 640)
        window.tabbingMode = .disallowed
        contentContainer = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        contentContainer.autoresizingMask = [.width, .height]
        webView.translatesAutoresizingMaskIntoConstraints = false
        statusOverlay = BrowserStatusOverlayView()
        statusOverlay.primaryAction = { [weak self] in
            self?.reload(nil)
        }
        contentContainer.addSubview(webView)
        contentContainer.addSubview(statusOverlay)
        window.contentView = contentContainer
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),

            statusOverlay.topAnchor.constraint(equalTo: contentContainer.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusOverlay.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
            statusOverlay.widthAnchor.constraint(lessThanOrEqualTo: contentContainer.widthAnchor, constant: -48)
        ])
        configureNativeToolbar()
        if isPopup || restoredFrame == nil {
            window.center()
        }

        observeWebViewState()

        if let initialURL {
            webView.load(Self.privacyRequest(for: initialURL, sourceURL: nil, profileID: profileID))
        }

        updateNativeChromeStatus()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleRenderedContentProbe(reason: "window shown", delay: 1.5)
    }

    @objc func reload(_ sender: Any?) {
        if isShowingBlankContent {
            setStatus("正在恢复空白页面…", showsProgress: true)
            recoverFromBlankContent(reason: "reload action")
            return
        }

        runRenderedContentProbe(reason: "reload action", recoverIfBlank: false) { [weak self] isBlank in
            guard let self else {
                return
            }
            if isBlank {
                self.recoverFromBlankContent(reason: "reload action blank probe")
            } else {
                self.webView.reload()
            }
        }
    }

    /// True when the web view has no live, loaded content — the content process crashed, a provisional
    /// load failed, or nothing ever loaded. In these states `reload()` is a no-op and the view stays blank.
    var isShowingBlankContent: Bool {
        webView.url == nil || webView.backForwardList.currentItem == nil || lastRenderProbeWasBlank
    }

    /// Re-issue a full load (restarting a dead content process) instead of refreshing the back-forward
    /// list. Falls back to the profile homepage when there is no current URL to recover.
    func hardReload(ignoringCache: Bool = false) {
        let target = webView.url ?? ProfileStore.homepageURL(for: profileID ?? defaultProfileID)
        let cachePolicy: URLRequest.CachePolicy = ignoringCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        webView.stopLoading()
        webView.load(Self.privacyRequest(for: target, sourceURL: nil, profileID: profileID, cachePolicy: cachePolicy))
    }

    var canGoBack: Bool {
        webView.canGoBack
    }

    var canGoForward: Bool {
        webView.canGoForward
    }

    @objc func goBack(_ sender: Any?) {
        guard webView.canGoBack else {
            return
        }
        webView.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        guard webView.canGoForward else {
            return
        }
        webView.goForward()
    }

    @objc func goHome(_ sender: Any?) {
        let target = ProfileStore.homepageURL(for: profileID ?? ProfileStore.currentProfileID())
        webView.stopLoading()
        webView.load(Self.privacyRequest(for: target, sourceURL: nil, profileID: profileID))
    }

    @objc func openCurrentURLInSystemBrowser(_ sender: Any?) {
        let target = webView.url ?? ProfileStore.homepageURL(for: profileID ?? ProfileStore.currentProfileID())
        NSWorkspace.shared.open(target)
    }

    func navigate(to url: URL) {
        webView.load(Self.privacyRequest(for: url, sourceURL: webView.url, profileID: profileID))
    }

    func currentURL() -> URL? {
        webView.url
    }

    func notificationContextText() -> String {
        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return webView.url?.host ?? "ChatGPT"
    }

    func diagnosticsReport() -> String {
        let frame = window.frame
        let currentItemURL = webView.backForwardList.currentItem?.url
        let rows = [
            ("窗口标题", window.title),
            ("窗口 frame", "x=\(Int(frame.origin.x)), y=\(Int(frame.origin.y)), w=\(Int(frame.size.width)), h=\(Int(frame.size.height))"),
            ("窗口类型", isPopup ? "弹窗" : "主窗口"),
            ("持久数据", persistent ? "是" : "否"),
            ("空间", profileDisplayName() ?? (persistent ? "默认" : "无痕")),
            ("当前 URL", webView.url.map(Self.loggableURL) ?? "nil"),
            ("历史当前项", currentItemURL.map(Self.loggableURL) ?? "nil"),
            ("标题", webView.title ?? "nil"),
            ("isLoading", webView.isLoading ? "true" : "false"),
            ("estimatedProgress", String(format: "%.3f", webView.estimatedProgress)),
            ("canGoBack / canGoForward", "\(webView.canGoBack) / \(webView.canGoForward)"),
            ("zoom", "\(Int(round(currentZoom * 100)))%"),
            ("isShowingBlankContent", isShowingBlankContent ? "true" : "false"),
            ("lastRenderProbeWasBlank", lastRenderProbeWasBlank ? "true" : "false"),
            ("lastRenderProbe", lastRenderProbeSummary),
            ("blankRecoveryAttempts", "\(blankRecoveryAttempts)"),
            ("lastBlankRecovery", lastBlankRecoverySummary),
            ("nativeStatusOverlay", currentOverlayMode.diagnosticDescription),
            ("webContentProcessTerminationCount", "\(webContentProcessTerminationCount)"),
            ("navigationFailureCount", "\(navigationFailureCount)"),
            ("lastNavigationFailure", lastNavigationFailureDescription),
            ("controllerCreatedAt", Self.diagnosticDateString(controllerCreatedAt)),
            ("firstNavigationFinishedAt", Self.diagnosticDateString(firstNavigationFinishedAt)),
            ("lastNavigationStartedAt", Self.diagnosticDateString(lastNavigationStartedAt)),
            ("lastNavigationFinishedAt", Self.diagnosticDateString(lastNavigationFinishedAt)),
            ("lastNavigationDuration", Self.diagnosticDurationString(from: lastNavigationStartedAt, to: lastNavigationFinishedAt)),
            ("assistantResponseInProgress", isAssistantResponseInProgress ? "true" : "false"),
            ("lastCompletionObservation", lastCompletionObservationSummary),
            ("lastBackgroundCompletionNotificationAt", Self.diagnosticDateString(lastBackgroundCompletionNotificationAt)),
            ("userAgent override", webView.customUserAgent ?? "nil"),
        ]
        return Self.diagnosticSection("WebView", rows)
    }

    func loadFingerprintTestPage() {
        webView.stopLoading()
        webView.loadHTMLString(Self.fingerprintTestShellHTML, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.renderFingerprintReport()
        }
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
        panel.message = "选择 cookie 文件。支持 JSON、Netscape cookies.txt、Cookie/Header String 文本。将导入到当前账号空间。"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json, .plainText, .data]
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

    func pasteCookiesFromDialog() {
        let alert = NSAlert()
        alert.messageText = "粘贴 Cookies"
        alert.informativeText = "支持 JSON、Netscape cookies.txt、Cookie/Header String。内容会导入到当前账号空间。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 240))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.string = NSPasteboard.general.string(forType: .string) ?? ""

        scrollView.documentView = textView
        alert.accessoryView = scrollView

        alert.beginSheetModal(for: window) { [weak self, textView] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.importCookies(fromText: textView.string)
        }

        DispatchQueue.main.async { [weak self, weak textView] in
            guard let textView else {
                return
            }
            self?.window.makeFirstResponder(textView)
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
                try data.write(to: url, options: [.atomic, .completeFileProtection])
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

    func confirmBurnCurrentProfileData(completion: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "焚烧当前空间？"
        alert.informativeText = "这会删除当前空间在本 App WebView 内所有站点的 cookies、缓存、localStorage、IndexedDB、Service Worker 等网站数据，关闭当前空间弹窗，清空页面历史，重建浏览器视图，并恢复默认 Safari 指纹。\n\n会保留：空间名称、首页、增强隐私设置。其他空间不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "焚烧并重建")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }

            self?.burnWebsiteData(completion: completion)
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
        if isDisposing || isPopup || !persistent {
            return true
        }

        persistMainWindowFrame()
        window.orderOut(nil)
        return false
    }

    func dispose() {
        webViewObservations.removeAll()
        childControllers.forEach { $0.window.close() }
        childControllers.removeAll()
        closeHandler = nil
        isDisposing = true
        window.close()
    }

    func windowDidMove(_ notification: Notification) {
        persistMainWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistMainWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleRenderedContentProbe(reason: "window activation", delay: 0.8)
    }

    func windowWillClose(_ notification: Notification) {
        persistMainWindowFrame()
        Self.controllers.removeAll { $0 === self }
        closeHandler?()
    }

    private func showStatusOverlay(_ mode: BrowserStatusOverlayMode) {
        currentOverlayMode = mode
        statusOverlay?.update(mode: mode)
    }

    private func hideStatusOverlayIfTransient() {
        switch currentOverlayMode {
        case .hidden, .failed, .blank:
            return
        case .recovering:
            showStatusOverlay(.hidden)
        }
    }

    private func startLoadingWatchdog(reason: String) {
        loadingWatchdogGeneration += 1
        let generation = loadingWatchdogGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self, weak webView] in
            guard let self,
                  let webView,
                  self.webView === webView,
                  !self.isDisposing,
                  generation == self.loadingWatchdogGeneration,
                  webView.isLoading else {
                return
            }
            let percent = max(1, min(99, Int(webView.estimatedProgress * 100)))
            browserLogger.info("Navigation still loading after watchdog delay (\(reason, privacy: .public)); progress=\(percent, privacy: .public)")
            self.setStatus("加载偏慢 \(percent)%", showsProgress: true)
        }
    }

    private func stopLoadingWatchdog() {
        loadingWatchdogGeneration += 1
    }

    private func invalidateRenderedContentProbes() {
        renderProbeGeneration += 1
    }

    private func scheduleRenderedContentProbe(reason: String, delay: TimeInterval) {
        invalidateRenderedContentProbes()
        let generation = renderProbeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
            guard let self,
                  let webView,
                  self.webView === webView,
                  !self.isDisposing,
                  generation == self.renderProbeGeneration else {
                return
            }
            self.runRenderedContentProbe(reason: reason, generation: generation, recoverIfBlank: true)
        }
    }

    private func runRenderedContentProbe(
        reason: String,
        generation: Int? = nil,
        recoverIfBlank: Bool,
        completion: ((Bool) -> Void)? = nil
    ) {
        webView.evaluateJavaScript(Self.renderedContentProbeScript) { [weak self] result, error in
            guard let self, !self.isDisposing else {
                return
            }
            if let generation, generation != self.renderProbeGeneration {
                return
            }
            if let error {
                browserLogger.debug("Rendered content probe failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                lastRenderProbeSummary = "probe failed: \(error.localizedDescription)"
                completion?(false)
                return
            }
            guard let report = result as? [String: Any] else {
                browserLogger.debug("Rendered content probe returned an unexpected result (\(reason, privacy: .public))")
                lastRenderProbeSummary = "probe returned unexpected result"
                completion?(false)
                return
            }

            let isBlank = Self.boolValue(report["blank"])
            lastRenderProbeWasBlank = isBlank
            let readyState = report["readyState"] as? String ?? "unknown"
            let textLength = Self.intValue(report["textLength"])
            let visibleElements = Self.intValue(report["visibleElements"])
            let bodyChildren = Self.intValue(report["bodyChildren"])
            lastRenderProbeSummary = "blank=\(isBlank), readyState=\(readyState), textLength=\(textLength), visibleElements=\(visibleElements), bodyChildren=\(bodyChildren)"
            updateNativeChromeStatus()

            if isBlank {
                let urlText = Self.loggableURL(webView.url ?? chatGPTURL)
                browserLogger.error("Rendered content probe found blank page (\(reason, privacy: .public)) at \(urlText, privacy: .public); textLength=\(textLength, privacy: .public), visibleElements=\(visibleElements, privacy: .public), bodyChildren=\(bodyChildren, privacy: .public)")
                if recoverIfBlank {
                    setStatus("页面空白，正在自动恢复…", showsProgress: true)
                    showStatusOverlay(.recovering("页面内容探针判定当前页为空，正在重新载入。"))
                    recoverFromBlankContent(reason: reason)
                } else {
                    showStatusOverlay(.blank("页面内容探针判定当前页为空，可以点恢复重新载入。"))
                }
            } else {
                blankRecoveryAttempts = 0
                hideStatusOverlayIfTransient()
            }

            completion?(isBlank)
        }
    }

    private func recoverFromBlankContent(reason: String) {
        guard blankRecoveryAttempts < 2 else {
            browserLogger.error("Blank page recovery suppressed after repeated attempts (\(reason, privacy: .public))")
            setStatus("自动恢复已停止，请手动重新加载", showsProgress: false)
            showStatusOverlay(.blank("自动恢复已达到上限，避免循环刷新；可以手动点恢复再试。"))
            return
        }

        blankRecoveryAttempts += 1
        let urlText = Self.loggableURL(webView.url ?? chatGPTURL)
        lastBlankRecoverySummary = "\(Self.diagnosticDateString(Date())) reason=\(reason), url=\(urlText)"
        browserLogger.error("Recovering blank WebView (\(reason, privacy: .public)) at \(urlText, privacy: .public)")
        setStatus("正在恢复页面…", showsProgress: true)
        showStatusOverlay(.recovering("正在重新载入 \(urlText)。"))

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.recoverBlankContent(in: self)
        } else {
            hardReload(ignoringCache: true)
        }
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastNavigationStartedAt = Date()
        lastRenderProbeWasBlank = false
        invalidateRenderedContentProbes()
        if case .recovering = currentOverlayMode {
            statusOverlay?.update(mode: currentOverlayMode)
        } else {
            showStatusOverlay(.hidden)
        }
        startLoadingWatchdog(reason: "navigation started")
        updateNativeChromeStatus()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if #available(macOS 11.3, *), navigationAction.shouldPerformDownload {
            // Links flagged for download (e.g. <a download> for large blob/data exports) stream to disk
            // through WKDownload instead of the base64 bridge, so there is no size ceiling.
            decisionHandler(.download)
            return
        }

        let cleanedURL = Self.cleanTrackingParameters(from: url)

        let sourceURL = webView.url

        if navigationAction.targetFrame == nil {
            // New window / window.open / target=_blank. The privacy menu decides whether third-party
            // destinations stay in an app popup or leave through the user's default browser.
            if Self.shouldOpenNewWindowInSystemBrowser(cleanedURL, sourceURL: sourceURL) {
                browserLogger.info("Opening user-clicked third-party URL in system browser: \(Self.loggableURL(cleanedURL), privacy: .public)")
                NSWorkspace.shared.open(cleanedURL)
            } else {
                openPopup(url: cleanedURL)
            }
            decisionHandler(.cancel)
            return
        }

        if Self.shouldOpenInsideApp(cleanedURL, sourceURL: sourceURL) {
            if navigationAction.targetFrame?.isMainFrame == true,
               Self.canRewriteForPrivacy(navigationAction.request),
                Self.needsPrivacyRewrite(request: navigationAction.request, cleanedURL: cleanedURL, sourceURL: webView.url, profileID: profileID) {
                webView.load(Self.privacyRequest(for: cleanedURL, sourceURL: webView.url, profileID: profileID))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        } else if Self.shouldOpenInSystemBrowser(cleanedURL, sourceURL: sourceURL, navigationType: navigationAction.navigationType) {
            browserLogger.info("Opening user-clicked third-party URL in system browser: \(Self.loggableURL(cleanedURL), privacy: .public)")
            NSWorkspace.shared.open(cleanedURL)
            decisionHandler(.cancel)
        } else {
            // Non-trusted but not a deliberate third-party click (e.g. an auto-redirect or scripted
            // navigation): keep it in-app rather than bouncing the whole session to the system browser.
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastNavigationFinishedAt = Date()
        if firstNavigationFinishedAt == nil {
            firstNavigationFinishedAt = lastNavigationFinishedAt
        }
        stopLoadingWatchdog()
        hideStatusOverlayIfTransient()
        webView.pageZoom = currentZoom
        clearInjectedZoomState()
        schedulePromptDraftRestore(reason: "navigation finished")
        scheduleRenderedContentProbe(reason: "navigation finished", delay: 2.0)
        updateNativeChromeStatus()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The render process died (OOM / WebKit fault), leaving a white view. Reload to restart it so the
        // window self-heals instead of stranding the user on a blank page.
        webContentProcessTerminationCount += 1
        browserLogger.error("Web content process terminated; reloading to recover blank view")
        setStatus("渲染进程已重启，正在恢复…", showsProgress: true)
        showStatusOverlay(.recovering("WebKit 渲染进程刚刚重启，正在重新载入当前页面。"))
        let target = webView.url ?? ProfileStore.homepageURL(for: profileID ?? defaultProfileID)
        webView.load(Self.privacyRequest(for: target, sourceURL: nil, profileID: profileID))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Self.isBenignNavigationError(error) else {
            updateNativeChromeStatus()
            return
        }

        // Surface the failure so a blank window after a failed load is diagnosable in the unified log.
        navigationFailureCount += 1
        lastNavigationFailureDescription = error.localizedDescription
        lastRenderProbeWasBlank = true
        stopLoadingWatchdog()
        setStatus("页面加载失败", showsProgress: false)
        showStatusOverlay(.failed(error.localizedDescription))
        browserLogger.error("Provisional navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !Self.isBenignNavigationError(error) else {
            updateNativeChromeStatus()
            return
        }

        navigationFailureCount += 1
        lastNavigationFailureDescription = error.localizedDescription
        lastRenderProbeWasBlank = true
        stopLoadingWatchdog()
        setStatus("页面加载失败", showsProgress: false)
        showStatusOverlay(.failed(error.localizedDescription))
        browserLogger.error("Navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let cleanedURL = Self.cleanTrackingParameters(from: url)
            if Self.shouldOpenNewWindowInSystemBrowser(cleanedURL, sourceURL: webView.url) {
                browserLogger.info("Opening user-clicked third-party popup URL in system browser: \(Self.loggableURL(cleanedURL), privacy: .public)")
                NSWorkspace.shared.open(cleanedURL)
                return nil
            }
        }

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

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择要上传的文件"
        panel.prompt = "上传"
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection

        panel.beginSheetModal(for: window) { response in
            guard response == .OK else {
                completionHandler(nil)
                return
            }

            completionHandler(panel.urls.isEmpty ? nil : panel.urls)
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
        let destination = uniqueDownloadURL(suggestedFilename: suggestedFilename)
        downloadDestinations[ObjectIdentifier(download)] = destination
        completionHandler(destination)
    }

    @available(macOS 11.3, *)
    func downloadDidFinish(_ download: WKDownload) {
        NSSound.beep()
        if let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    @available(macOS 11.3, *)
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        presentError("下载失败：\(error.localizedDescription)")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "promptDraft" {
            handlePromptDraftMessage(message)
            return
        }

        if message.name == "completionState" {
            handleCompletionStateMessage(message)
            return
        }

        guard message.name == "downloadBlob",
              message.frameInfo.isMainFrame,
              Self.isTrustedChatGPTBridgeOrigin(message.frameInfo.securityOrigin),
              let payload = message.body as? [String: Any]
        else {
            return
        }

        if (payload["action"] as? String) == "showImageMenu" {
            showImageDownloadMenu(payload: payload)
            return
        }

        saveImageDownloadPayload(payload)
    }

    private func handlePromptDraftMessage(_ message: WKScriptMessage) {
        guard persistent,
              PromptDraftStore.isRestoreEnabled(),
              message.frameInfo.isMainFrame,
              Self.isTrustedChatGPTBridgeOrigin(message.frameInfo.securityOrigin),
              let payload = message.body as? [String: Any],
              let rawText = payload["text"] as? String
        else {
            return
        }

        PromptDraftStore.saveDraft(rawText, profileID: profileID)
    }

    private func handleCompletionStateMessage(_ message: WKScriptMessage) {
        guard persistent,
              message.frameInfo.isMainFrame,
              Self.isTrustedChatGPTBridgeOrigin(message.frameInfo.securityOrigin),
              let payload = message.body as? [String: Any]
        else {
            return
        }

        let isBusy = Self.boolValue(payload["busy"])
        let reason = payload["reason"] as? String ?? "unknown"
        let previous = isAssistantResponseInProgress
        isAssistantResponseInProgress = isBusy
        lastCompletionObservationSummary = "\(Self.diagnosticDateString(Date())) busy=\(isBusy), reason=\(reason)"

        guard previous, !isBusy, BackgroundCompletionNotifications.isEnabled() else {
            return
        }

        guard !NSApp.isActive || window.isKeyWindow == false else {
            return
        }

        lastBackgroundCompletionNotificationAt = Date()
        (NSApp.delegate as? AppDelegate)?.postBackgroundCompletionNotification(from: self)
    }

    private func saveImageDownloadPayload(_ payload: [String: Any]) {
        let suggestedName = (payload["filename"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dataURL = payload["dataURL"] as? String {
            do {
                let filename = Self.imageFilename(
                    suggestedFilename: suggestedName,
                    fallback: "chatgpt-image",
                    mimeType: Self.dataURLMimeType(dataURL)
                )
                let outputURL = uniqueDownloadURL(suggestedFilename: filename)
                let data = try decodeDataURL(dataURL)
                try data.write(to: outputURL, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch {
                presentError("保存下载失败：\(error.localizedDescription)")
            }
            return
        }

        if let rawURL = payload["url"] as? String,
           let url = URL(string: rawURL),
           url.scheme?.lowercased() == "https" {
            downloadRemoteImage(from: url, suggestedFilename: suggestedName)
            return
        }

        presentError("保存下载失败：下载桥没有收到有效图像数据。")
    }

    private func showImageDownloadMenu(payload: [String: Any]) {
        let menu = NSMenu(title: "图像")
        let downloadItem = NSMenuItem(title: "下载图像", action: #selector(downloadImageFromContextMenu(_:)), keyEquivalent: "")
        downloadItem.target = self
        downloadItem.representedObject = payload as NSDictionary
        menu.addItem(downloadItem)

        let copyItem = NSMenuItem(title: "拷贝图像", action: #selector(copyImageFromContextMenu(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.representedObject = payload as NSDictionary
        menu.addItem(copyItem)

        let x = CGFloat((payload["x"] as? Double) ?? Double(webView.bounds.midX))
        let y = CGFloat((payload["y"] as? Double) ?? Double(webView.bounds.midY))
        let point = NSPoint(
            x: min(max(x, 0), webView.bounds.width),
            y: min(max(webView.bounds.height - y, 0), webView.bounds.height)
        )
        menu.popUp(positioning: downloadItem, at: point, in: webView)
    }

    @objc private func downloadImageFromContextMenu(_ sender: NSMenuItem) {
        guard let payload = Self.dictionary(from: sender.representedObject) else {
            return
        }
        saveImageDownloadPayload(payload)
    }

    @objc private func copyImageFromContextMenu(_ sender: NSMenuItem) {
        guard let payload = Self.dictionary(from: sender.representedObject) else {
            return
        }
        copyImagePayload(payload)
    }

    private static func dictionary(from object: Any?) -> [String: Any]? {
        guard let dictionary = object as? NSDictionary else {
            return nil
        }
        return dictionary.reduce(into: [String: Any]()) { result, entry in
            guard let key = entry.key as? String else {
                return
            }
            result[key] = entry.value
        }
    }

    private func copyImagePayload(_ payload: [String: Any]) {
        if let dataURL = payload["dataURL"] as? String {
            do {
                let data = try decodeDataURL(dataURL)
                try copyImageDataToPasteboard(data)
            } catch {
                presentError("拷贝图像失败：\(error.localizedDescription)")
            }
            return
        }

        if let rawURL = payload["url"] as? String,
           let url = URL(string: rawURL),
           url.scheme?.lowercased() == "https" {
            copyRemoteImage(from: url)
            return
        }

        presentError("拷贝图像失败：下载桥没有收到有效图像数据。")
    }

    private func copyImageDataToPasteboard(_ data: Data) throws {
        guard let image = NSImage(data: data) else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 8, userInfo: [NSLocalizedDescriptionKey: "图像数据无法解码"])
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
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

    func restorePromptDraftIfAvailable(reason: String) {
        guard persistent,
              PromptDraftStore.isRestoreEnabled() else {
            return
        }

        let draft = PromptDraftStore.draft(for: profileID)
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        webView.evaluateJavaScript(Self.restorePromptDraftScript(text: draft)) { result, error in
            if let error {
                browserLogger.debug("Prompt draft restore failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                return
            }

            guard let report = result as? [String: Any],
                  Self.boolValue(report["restored"]) else {
                return
            }
            browserLogger.info("Prompt draft restored (\(reason, privacy: .public))")
        }
    }

    private func schedulePromptDraftRestore(reason: String) {
        guard persistent,
              PromptDraftStore.isRestoreEnabled(),
              !PromptDraftStore.draft(for: profileID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        for delay in [0.9, 2.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.webView === webView,
                      !self.isDisposing else {
                    return
                }
                self.restorePromptDraftIfAvailable(reason: reason)
            }
        }
    }

    private func renderFingerprintReport() {
        webView.evaluateJavaScript(Self.fingerprintTestRenderScript) { [weak self] _, error in
            if let error {
                let message = Self.javascriptStringLiteral(error.localizedDescription)
                let script = "document.body.innerHTML = '<main><h1>指纹检测页</h1><p>报告脚本执行失败：' + \(message) + '</p></main>';"
                self?.webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
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
            importCookies(cookies)
        } catch {
            presentError("Cookie 导入失败：\(Self.safeCookieImportMessage(error))")
        }
    }

    private func importCookies(fromText text: String) {
        do {
            let cookies = try Self.parseCookieImport(data: Data(text.utf8))
            importCookies(cookies)
        } catch {
            presentError("Cookie 导入失败：\(Self.safeCookieImportMessage(error))")
        }
    }

    private func importCookies(_ cookies: [HTTPCookie]) {
        let parsedCount = cookies.count
        let importableCookies = cookies.filter { Self.isChatGPTEssentialCookieName($0.name) }
        let skippedCount = parsedCount - importableCookies.count
        guard !importableCookies.isEmpty else {
            presentError("Cookie 导入失败：未发现关键 ChatGPT 登录 cookie。为避免请求头过大导致白屏，已拒绝导入低价值 cookie。")
            return
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        let importedIdentities = Set(importableCookies.map(CookieIdentity.init))

        for cookie in importableCookies {
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else {
                return
            }

            self.pruneOversizedChatGPTCookies(in: cookieStore) { [weak self] prunedCount in
                guard let self else {
                    return
                }

                cookieStore.getAllCookies { [weak self] storedCookies in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else {
                            return
                        }

                        let storedIdentities = Set(storedCookies.map(CookieIdentity.init))
                        let missingCookies = importableCookies.filter { !storedIdentities.contains(CookieIdentity($0)) }
                        let storedCount = importedIdentities.intersection(storedIdentities).count
                        let importedLoginNames = Set(importableCookies.map(\.name).filter(Self.isChatGPTEssentialCookieName))
                        let storedLoginNames = Set(storedCookies.map(\.name).filter { importedLoginNames.contains($0) })
                        let missingLoginNames = importedLoginNames.subtracting(storedLoginNames).sorted()
                        let profileName = self.profileDisplayName() ?? "默认"

                        var lines = [
                            "当前空间：\(profileName)",
                            "已解析 \(parsedCount) 个 cookie，导入 \(importableCookies.count) 个关键 cookie，跳过 \(skippedCount) 个低价值 cookie；WebKit 当前可读到 \(storedCount)/\(importedIdentities.count) 个目标 cookie。"
                        ]

                        let hasSessionCookie = importedLoginNames.contains(where: Self.isChatGPTSessionCookieName)
                        if !hasSessionCookie {
                            lines.append("提示：本次内容没有 ChatGPT session-token，通常不能直接免登录。")
                        } else if missingLoginNames.isEmpty {
                            lines.append("关键登录 cookie 已写入：\(importedLoginNames.sorted().joined(separator: ", "))")
                        } else {
                            lines.append("缺失关键登录 cookie：\(missingLoginNames.joined(separator: ", "))")
                        }

                        if prunedCount > 0 {
                            lines.append("已清理 \(prunedCount) 个低价值旧 cookie，避免请求头过大。")
                        }

                        if !missingCookies.isEmpty {
                            let names = missingCookies.prefix(8).map(\.name).joined(separator: ", ")
                            let suffix = missingCookies.count > 8 ? " 等 \(missingCookies.count) 个" : ""
                            lines.append("未写入：\(names)\(suffix)")
                        }

                        lines.append("正在刷新页面。")
                        self.presentAlert(lines.joined(separator: "\n"), style: missingCookies.isEmpty && missingLoginNames.isEmpty ? .informational : .warning)
                        self.webView.reload()
                    }
                }
            }
        }
    }

    private func pruneOversizedChatGPTCookies(in cookieStore: WKHTTPCookieStore, completion: @escaping (Int) -> Void) {
        cookieStore.getAllCookies { storedCookies in
            let finish: (Int) -> Void = { count in
                DispatchQueue.main.async {
                    completion(count)
                }
            }
            let headerBytes = storedCookies
                .filter(Self.isChatGPTRelatedCookie)
                .reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 2 }
            guard headerBytes > maximumChatGPTCookieHeaderBytes else {
                finish(0)
                return
            }

            let removableCookies = storedCookies
                .filter(Self.isChatGPTRelatedCookie)
                .filter { !Self.isChatGPTEssentialCookieName($0.name) }
            guard !removableCookies.isEmpty else {
                finish(0)
                return
            }

            let group = DispatchGroup()
            for cookie in removableCookies {
                group.enter()
                cookieStore.delete(cookie) {
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                completion(removableCookies.count)
            }
        }
    }

    private static func isChatGPTRelatedCookie(_ cookie: HTTPCookie) -> Bool {
        isAllowedCookieDomain(cookie.domain)
    }

    fileprivate static func isAllowedCookieDomain(_ domain: String) -> Bool {
        var normalized = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        return normalized == "chatgpt.com"
            || normalized.hasSuffix(".chatgpt.com")
            || normalized == "openai.com"
            || normalized.hasSuffix(".openai.com")
    }

    fileprivate static func isChatGPTEssentialCookieName(_ name: String) -> Bool {
        name.hasPrefix("__Secure-next-auth.session-token")
            || name == "cf_clearance"
            || name == "__Secure-oai-is"
            || name == "oai-sc"
    }

    fileprivate static func isChatGPTSessionCookieName(_ name: String) -> Bool {
        name.hasPrefix("__Secure-next-auth.session-token")
    }

    private func downloadRemoteImage(from url: URL, suggestedFilename: String?) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else {
                return
            }

            if let error {
                DispatchQueue.main.async {
                    self.presentError("保存下载失败：\(error.localizedDescription)")
                }
                return
            }

            guard let data, !data.isEmpty else {
                DispatchQueue.main.async {
                    self.presentError("保存下载失败：图像数据为空。")
                }
                return
            }

            guard data.count <= maximumBridgeDownloadBytes else {
                DispatchQueue.main.async {
                    self.presentError("保存下载失败：图像超过 \(maximumBridgeDownloadBytes / 1024 / 1024) MB。")
                }
                return
            }

            let filename = Self.remoteImageFilename(
                suggestedFilename: suggestedFilename,
                sourceURL: url,
                mimeType: response?.mimeType
            )
            let outputURL = self.uniqueDownloadURL(suggestedFilename: filename)

            do {
                try data.write(to: outputURL, options: .atomic)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentError("保存下载失败：\(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private func copyRemoteImage(from url: URL) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else {
                return
            }

            if let error {
                DispatchQueue.main.async {
                    self.presentError("拷贝图像失败：\(error.localizedDescription)")
                }
                return
            }

            guard let data, !data.isEmpty else {
                DispatchQueue.main.async {
                    self.presentError("拷贝图像失败：图像数据为空。")
                }
                return
            }

            guard data.count <= maximumBridgeDownloadBytes else {
                DispatchQueue.main.async {
                    self.presentError("拷贝图像失败：图像超过 \(maximumBridgeDownloadBytes / 1024 / 1024) MB。")
                }
                return
            }

            do {
                try self.copyImageDataToPasteboard(data)
            } catch {
                DispatchQueue.main.async {
                    self.presentError("拷贝图像失败：\(error.localizedDescription)")
                }
            }
        }.resume()
    }

    private static func remoteImageFilename(suggestedFilename: String?, sourceURL: URL, mimeType: String?) -> String {
        imageFilename(
            suggestedFilename: suggestedFilename,
            fallback: sourceURL.lastPathComponent.isEmpty ? "chatgpt-image" : sourceURL.lastPathComponent,
            mimeType: mimeType
        )
    }

    private static func imageFilename(suggestedFilename: String?, fallback: String, mimeType: String?) -> String {
        let rawName = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        var filename = rawName?.isEmpty == false ? rawName! : fallback
        if filename.isEmpty || filename == "/" {
            filename = "chatgpt-image"
        }

        if URL(fileURLWithPath: filename).pathExtension.isEmpty,
           let ext = fileExtension(forMIMEType: mimeType) {
            filename += ".\(ext)"
        }

        return filename
    }

    private static func fileExtension(forMIMEType mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        case "image/svg+xml":
            return "svg"
        case "image/avif":
            return "avif"
        case "image/heic":
            return "heic"
        default:
            return nil
        }
    }

    private func burnWebsiteData(completion: @escaping () -> Void) {
        WebsiteDataCleaner.removeAllData(from: webView.configuration.websiteDataStore) { [weak self] in
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
            completion()
        }
    }

    private static func loadCookieExport(from url: URL) throws -> [HTTPCookie] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maximumCookieImportBytes {
            throw cookieImportError("Cookie 文件过大")
        }

        let data = try Data(contentsOf: url)
        return try parseCookieImport(data: data)
    }

    private static func parseCookieImport(data: Data) throws -> [HTTPCookie] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw cookieImportError("Cookie 文件必须是 UTF-8 文本")
        }

        let normalizedText = text.removingUTF8ByteOrderMark()
        let trimmedText = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }

        let exportedCookies: [ExportedBrowserCookie]
        if trimmedText.hasPrefix("[") || trimmedText.hasPrefix("{") {
            exportedCookies = try JSONDecoder().decode(CookieImportDocument.self, from: Data(trimmedText.utf8)).cookies
        } else if looksLikeNetscapeCookieText(trimmedText) {
            exportedCookies = try parseNetscapeCookieText(trimmedText)
        } else {
            exportedCookies = try parseHeaderCookieText(trimmedText)
        }

        let cookies = try exportedCookies.map { try $0.makeCookie() }
        guard !cookies.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }
        return cookies
    }

    private static func looksLikeNetscapeCookieText(_ text: String) -> Bool {
        if text.localizedCaseInsensitiveContains("Netscape HTTP Cookie File") {
            return true
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("#") && !line.hasPrefix("#HttpOnly_") {
                continue
            }
            let fields = splitCookieFields(line, maxSplits: 6)
            return fields.count >= 7 && isNetscapeBoolean(fields[1]) && isNetscapeBoolean(fields[3]) && Int(fields[4]) != nil
        }

        return false
    }

    private static func parseNetscapeCookieText(_ text: String) throws -> [ExportedBrowserCookie] {
        var cookies: [ExportedBrowserCookie] = []

        for (lineIndex, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") {
                continue
            }

            let fields = splitCookieFields(line, maxSplits: 6)
            guard fields.count >= 7 else {
                throw cookieImportError("Netscape 第 \(lineIndex + 1) 行字段不足")
            }
            guard let includeSubdomains = parseNetscapeBoolean(fields[1]) else {
                throw cookieImportError("Netscape 第 \(lineIndex + 1) 行 includeSubdomains 无效")
            }
            guard let secure = parseNetscapeBoolean(fields[3]) else {
                throw cookieImportError("Netscape 第 \(lineIndex + 1) 行 secure 无效")
            }
            guard let expires = Double(fields[4]) else {
                throw cookieImportError("Netscape 第 \(lineIndex + 1) 行 expires 无效")
            }

            let isSession = expires <= 0
            cookies.append(
                ExportedBrowserCookie(
                    domain: fields[0],
                    expirationDate: isSession ? nil : expires,
                    hostOnly: !includeSubdomains,
                    httpOnly: httpOnly,
                    name: fields[5],
                    path: fields[2].isEmpty ? "/" : fields[2],
                    sameSite: nil,
                    secure: secure,
                    session: isSession,
                    value: fields[6]
                )
            )
        }

        guard !cookies.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }
        return cookies
    }

    private static func parseHeaderCookieText(_ text: String) throws -> [ExportedBrowserCookie] {
        var cookies: [ExportedBrowserCookie] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            if let value = stripHeaderPrefix(line, prefix: "Set-Cookie:") {
                cookies.append(try parseSetCookieLine(value))
            } else if let value = stripHeaderPrefix(line, prefix: "Cookie:") {
                cookies.append(contentsOf: try parseCookieHeaderPairs(value))
            } else if looksLikeSetCookieLine(line) {
                cookies.append(try parseSetCookieLine(line))
            } else {
                cookies.append(contentsOf: try parseCookieHeaderPairs(line))
            }
        }

        guard !cookies.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }
        return cookies
    }

    private static func parseCookieHeaderPairs(_ header: String) throws -> [ExportedBrowserCookie] {
        var cookies: [ExportedBrowserCookie] = []

        for segment in header.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else {
                continue
            }

            let name = String(pair[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isSetCookieAttribute(name) else {
                continue
            }

            cookies.append(headerCookie(name: name, value: value))
        }

        guard !cookies.isEmpty else {
            throw cookieImportError("Header String 没有可导入的 cookie")
        }
        return cookies
    }

    private static func parseSetCookieLine(_ line: String) throws -> ExportedBrowserCookie {
        let segments = line.split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = segments.first, let separator = first.firstIndex(of: "=") else {
            throw cookieImportError("Set-Cookie Header 无效")
        }

        let name = String(first[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(first[first.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw cookieImportError("Set-Cookie Header cookie 名称为空")
        }

        var domain = defaultHeaderCookieImportDomain
        var path = "/"
        var secure = false
        var httpOnly = false
        var sameSite: String?
        var session = true
        var expirationDate: Double?

        for attribute in segments.dropFirst() {
            let lower = attribute.lowercased()
            if lower == "secure" {
                secure = true
            } else if lower == "httponly" {
                httpOnly = true
            } else if let separator = attribute.firstIndex(of: "=") {
                let key = String(attribute[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = String(attribute[attribute.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "domain":
                    domain = value
                case "path":
                    path = value.isEmpty ? "/" : value
                case "expires":
                    if let date = parseCookieExpiresDate(value) {
                        expirationDate = date.timeIntervalSince1970
                        session = false
                    }
                case "max-age":
                    if let maxAge = Double(value), maxAge > 0 {
                        expirationDate = Date().addingTimeInterval(maxAge).timeIntervalSince1970
                        session = false
                    }
                case "samesite":
                    sameSite = value
                default:
                    break
                }
            }
        }

        return ExportedBrowserCookie(
            domain: domain,
            expirationDate: expirationDate,
            hostOnly: !domain.hasPrefix("."),
            httpOnly: httpOnly,
            name: name,
            path: path,
            sameSite: sameSite,
            secure: secure,
            session: session,
            value: value
        )
    }

    private static func headerCookie(name: String, value: String) -> ExportedBrowserCookie {
        ExportedBrowserCookie(
            domain: defaultHeaderCookieImportDomain,
            expirationDate: nil,
            hostOnly: false,
            httpOnly: false,
            name: name,
            path: "/",
            sameSite: nil,
            secure: true,
            session: true,
            value: value
        )
    }

    private static func splitCookieFields(_ line: String, maxSplits: Int) -> [String] {
        line.split(
            maxSplits: maxSplits,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        ).map(String.init)
    }

    private static func stripHeaderPrefix(_ line: String, prefix: String) -> String? {
        guard line.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil else {
            return nil
        }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeSetCookieLine(_ line: String) -> Bool {
        let lowerSegments = line.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard lowerSegments.count > 1, lowerSegments.first?.contains("=") == true else {
            return false
        }
        return lowerSegments.dropFirst().contains { segment in
            segment == "secure"
                || segment == "httponly"
                || segment.hasPrefix("domain=")
                || segment.hasPrefix("path=")
                || segment.hasPrefix("expires=")
                || segment.hasPrefix("max-age=")
                || segment.hasPrefix("samesite=")
        }
    }

    private static func isSetCookieAttribute(_ name: String) -> Bool {
        switch name.lowercased() {
        case "domain", "path", "expires", "max-age", "samesite", "secure", "httponly":
            return true
        default:
            return false
        }
    }

    private static func isNetscapeBoolean(_ value: String) -> Bool {
        parseNetscapeBoolean(value) != nil
    }

    private static func parseNetscapeBoolean(_ value: String) -> Bool? {
        switch value.uppercased() {
        case "TRUE":
            return true
        case "FALSE":
            return false
        default:
            return nil
        }
    }

    private static func parseCookieExpiresDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd-MMM-yyyy HH:mm:ss zzz",
            "EEE MMM dd HH:mm:ss yyyy",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
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
        guard dataURL.utf8.count <= maximumBridgeDownloadPayloadCharacters else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 4, userInfo: [NSLocalizedDescriptionKey: "下载内容超过 200MB 限制"])
        }
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 1, userInfo: [NSLocalizedDescriptionKey: "不是有效的 data URL"])
        }

        let header = dataURL[..<commaIndex]
        let body = String(dataURL[dataURL.index(after: commaIndex)...])
        if header.contains(";base64") {
            let estimatedDecodedBytes = (body.utf8.count * 3) / 4
            guard estimatedDecodedBytes <= maximumBridgeDownloadBytes else {
                throw NSError(domain: "ChatGPTSwiftWeb", code: 5, userInfo: [NSLocalizedDescriptionKey: "下载内容超过 200MB 限制"])
            }
            guard let data = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
                throw NSError(domain: "ChatGPTSwiftWeb", code: 2, userInfo: [NSLocalizedDescriptionKey: "Base64 数据无法解码"])
            }
            guard data.count <= maximumBridgeDownloadBytes else {
                throw NSError(domain: "ChatGPTSwiftWeb", code: 6, userInfo: [NSLocalizedDescriptionKey: "下载内容超过 200MB 限制"])
            }
            return data
        }

        guard let decoded = body.removingPercentEncoding,
              let data = decoded.data(using: .utf8)
        else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 3, userInfo: [NSLocalizedDescriptionKey: "文本数据无法解码"])
        }
        guard data.count <= maximumBridgeDownloadBytes else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 7, userInfo: [NSLocalizedDescriptionKey: "下载内容超过 200MB 限制"])
        }
        return data
    }

    private static func dataURLMimeType(_ dataURL: String) -> String? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }
        let header = String(dataURL[..<commaIndex])
        guard header.hasPrefix("data:") else {
            return nil
        }
        let rawMimeType = header
            .dropFirst("data:".count)
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
        return rawMimeType.map(String.init)
    }

    private func uniqueDownloadURL(suggestedFilename: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
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
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet.controlCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "chatgpt-download" : cleaned
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return string == "true" || string == "1"
        }
        return false
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let int = Int(string) {
            return int
        }
        return 0
    }

    private static func isBenignNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func diagnosticSection(_ title: String, _ rows: [(String, String)]) -> String {
        let body = rows.map { key, value in
            "\(key): \(value)"
        }.joined(separator: "\n")
        return "[\(title)]\n\(body)"
    }

    private static func diagnosticDateString(_ date: Date?) -> String {
        guard let date else {
            return "无"
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func diagnosticDurationString(from start: Date?, to end: Date?) -> String {
        guard let start, let end else {
            return "无"
        }
        return String(format: "%.3fs", max(0, end.timeIntervalSince(start)))
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return string
    }

    private static let renderedContentProbeScript = """
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const isChatGPTPage = location.protocol === 'https:' && (
        host === 'chatgpt.com' ||
        host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' ||
        host.endsWith('.chat.openai.com')
      );
      if (!isChatGPTPage || document.readyState !== 'complete') {
        return {
          blank: false,
          readyState: document.readyState,
          href: location.href,
          title: document.title,
          textLength: 0,
          visibleElements: 0,
          bodyChildren: document.body ? document.body.children.length : 0
        };
      }

      const body = document.body;
      const text = body ? String(body.innerText || body.textContent || '').replace(/\\s+/g, ' ').trim() : '';
      const selectors = [
        'main',
        '[role="main"]',
        'form',
        'textarea',
        'input',
        'button',
        'nav',
        'article',
        'section',
        'iframe',
        'canvas',
        'video',
        'img',
        'svg',
        '[data-testid]',
        '[contenteditable="true"]'
      ].join(',');

      let visibleElements = 0;
      if (body) {
        for (const element of body.querySelectorAll(selectors)) {
          try {
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
            const rect = element.getBoundingClientRect();
            if (rect.width > 1 && rect.height > 1) visibleElements += 1;
          } catch (_) {}
        }
      }

      const bodyChildren = body ? body.children.length : 0;
      return {
        blank: !body || (text.length < 8 && visibleElements === 0),
        readyState: document.readyState,
        href: location.href,
        title: document.title,
        textLength: text.length,
        visibleElements,
        bodyChildren
      };
    })()
    """

    private static let promptDraftCaptureScript = """
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const isChatGPTPage = location.protocol === 'https:' && (
        host === 'chatgpt.com' ||
        host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' ||
        host.endsWith('.chat.openai.com')
      );
      if (!isChatGPTPage || window.__chatgptSwiftPromptDraftBridgeInstalled) return;
      window.__chatgptSwiftPromptDraftBridgeInstalled = true;

      const maxLength = 12000;
      const visible = (element) => {
        if (!element) return false;
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
      };
      const firstVisible = (selector) => Array.from(document.querySelectorAll(selector)).find(visible);
      const findComposer = () =>
        firstVisible('textarea[data-testid="prompt-textarea"]') ||
        firstVisible('[contenteditable="true"][data-testid="prompt-textarea"]') ||
        firstVisible('#prompt-textarea') ||
        firstVisible('textarea') ||
        firstVisible('[role="textbox"]') ||
        firstVisible('div[contenteditable="true"]');
      const readText = (element) => {
        if (!element) return '';
        if (element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement) {
          return String(element.value || '').slice(0, maxLength);
        }
        return String(element.innerText || element.textContent || '').slice(0, maxLength);
      };

      let publishTimer = 0;
      const publish = () => {
        window.clearTimeout(publishTimer);
        publishTimer = window.setTimeout(() => {
          try {
            const composer = findComposer();
            window.webkit.messageHandlers.promptDraft.postMessage({ text: readText(composer) });
          } catch (_) {}
        }, 250);
      };

      const attach = () => {
        const composer = findComposer();
        if (!composer || composer.__chatgptSwiftDraftObserved) return;
        composer.__chatgptSwiftDraftObserved = true;
        ['input', 'change', 'keyup', 'paste', 'cut'].forEach((eventName) => {
          composer.addEventListener(eventName, publish, true);
        });
      };

      attach();
      new MutationObserver(attach).observe(document.documentElement, { childList: true, subtree: true });
      window.setInterval(attach, 2500);
    })()
    """

    private static let completionStateObserverScript = """
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const isChatGPTPage = location.protocol === 'https:' && (
        host === 'chatgpt.com' ||
        host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' ||
        host.endsWith('.chat.openai.com')
      );
      if (!isChatGPTPage || window.__chatgptSwiftCompletionObserverInstalled) return;
      window.__chatgptSwiftCompletionObserverInstalled = true;

      const visible = (element) => {
        if (!element) return false;
        const rect = element.getBoundingClientRect();
        const style = window.getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
      };
      const textOf = (element) => String(
        element?.getAttribute?.('aria-label') ||
        element?.getAttribute?.('data-testid') ||
        element?.innerText ||
        element?.textContent ||
        ''
      ).toLowerCase();
      const busyReason = () => {
        const candidates = Array.from(document.querySelectorAll('button, [role="button"], [aria-busy="true"], [data-testid]'))
          .filter(visible);
        for (const element of candidates) {
          const text = textOf(element);
          if (
            text.includes('stop') ||
            text.includes('停止') ||
            text.includes('streaming') ||
            text.includes('generating') ||
            text.includes('回答中') ||
            text.includes('生成中') ||
            text.includes('stop-button')
          ) {
            return text.slice(0, 80) || 'busy-control';
          }
        }
        if (document.querySelector('[aria-busy="true"]')) return 'aria-busy';
        return '';
      };

      let lastBusy = null;
      let publishTimer = 0;
      const publish = () => {
        window.clearTimeout(publishTimer);
        publishTimer = window.setTimeout(() => {
          const reason = busyReason();
          const busy = reason.length > 0;
          if (busy === lastBusy) return;
          lastBusy = busy;
          try {
            window.webkit.messageHandlers.completionState.postMessage({ busy, reason });
          } catch (_) {}
        }, 500);
      };

      publish();
      new MutationObserver(publish).observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['aria-label', 'aria-busy', 'data-testid', 'disabled']
      });
      window.setInterval(publish, 3000);
    })()
    """

    private static func restorePromptDraftScript(text: String) -> String {
        let textLiteral = javascriptStringLiteral(text)
        return """
        (() => {
          const text = \(textLiteral);
          const visible = (element) => {
            if (!element) return false;
            const rect = element.getBoundingClientRect();
            const style = window.getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          };
          const firstVisible = (selector) => Array.from(document.querySelectorAll(selector)).find(visible);
          const composer =
            firstVisible('textarea[data-testid="prompt-textarea"]') ||
            firstVisible('[contenteditable="true"][data-testid="prompt-textarea"]') ||
            firstVisible('#prompt-textarea') ||
            firstVisible('textarea') ||
            firstVisible('[role="textbox"]') ||
            firstVisible('div[contenteditable="true"]');

          if (!composer || !text.trim()) {
            return { restored: false, reason: 'missing composer or draft' };
          }

          const existing = composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement
            ? String(composer.value || '')
            : String(composer.innerText || composer.textContent || '');
          if (existing.trim().length > 0) {
            return { restored: false, reason: 'composer not empty' };
          }

          composer.focus();
          if (composer instanceof HTMLTextAreaElement || composer instanceof HTMLInputElement) {
            const descriptor = Object.getOwnPropertyDescriptor(
              composer instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,
              'value'
            );
            if (descriptor?.set) {
              descriptor.set.call(composer, text);
            } else {
              composer.value = text;
            }
          } else {
            const inserted = document.execCommand('insertText', false, text);
            if (!inserted && !String(composer.innerText || composer.textContent || '').trim()) {
              composer.textContent = text;
            }
          }

          composer.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
          composer.dispatchEvent(new Event('change', { bubbles: true }));
          return { restored: true };
        })()
        """
    }

    private static func makeConfiguration(messageHandler: WKScriptMessageHandler, persistent: Bool, profileID: String?) -> WKWebViewConfiguration {
        let userContentController = WKUserContentController()
        userContentController.add(messageHandler, name: "downloadBlob")
        userContentController.add(messageHandler, name: "promptDraft")
        userContentController.add(messageHandler, name: "completionState")
        let fingerprint = ProfileStore.fingerprint(for: profileID)
        let enhancedPrivacyEnabled = ProfileStore.isEnhancedPrivacyEnabled(for: profileID)
        let webRTCProtectionEnabled = PrivacySettings.isWebRTCProtectionEnabled()
        // 默认(无指纹混淆)仍对齐 VPN 出口时区:不伪造 navigator/screen,只修正 IP/时区错位。
        // 未开 VPN(出口时区==系统时区)或尚未解析到出口时区时为 nil,完全保持原生 Safari 行为。
        let timezoneOnlyScript = fingerprint == nil
            ? FingerprintCatalog.timezoneOnlyScript(systemTimezone: TimeZone.current.identifier)
            : nil
        if fingerprint != nil || enhancedPrivacyEnabled || webRTCProtectionEnabled || timezoneOnlyScript != nil {
            userContentController.addUserScript(WKUserScript(source: nativeShimScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        userContentController.addUserScript(WKUserScript(source: openAIPasskeyFallbackScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        userContentController.addUserScript(WKUserScript(source: downloadBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        userContentController.addUserScript(WKUserScript(source: promptDraftCaptureScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        userContentController.addUserScript(WKUserScript(source: completionStateObserverScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        userContentController.addUserScript(WKUserScript(source: passkeyLimitationNoticeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        if let fingerprint {
            userContentController.addUserScript(WKUserScript(source: FingerprintCatalog.script(for: fingerprint), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let timezoneOnlyScript {
            userContentController.addUserScript(WKUserScript(source: timezoneOnlyScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if enhancedPrivacyEnabled {
            userContentController.addUserScript(WKUserScript(source: privacySignalsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
            let script = FingerprintCatalog.enhancedPrivacyScript(profileID: profileID, fingerprint: fingerprint)
            userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if webRTCProtectionEnabled {
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

    private static func isChatGPTHost(_ host: String) -> Bool {
        host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") || host == "chat.openai.com" || host.hasSuffix(".chat.openai.com")
    }

    private static func isOpenAIAuthHost(_ host: String) -> Bool {
        host == "auth.openai.com" || host.hasSuffix(".auth.openai.com")
            || host == "auth0.openai.com" || host.hasSuffix(".auth0.openai.com")
            || host == "login.openai.com" || host.hasSuffix(".login.openai.com")
    }

    private static func isOpenAISentinelHost(_ host: String) -> Bool {
        host == "sentinel.openai.com"
    }

    private static func isCloudflareChallengeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        return host == "challenges.cloudflare.com"
    }

    private static func isOpenAIFamilyHost(_ host: String) -> Bool {
        host == "openai.com" || host.hasSuffix(".openai.com")
    }

    /// OpenAI's own surfaces beyond the bare ChatGPT host: the marketing/help/platform sites, the
    /// static and user-content CDNs, and Sora. They belong to the same product family, so links into
    /// them open in-app instead of bouncing to the system browser.
    private static func isOpenAIEcosystemHost(_ host: String) -> Bool {
        isOpenAIFamilyHost(host)
            || host == "oaistatic.com" || host.hasSuffix(".oaistatic.com")
            || host == "oaiusercontent.com" || host.hasSuffix(".oaiusercontent.com")
            || host == "sora.com" || host.hasSuffix(".sora.com")
    }

    private static func isTrustedAuthSourceHost(_ host: String) -> Bool {
        isChatGPTHost(host)
            || isOpenAIAuthHost(host)
            || isOpenAIFamilyHost(host)
            || isOAuthProviderHost(host)
    }

    private static func isOAuthProviderHost(_ host: String) -> Bool {
        host == "accounts.google.com"
            || host.hasPrefix("accounts.google.")
            || host == "appleid.apple.com"
            || host == "login.microsoftonline.com"
            || host == "login.live.com"
            || host == "github.com"
            || host == "facebook.com"
            || host.hasSuffix(".facebook.com")
            || host == "twitter.com"
            || host == "x.com"
    }

    private static func isAuthLikeURL(_ url: URL, expanded: Bool = false) -> Bool {
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        let combined = path + "?" + query
        var markers = [
            "oauth",
            "auth",
            "authorize",
            "signin",
            "login",
            "account",
        ]
        if expanded {
            markers.append(contentsOf: [
                "callback",
                "continue",
                "credential",
                "passkey",
                "webauthn",
                "challenge",
                "verify",
                "mfa",
                "sso",
            ])
        }
        return markers.contains { combined.contains($0) }
    }

    private static func isOAuthContinuationHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        guard isOAuthProviderHost(host) else {
            return false
        }
        return isAuthLikeURL(url)
    }

    private static func isAuthContinuationFromTrustedSource(_ url: URL, sourceURL: URL?) -> Bool {
        guard let host = url.host?.lowercased(),
              let sourceHost = sourceURL?.host?.lowercased(),
              isTrustedAuthSourceHost(sourceHost),
              isAuthLikeURL(url, expanded: true)
        else {
            return false
        }

        return isOpenAIFamilyHost(host) || isOAuthProviderHost(host)
    }

    private static func isTrustedChatGPTBridgeOrigin(_ origin: WKSecurityOrigin) -> Bool {
        guard origin.protocol == "https" else {
            return false
        }
        return isChatGPTHost(origin.host.lowercased())
    }

    private static func shouldOpenInsideApp(_ url: URL, sourceURL: URL? = nil) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        if ["about", "blob", "data"].contains(scheme) {
            return true
        }

        guard scheme == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }

        return isChatGPTHost(host)
            || isOpenAIEcosystemHost(host)
            || isOpenAIAuthHost(host)
            || isOpenAISentinelHost(host)
            || isCloudflareChallengeURL(url)
            || isOAuthContinuationHost(url)
            || isAuthContinuationFromTrustedSource(url, sourceURL: sourceURL)
    }

    /// Only a deliberate user click on a genuine third-party https link should leave the app for the
    /// system browser. Automatic redirects, script-driven navigations, and ChatGPT's own popups stay
    /// in-app, so the user is never bounced to the default browser unexpectedly mid-session.
    private static func shouldOpenInSystemBrowser(_ url: URL, sourceURL: URL? = nil, navigationType: WKNavigationType) -> Bool {
        if PrivacySettings.keepThirdPartyLinksInApp() {
            return false
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        if shouldOpenInsideApp(url, sourceURL: sourceURL) {
            return false
        }
        return navigationType == .linkActivated
    }

    /// WebKit often reports JS-mediated target=_blank/window.open as `.other`, even when it came from
    /// a user click. For new-window requests the menu setting is the source of truth.
    private static func shouldOpenNewWindowInSystemBrowser(_ url: URL, sourceURL: URL? = nil) -> Bool {
        if PrivacySettings.keepThirdPartyLinksInApp() {
            return false
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        return !shouldOpenInsideApp(url, sourceURL: sourceURL)
    }

    private static func loggableURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<unparseable-url>"
        }
        if components.query != nil {
            components.percentEncodedQuery = nil
            return (components.url?.absoluteString ?? "\(url.scheme ?? "unknown")://\(url.host ?? "unknown")") + "?<redacted>"
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func canRewriteForPrivacy(_ request: URLRequest) -> Bool {
        let method = request.httpMethod?.uppercased() ?? "GET"
        return method == "GET" || method == "HEAD"
    }

    private static func needsPrivacyRewrite(request: URLRequest, cleanedURL: URL, sourceURL: URL?, profileID: String?) -> Bool {
        guard let originalURL = request.url else {
            return false
        }
        if cleanedURL.absoluteString != originalURL.absoluteString {
            return true
        }
        if ProfileStore.isEnhancedPrivacyEnabled(for: profileID),
           request.value(forHTTPHeaderField: "Sec-GPC") != "1" {
            return true
        }
        if ProfileStore.fingerprint(for: profileID) != nil,
           let acceptLanguage = acceptLanguageHeader(for: profileID),
           request.value(forHTTPHeaderField: "Accept-Language") != acceptLanguage {
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
        profileID: String?,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) -> URLRequest {
        let cleanedURL = cleanTrackingParameters(from: url)
        var request = URLRequest(url: cleanedURL, cachePolicy: cachePolicy)
        if ProfileStore.isEnhancedPrivacyEnabled(for: profileID) {
            request.setValue("1", forHTTPHeaderField: "Sec-GPC")
        }
        if ProfileStore.fingerprint(for: profileID) != nil,
           let acceptLanguage = acceptLanguageHeader(for: profileID) {
            request.setValue(acceptLanguage, forHTTPHeaderField: "Accept-Language")
        }
        if shouldTrimReferrer(from: sourceURL, to: cleanedURL),
           let origin = originReferrer(from: sourceURL) {
            request.setValue(origin, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private static func acceptLanguageHeader(for profileID: String?) -> String? {
        let languages = ProfileStore.fingerprint(for: profileID)?.acceptLanguages ?? FingerprintCatalog.defaultAcceptLanguages
        guard !languages.isEmpty else {
            return nil
        }

        return languages.enumerated().map { index, language in
            if index == 0 {
                return language
            }
            let quality = max(0.1, 1.0 - Double(index) * 0.1)
            return "\(language);q=\(String(format: "%.1f", quality))"
        }.joined(separator: ",")
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

    private static let fingerprintTestShellHTML = """
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
          background: #f8fafc;
          color: #111827;
        }
        main { max-width: 1040px; margin: 0 auto; }
        section { margin-top: 22px; }
        h1 { font-size: 24px; margin: 0 0 8px; }
        h2 { font-size: 16px; margin: 0 0 10px; }
        p { margin: 0 0 18px; color: #4b5563; line-height: 1.5; }
        table { width: 100%; border-collapse: collapse; border: 1px solid #d1d5db; background: #ffffff; }
        th, td { border-bottom: 1px solid #e5e7eb; padding: 9px 10px; text-align: left; vertical-align: top; font-size: 13px; }
        tr:last-child th, tr:last-child td { border-bottom: 0; }
        th { width: 260px; font-weight: 650; }
        code { word-break: break-all; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .ok, .risk-low { color: #15803d; }
        .warn, .risk-medium { color: #b45309; }
        .risk-high { color: #b91c1c; }
        .badge { display: inline-block; min-width: 54px; padding: 2px 7px; border-radius: 999px; text-align: center; font-size: 12px; font-weight: 650; background: #eef2ff; }
        @media (prefers-color-scheme: dark) {
          body { background: #0f172a; color: #e5e7eb; }
          p { color: #94a3b8; }
          table { border-color: #334155; background: #111827; }
          th, td { border-bottom-color: #1f2937; }
          .ok, .risk-low { color: #86efac; }
          .warn, .risk-medium { color: #fbbf24; }
          .risk-high { color: #fca5a5; }
          .badge { background: #1e293b; }
        }
      </style>
    </head>
    <body>
      <main>
        <h1>指纹检测页</h1>
        <p>正在读取当前账号空间的浏览器暴露值...</p>
        <section>
          <h2>一致性风险</h2>
          <table><tbody id="risk"><tr><th>状态</th><td><code>pending</code></td></tr></tbody></table>
        </section>
        <section>
          <h2>原始暴露值</h2>
          <table><tbody id="report"><tr><th>状态</th><td><code>pending</code></td></tr></tbody></table>
        </section>
      </main>
    </body>
    </html>
    """

    private static let fingerprintTestRenderScript = """
    (() => {
      try {
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
      const clear = (node) => {
        while (node.firstChild) node.removeChild(node.firstChild);
      };
      const appendCell = (row, tag, value, className) => {
        const cell = document.createElement(tag);
        if (className) cell.className = className;
        const code = document.createElement('code');
        code.textContent = value;
        cell.appendChild(code);
        row.appendChild(cell);
      };
      const appendRaw = (tbody, key, value) => {
        const row = document.createElement('tr');
        const th = document.createElement('th');
        th.textContent = key;
        row.appendChild(th);
        const rendered = text(value);
        appendCell(row, 'td', rendered, rendered === 'undefined' || rendered === 'absent' ? 'warn' : 'ok');
        tbody.appendChild(row);
        return row;
      };
      const appendRisk = (tbody, level, key, value) => {
        const row = document.createElement('tr');
        const cls = level === '高' ? 'risk-high' : (level === '中' ? 'risk-medium' : 'risk-low');
        const th = document.createElement('th');
        const badge = document.createElement('span');
        badge.className = 'badge ' + cls;
        badge.textContent = level;
        th.appendChild(badge);
        th.appendChild(document.createTextNode(' ' + key));
        row.appendChild(th);
        appendCell(row, 'td', text(value), cls);
        tbody.appendChild(row);
      };

      let risk = document.getElementById('risk');
      let report = document.getElementById('report');
      if (!risk || !report) {
        document.head.innerHTML = '<style>body{margin:0;padding:28px;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Arial,sans-serif;background:#f8fafc;color:#111827}main{max-width:1040px;margin:0 auto}section{margin-top:22px}h1{font-size:24px;margin:0 0 8px}h2{font-size:16px;margin:0 0 10px}p{margin:0 0 18px;color:#4b5563;line-height:1.5}table{width:100%;border-collapse:collapse;border:1px solid #d1d5db;background:#fff}th,td{border-bottom:1px solid #e5e7eb;padding:9px 10px;text-align:left;vertical-align:top;font-size:13px}th{width:260px;font-weight:650}code{word-break:break-all;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.ok,.risk-low{color:#15803d}.warn,.risk-medium{color:#b45309}.risk-high{color:#b91c1c}.badge{display:inline-block;min-width:54px;padding:2px 7px;border-radius:999px;text-align:center;font-size:12px;font-weight:650;background:#eef2ff}</style>';
        document.body.innerHTML = '<main><h1>指纹检测页</h1><p>正在读取当前账号空间的浏览器暴露值...</p><section><h2>一致性风险</h2><table><tbody id="risk"></tbody></table></section><section><h2>原始暴露值</h2><table><tbody id="report"></tbody></table></section></main>';
        risk = document.getElementById('risk');
        report = document.getElementById('report');
      }
      if (!risk || !report) throw new Error('diagnostic containers missing');
      clear(risk);
      clear(report);
      const ua = navigator.userAgent || '';
      const platform = navigator.platform || '';
      const safariFamily = /AppleWebKit/i.test(ua) && /Safari/i.test(ua) && !/(Chrome|CriOS|Firefox|FxiOS|Edg|OPR)/i.test(ua);
      appendRisk(risk, safariFamily ? '低' : '高', 'Safari 家族一致性', safariFamily ? 'UA 属于 Safari/WebKit 家族' : 'UA 不是纯 Safari/WebKit 家族');

      let device = 'mac';
      if (/iPhone/i.test(ua)) device = 'iphone';
      if (/iPad/i.test(ua)) device = 'ipad';
      const touchPoints = Number(navigator.maxTouchPoints || 0);
      const platformOk = (device === 'mac' && platform === 'MacIntel' && touchPoints === 0)
        || (device === 'iphone' && platform === 'iPhone' && touchPoints > 0)
        || (device === 'ipad' && (platform === 'iPad' || platform === 'MacIntel') && touchPoints > 0);
      appendRisk(risk, platformOk ? '低' : '高', 'UA / platform / touch', device + ', platform=' + platform + ', maxTouchPoints=' + touchPoints);

      const safariOnlySignals = [];
      if (navigator.userAgentData !== undefined) safariOnlySignals.push('userAgentData present');
      if (navigator.deviceMemory !== undefined) safariOnlySignals.push('deviceMemory present');
      if (navigator.connection !== undefined) safariOnlySignals.push('connection present');
      appendRisk(risk, safariOnlySignals.length ? '中' : '低', 'Safari-only API 暴露', safariOnlySignals.length ? safariOnlySignals.join(', ') : '未发现 Chromium-only API');

      const rtcBlocked = typeof RTCPeerConnection === 'undefined' && typeof webkitRTCPeerConnection === 'undefined';
      appendRisk(risk, rtcBlocked ? '低' : '中', 'WebRTC 暴露', rtcBlocked ? '构造器不可见' : '构造器仍可见，语音可用性和隐私需要权衡');
      appendRisk(risk, navigator.globalPrivacyControl === true ? '低' : '中', 'GPC', navigator.globalPrivacyControl === true ? 'navigator.globalPrivacyControl=true' : '未检测到 GPC JS 信号');
      const screenMismatch = innerWidth > screen.width + 48 || innerHeight > screen.height + 140;
      appendRisk(risk, screenMismatch ? '高' : '低', '窗口 / screen 尺寸', 'inner=' + innerWidth + 'x' + innerHeight + ', screen=' + screen.width + 'x' + screen.height + ', dpr=' + devicePixelRatio);
      appendRisk(risk, '中', '不可控残余', 'TLS/HTTP2 SETTINGS/IP/字体/Worker/行为模式仍由系统、网络和站点侧模型决定');

      appendRaw(report, 'URL', location.href);
      appendRaw(report, 'User-Agent', navigator.userAgent);
      appendRaw(report, 'navigator.platform', navigator.platform);
      appendRaw(report, 'navigator.language', navigator.language);
      appendRaw(report, 'navigator.languages', Array.from(navigator.languages || []));
      appendRaw(report, 'navigator.hardwareConcurrency', navigator.hardwareConcurrency);
      appendRaw(report, 'navigator.deviceMemory', navigator.deviceMemory);
      appendRaw(report, 'navigator.maxTouchPoints', navigator.maxTouchPoints);
      appendRaw(report, 'navigator.userAgentData', navigator.userAgentData);
      appendRaw(report, 'plugins.length', navigator.plugins ? navigator.plugins.length : 'undefined');
      appendRaw(report, 'mimeTypes.length', navigator.mimeTypes ? navigator.mimeTypes.length : 'undefined');
      appendRaw(report, 'TouchEvent', 'TouchEvent' in window ? 'present' : 'absent');
      appendRaw(report, 'screen', {
        width: screen.width,
        height: screen.height,
        availWidth: screen.availWidth,
        availHeight: screen.availHeight,
        colorDepth: screen.colorDepth,
        pixelDepth: screen.pixelDepth,
        orientation: screen.orientation ? { type: screen.orientation.type, angle: screen.orientation.angle } : undefined
      });
      appendRaw(report, 'window size', {
        innerWidth,
        innerHeight,
        outerWidth,
        outerHeight,
        devicePixelRatio
      });
      appendRaw(report, 'timezone', Intl.DateTimeFormat().resolvedOptions().timeZone);
      appendRaw(report, 'WebRTC constructors', {
        RTCPeerConnection: typeof RTCPeerConnection,
        webkitRTCPeerConnection: typeof webkitRTCPeerConnection,
        RTCIceCandidate: typeof RTCIceCandidate
      });
      appendRaw(report, 'mediaDevices.enumerateDevices', navigator.mediaDevices && navigator.mediaDevices.enumerateDevices ? 'present' : 'absent');
      appendRaw(report, 'Canvas hash', canvasHash());
      appendRaw(report, 'WebGL', webglInfo());
      const audioRow = appendRaw(report, 'Audio hash', 'pending');
      audioHash().then((audio) => {
        const td = audioRow.querySelector('td code');
        if (td) td.textContent = text(audio);
      });
      const description = document.querySelector('main > p');
      if (description) {
        description.textContent = '这个页面在当前账号空间内运行，用来检查 UA、navigator、screen、WebRTC、Canvas、WebGL 和 AudioContext 暴露值，并提示 Safari-only 隐私指纹的一致性风险。';
      }
      } catch (error) {
        document.body.innerHTML = '<main><h1>指纹检测页</h1><p>报告脚本执行失败：' + String(error && (error.stack || error.message || error)) + '</p></main>';
      }
    })();
    """

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
          background: #f8fafc;
          color: #111827;
        }
        main { max-width: 1040px; margin: 0 auto; }
        section { margin-top: 22px; }
        h1 { font-size: 24px; margin: 0 0 8px; }
        h2 { font-size: 16px; margin: 0 0 10px; }
        p { margin: 0 0 18px; color: #4b5563; line-height: 1.5; }
        table { width: 100%; border-collapse: collapse; border: 1px solid #d1d5db; background: #ffffff; }
        th, td {
          border-bottom: 1px solid #e5e7eb;
          padding: 9px 10px;
          text-align: left;
          vertical-align: top;
          font-size: 13px;
        }
        tr:last-child th, tr:last-child td { border-bottom: 0; }
        th { width: 260px; font-weight: 650; }
        code { word-break: break-all; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        .ok { color: #15803d; }
        .warn { color: #b45309; }
        .risk-low { color: #15803d; }
        .risk-medium { color: #b45309; }
        .risk-high { color: #b91c1c; }
        .badge {
          display: inline-block;
          min-width: 54px;
          padding: 2px 7px;
          border-radius: 999px;
          text-align: center;
          font-size: 12px;
          font-weight: 650;
          background: #eef2ff;
        }
        @media (prefers-color-scheme: dark) {
          body { background: #0f172a; color: #e5e7eb; }
          p { color: #94a3b8; }
          table { border-color: #334155; background: #111827; }
          th, td { border-bottom-color: #1f2937; }
          .ok { color: #86efac; }
          .warn { color: #fbbf24; }
          .risk-low { color: #86efac; }
          .risk-medium { color: #fbbf24; }
          .risk-high { color: #fca5a5; }
          .badge { background: #1e293b; }
        }
      </style>
    </head>
    <body>
      <main>
        <h1>指纹检测页</h1>
        <p>这个页面在当前账号空间内运行，用来检查 UA、navigator、screen、WebRTC、Canvas、WebGL 和 AudioContext 暴露值，并提示 Safari-only 隐私指纹的一致性风险。</p>
        <section>
          <h2>一致性风险</h2>
          <table>
            <tbody id="risk"></tbody>
          </table>
        </section>
        <section>
          <h2>原始暴露值</h2>
          <table>
            <tbody id="report"></tbody>
          </table>
        </section>
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
        const riskRows = [];
        const add = (key, value) => rows.push([key, text(value)]);
        const addRisk = (level, key, value) => riskRows.push([level, key, text(value)]);
        const escapeHTML = (value) => value.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
        const render = () => {
          document.getElementById('risk').innerHTML = riskRows.map(([level, key, value]) => {
            const cls = level === '高' ? 'risk-high' : (level === '中' ? 'risk-medium' : 'risk-low');
            return `<tr><th><span class="badge ${cls}">${escapeHTML(level)}</span> ${escapeHTML(key)}</th><td class="${cls}"><code>${escapeHTML(value)}</code></td></tr>`;
          }).join('');
          document.getElementById('report').innerHTML = rows.map(([key, value]) => {
            const cls = value === 'undefined' || value === 'absent' ? 'warn' : 'ok';
            return `<tr><th>${escapeHTML(key)}</th><td class="${cls}"><code>${escapeHTML(value)}</code></td></tr>`;
          }).join('');
        };
        const buildRiskReport = () => {
          const ua = navigator.userAgent || '';
          const platform = navigator.platform || '';
          const safariFamily = /AppleWebKit/i.test(ua) && /Safari/i.test(ua) && !/(Chrome|CriOS|Firefox|FxiOS|Edg|OPR)/i.test(ua);
          addRisk(safariFamily ? '低' : '高', 'Safari 家族一致性', safariFamily ? 'UA 属于 Safari/WebKit 家族' : 'UA 不是纯 Safari/WebKit 家族');

          let device = 'mac';
          if (/iPhone/i.test(ua)) device = 'iphone';
          if (/iPad/i.test(ua)) device = 'ipad';
          const touchPoints = Number(navigator.maxTouchPoints || 0);
          const platformOk = (device === 'mac' && platform === 'MacIntel' && touchPoints === 0)
            || (device === 'iphone' && platform === 'iPhone' && touchPoints > 0)
            || (device === 'ipad' && (platform === 'iPad' || platform === 'MacIntel') && touchPoints > 0);
          addRisk(platformOk ? '低' : '高', 'UA / platform / touch', `${device}, platform=${platform}, maxTouchPoints=${touchPoints}`);

          const safariOnlySignals = [];
          if (navigator.userAgentData !== undefined) safariOnlySignals.push('userAgentData present');
          if (navigator.deviceMemory !== undefined) safariOnlySignals.push('deviceMemory present');
          if (navigator.connection !== undefined) safariOnlySignals.push('connection present');
          addRisk(safariOnlySignals.length ? '中' : '低', 'Safari-only API 暴露', safariOnlySignals.length ? safariOnlySignals.join(', ') : '未发现 Chromium-only API');

          const rtcBlocked = typeof RTCPeerConnection === 'undefined' && typeof webkitRTCPeerConnection === 'undefined';
          addRisk(rtcBlocked ? '低' : '中', 'WebRTC 暴露', rtcBlocked ? '构造器不可见' : '构造器仍可见，语音可用性和隐私需要权衡');

          addRisk(navigator.globalPrivacyControl === true ? '低' : '中', 'GPC', navigator.globalPrivacyControl === true ? 'navigator.globalPrivacyControl=true' : '未检测到 GPC JS 信号');

          const screenMismatch = innerWidth > screen.width + 48 || innerHeight > screen.height + 140;
          addRisk(screenMismatch ? '高' : '低', '窗口 / screen 尺寸', `inner=${innerWidth}x${innerHeight}, screen=${screen.width}x${screen.height}, dpr=${devicePixelRatio}`);

          addRisk('中', '不可控残余', 'TLS/HTTP2 SETTINGS/IP/字体/Worker/行为模式仍由系统、网络和站点侧模型决定');
        };

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
        add('Audio hash', 'pending');
        buildRiskReport();
        render();

        audioHash().then((audio) => {
          const target = rows.find((row) => row[0] === 'Audio hash');
          if (target) target[1] = text(audio);
          render();
        });
      </script>
    </body>
    </html>
    """

    private static let downloadBridgeScript = """
    (() => {
      const marker = '__wkDownloadBridge';
      if (window[marker]) return;
      try {
        Object.defineProperty(window, marker, { value: true, configurable: false, writable: false });
      } catch (_) {
        window[marker] = true;
      }

      const maxBlobDownloadBytes = \(maximumBridgeDownloadBytes);
      const isTrustedPage = () => {
        try {
          const host = location.hostname.toLowerCase();
          return location.protocol === 'https:' && (host === 'chatgpt.com' || host.endsWith('.chatgpt.com') || host === 'chat.openai.com' || host.endsWith('.chat.openai.com'));
        } catch (_) {
          return false;
        }
      };
      if (!isTrustedPage()) return;

      const looksLikeCloudflareChallenge = () => {
        try {
          const href = String(location.href || '').toLowerCase();
          if (href.includes('/cdn-cgi/challenge-platform/')) return true;
          if (document.querySelector([
            'iframe[src*="challenges.cloudflare.com"]',
            '.cf-turnstile',
            '#cf-challenge-running',
            '#challenge-stage',
            '[data-cf-challenge]'
          ].join(','))) return true;
          const text = String(document.body ? document.body.textContent || '' : '').toLowerCase();
          return text.includes('cloudflare') && (
            text.includes('verifying') ||
            text.includes('checking') ||
            text.includes('正在验证') ||
            text.includes('验证')
          );
        } catch (_) {
          return false;
        }
      };

      const blobURLs = new Map();
      const installBlobURLCache = () => {
        if (!URL.createObjectURL) return;
        const originalCreateObjectURL = URL.createObjectURL.bind(URL);
        URL.createObjectURL = (value) => {
          const url = originalCreateObjectURL(value);
          try {
            if (value instanceof Blob) blobURLs.set(url, value);
          } catch (_) {}
          return url;
        };
        if (URL.revokeObjectURL) {
          const originalRevokeObjectURL = URL.revokeObjectURL.bind(URL);
          URL.revokeObjectURL = (url) => {
            blobURLs.delete(url);
            return originalRevokeObjectURL(url);
          };
        }
      };

      function readBlob(blob) {
        if (!blob || typeof blob.size !== 'number' || blob.size > maxBlobDownloadBytes) {
          throw new Error('Blob download is too large for this bridge');
        }
        return new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = () => reject(reader.error || new Error('Unable to read blob'));
          reader.readAsDataURL(blob);
        });
      }

      async function resolveDataURL(href) {
        if (href.startsWith('data:')) {
          if (href.length > maxBlobDownloadBytes * 2 + 4096) throw new Error('Data URL download is too large for this bridge');
          return href;
        }
        const cached = blobURLs.get(href);
        if (cached) return await readBlob(cached);
        const response = await fetch(href);
        return await readBlob(await response.blob());
      }

      function filenameFromURL(raw, fallback) {
        try {
          const url = new URL(raw, location.href);
          const last = decodeURIComponent(url.pathname.split('/').filter(Boolean).pop() || '');
          if (last) return last;
        } catch (_) {}
        return fallback || 'chatgpt-image.png';
      }

            function imageTargetFromEvent(event) {
              const path = event.composedPath ? event.composedPath() : [];
              for (const node of path) {
                if (!node || node === window || node === document) continue;
                if (node instanceof HTMLImageElement || node instanceof HTMLCanvasElement) return node;
              }
              const target = event.target;
              if (target && target.closest) {
                return target.closest('img, canvas');
              }
              return null;
            }

            function installStopTooltipGuard() {
              if (!isTrustedPage()) return;
              const stopTooltipLabels = [
                '停止回答',
                'Stop generating',
                'Stop response',
                'Stop answering'
              ];
              const tooltipSelector = '[role="tooltip"], [data-radix-popper-content-wrapper]';
              let guardTimer = 0;

              function hideStopTooltips() {
                guardTimer = 0;
                for (const tooltip of document.querySelectorAll(tooltipSelector)) {
                  const text = (tooltip.textContent || '').trim();
                  if (!stopTooltipLabels.some((label) => text.includes(label))) continue;
                  tooltip.style.setProperty('display', 'none', 'important');
                  tooltip.style.setProperty('visibility', 'hidden', 'important');
                  tooltip.setAttribute('data-wk-hidden-stop-tooltip', 'true');
                }
              }

              function scheduleGuard() {
                if (guardTimer) return;
                guardTimer = window.setTimeout(hideStopTooltips, 80);
              }

              const root = document.documentElement || document.body;
              if (!root) {
                document.addEventListener('DOMContentLoaded', installStopTooltipGuard, { once: true });
                return;
              }

              scheduleGuard();
              document.addEventListener('pointermove', scheduleGuard, true);
              document.addEventListener('focusin', scheduleGuard, true);
              new MutationObserver(scheduleGuard).observe(root, {
                childList: true,
                subtree: true
              });
            }

            async function imagePayload(target) {
              if (target instanceof HTMLCanvasElement) {
                const dataURL = target.toDataURL('image/png');
                if (dataURL.length > maxBlobDownloadBytes * 2 + 4096) throw new Error('Canvas image is too large for this bridge');
                return { filename: 'chatgpt-canvas.png', dataURL };
              }

        const src = target.currentSrc || target.src || '';
        if (!src) throw new Error('Image has no source URL');

        const filename = target.getAttribute('download') || target.alt || filenameFromURL(src, 'chatgpt-image.png');
        if (src.startsWith('data:') || src.startsWith('blob:')) {
          return { filename, dataURL: await resolveDataURL(src) };
        }

        const url = new URL(src, location.href);
        if (url.protocol !== 'https:') throw new Error('Only HTTPS images can be downloaded by URL');
        try {
          const response = await fetch(url.href, { credentials: 'include', cache: 'no-store' });
          if (response.ok) {
            return { filename, dataURL: await readBlob(await response.blob()) };
          }
        } catch (_) {}
              return { filename, url: url.href };
            }

            const installPageHooks = () => {
              if (looksLikeCloudflareChallenge()) return;
              installBlobURLCache();
              installStopTooltipGuard();

              document.addEventListener('contextmenu', (event) => {
                if (!isTrustedPage()) return;
        const target = imageTargetFromEvent(event);
        if (!target) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        imagePayload(target).then((payload) => {
          window.webkit.messageHandlers.downloadBlob.postMessage(Object.assign({
            action: 'showImageMenu',
            x: event.clientX,
            y: event.clientY
          }, payload));
        }).catch((error) => {
          console.error('[WebView] image context menu failed', error);
        });
              }, true);

              document.addEventListener('click', async (event) => {
        const target = event.target && event.target.closest ? event.target.closest('a[href^="blob:"],a[href^="data:"]') : null;
        if (!target) return;
        if (!isTrustedPage()) return;

        const href = target.href || '';

        const cachedBlob = blobURLs.get(href);
        const exceedsBridge = (cachedBlob && typeof cachedBlob.size === 'number' && cachedBlob.size > maxBlobDownloadBytes)
          || (href.startsWith('data:') && href.length > maxBlobDownloadBytes * 2 + 4096);
        if (exceedsBridge) {
          // Too large for the base64 bridge — let WebKit's native downloader stream it to disk instead
          // of materializing a multi-hundred-MB data URL across the IPC boundary.
          return;
        }

        event.preventDefault();
        event.stopImmediatePropagation();

        try {
          const dataURL = await resolveDataURL(href);
          window.webkit.messageHandlers.downloadBlob.postMessage({
            filename: target.download || 'chatgpt-download',
            dataURL
          });
        } catch (error) {
          console.error('[WebView] blob download bridge failed', error);
        }
              }, true);
            };

            if (document.readyState === 'loading') {
              document.addEventListener('DOMContentLoaded', installPageHooks, { once: true });
            } else {
              installPageHooks();
            }
    })();
    """
}

private struct CookieImportDocument: Decodable {
    let cookies: [ExportedBrowserCookie]

    enum CodingKeys: String, CodingKey {
        case cookies
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let cookies = try? singleValue.decode([ExportedBrowserCookie].self) {
            self.cookies = cookies
            return
        }
        if let cookie = try? singleValue.decode(ExportedBrowserCookie.self) {
            self.cookies = [cookie]
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cookies = try container.decode([ExportedBrowserCookie].self, forKey: .cookies)
    }
}

private struct CookieIdentity: Hashable {
    let name: String
    let domain: String
    let path: String

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        domain = Self.normalizedDomain(cookie.domain)
        path = cookie.path
    }

    private static func normalizedDomain(_ domain: String) -> String {
        var normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        return normalized
    }
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

    init(
        domain: String,
        expirationDate: Double?,
        hostOnly: Bool?,
        httpOnly: Bool?,
        name: String,
        path: String,
        sameSite: String?,
        secure: Bool?,
        session: Bool?,
        value: String
    ) {
        self.domain = domain
        self.expirationDate = expirationDate
        self.hostOnly = hostOnly
        self.httpOnly = httpOnly
        self.name = name
        self.path = path
        self.sameSite = sameSite
        self.secure = secure
        self.session = session
        self.value = value
    }

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
        guard BrowserWindowController.isAllowedCookieDomain(trimmedDomain) else {
            throw BrowserWindowController.cookieImportError("cookie 域名不在 ChatGPT/OpenAI 白名单中：\(trimmedDomain)")
        }
        guard cookiePath.hasPrefix("/") else {
            throw BrowserWindowController.cookieImportError("cookie path 无效")
        }
        guard !cookiePath.utf8.contains(0),
              !cookiePath.split(separator: "/").contains(where: { $0 == ".." }) else {
            throw BrowserWindowController.cookieImportError("cookie path 不安全")
        }

        var cookieAttributes: [HTTPCookiePropertyKey: Any] = [
            .name: trimmedName,
            .value: value,
            .domain: trimmedDomain,
            .path: cookiePath,
            .version: "0",
        ]

        if secure == true {
            cookieAttributes[.secure] = "TRUE"
        }
        if httpOnly == true {
            cookieAttributes[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        if let sameSiteValue = normalizedSameSiteValue(sameSite) {
            cookieAttributes[HTTPCookiePropertyKey("SameSite")] = sameSiteValue
        }
        if session != true, let expirationDate {
            cookieAttributes[.expires] = Date(timeIntervalSince1970: expirationDate)
        }

        guard let result = makeFoundationCookie(cookieAttributes) else {
            throw BrowserWindowController.cookieImportError("cookie 数据无法转换")
        }

        return result
    }

    private func makeFoundationCookie(_ attributes: [HTTPCookiePropertyKey: Any]) -> HTTPCookie? {
        HTTPCookie(properties: attributes)
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

private extension String {
    func removingUTF8ByteOrderMark() -> String {
        if hasPrefix("\u{feff}") {
            return String(dropFirst())
        }
        return self
    }
}

private struct WebProfile: Codable {
    let id: String
    var name: String
    var createdAt: Date
}

private enum WebsiteDataCleaner {
    static func removeAllData(from dataStore: WKWebsiteDataStore, completion: @escaping () -> Void) {
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

        group.notify(queue: .main, execute: completion)
    }
}

private struct ProfileExportDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let sourceProfileID: String
    let name: String
    let homepage: String?
    let fingerprint: FingerprintProfile?
    let fingerprintDisabled: Bool?
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

/// Resolves the timezone of the current network egress so the injected browser fingerprint's
/// timezone matches the exit IP's country. A system VPN routes URLSession traffic through its exit,
/// so a plain request reports the exit's geo. Cloudflare treats "IP in country A, browser timezone
/// in country B" as a bot signal and issues more managed challenges; aligning the timezone removes
/// it. Every failure path degrades to nil (no override -> system timezone), so offline / non-VPN
/// behavior is unchanged.
private enum GeoIPResolver {
    private static let cacheKey = "geoip.exit.timezone"

    private static var endpoints: [(url: URL, timezone: (Any) -> String?)] {
        var list: [(URL, (Any) -> String?)] = []
        if let u = URL(string: "https://ipwho.is/") {
            // ipwho.is: { "timezone": { "id": "America/New_York", ... } }
            list.append((u, { json in
                ((json as? [String: Any])?["timezone"] as? [String: Any])?["id"] as? String
            }))
        }
        if let u = URL(string: "https://ipinfo.io/json") {
            // ipinfo.io: { "timezone": "America/New_York", ... }
            list.append((u, { json in
                (json as? [String: Any])?["timezone"] as? String
            }))
        }
        return list
    }

    static func cachedTimezone() -> String? {
        guard let tz = UserDefaults.standard.string(forKey: cacheKey), isValidTimezone(tz) else {
            return nil
        }
        return tz
    }

    /// Resolve the exit timezone in the background; the completion runs on the main queue with the
    /// resolved timezone (nil on total failure) and whether it differs from the previously cached
    /// value, so a caller can refresh injection only when the exit actually changed.
    static func refresh(completion: ((String?, Bool) -> Void)? = nil) {
        let previous = cachedTimezone()
        DispatchQueue.global(qos: .utility).async {
            resolve(endpointIndex: 0) { resolved in
                if let resolved {
                    UserDefaults.standard.set(resolved, forKey: cacheKey)
                }
                guard let completion else { return }
                let changed = resolved != nil && resolved != previous
                DispatchQueue.main.async { completion(resolved, changed) }
            }
        }
    }

    private static func resolve(endpointIndex: Int, completion: @escaping (String?) -> Void) {
        let endpoints = self.endpoints
        guard endpointIndex < endpoints.count else {
            completion(nil)
            return
        }
        let endpoint = endpoints[endpointIndex]
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data),
               let tz = endpoint.timezone(json), isValidTimezone(tz) {
                completion(tz)
            } else {
                resolve(endpointIndex: endpointIndex + 1, completion: completion)
            }
        }.resume()
    }

    private static func isValidTimezone(_ tz: String) -> Bool {
        !tz.isEmpty && tz.count <= 64 && TimeZone(identifier: tz) != nil
    }
}

private enum FingerprintCatalog {
    static let offPresetID = "off"
    static let defaultAcceptLanguages = ["zh-CN", "en-US"]

    private static let macSafari17UserAgent = defaultSafariUserAgent
    // iOS/iPadOS 26 freezes the UA OS token at 18_6 (like macOS freezes 10_15_7); the real OS major lives only in Version/ (26.0). Real devices report OS 18_6 — do NOT "correct" it to 26_0, that would be a detectable fake.
    private static let iPadSafari17UserAgent = "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    private static let iPhoneSafari17UserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    static let presets: [FingerprintProfile] = [
        FingerprintProfile(
            presetID: "mba13",
            displayName: "MacBook Air 13\" M2",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
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
            acceptLanguages: defaultAcceptLanguages,
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
            acceptLanguages: defaultAcceptLanguages,
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
            acceptLanguages: defaultAcceptLanguages,
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
            acceptLanguages: defaultAcceptLanguages,
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
        randomMacProfile()
    }

    static func privacyAssessment(
        fingerprint: FingerprintProfile?,
        enhancedPrivacyEnabled: Bool,
        webRTCProtectionEnabled: Bool
    ) -> String {
        var lines: [String] = []
        if let fingerprint {
            lines.append("推荐基线：开启，当前空间固定为 \(fingerprint.displayName)")
            let issues = consistencyIssues(for: fingerprint)
            if issues.isEmpty {
                lines.append("Safari 一致性：通过基础检查")
            } else {
                lines.append("Safari 一致性：需注意 " + issues.joined(separator: "；"))
            }
        } else {
            lines.append("推荐基线：关闭，当前空间使用真实默认 Safari/WebKit 指纹")
        }
        lines.append("增强隐私：\(enhancedPrivacyEnabled ? "开启，Canvas/WebGL/Audio 等使用稳定扰动" : "关闭，JS 层高熵指纹暴露更多")")
        lines.append("WebRTC：\(webRTCProtectionEnabled ? "已屏蔽构造器和设备枚举" : "关闭，可能暴露本机网络和设备枚举")")
        lines.append("不可控残余：TLS/HTTP2/Worker/字体/GPU/IP/行为模式仍不能保证伪装成另一台真实设备")
        return lines.joined(separator: "\n")
    }

    private static func consistencyIssues(for fingerprint: FingerprintProfile) -> [String] {
        var issues: [String] = []
        let ua = fingerprint.userAgent
        let isSafariFamily = ua.contains("AppleWebKit")
            && ua.contains("Safari")
            && !ua.contains("Chrome")
            && !ua.contains("Firefox")
            && !ua.contains("Edg")
        if !isSafariFamily {
            issues.append("UA 不是 Safari/WebKit 家族")
        }
        if ua.contains("Macintosh") && fingerprint.platform != "MacIntel" {
            issues.append("Mac UA 与 platform 不一致")
        }
        if ua.contains("iPhone") && (fingerprint.platform != "iPhone" || fingerprint.maxTouchPoints == 0) {
            issues.append("iPhone UA 与触控/platform 不一致")
        }
        if ua.contains("iPad") && fingerprint.maxTouchPoints == 0 {
            issues.append("iPad UA 缺少触控能力")
        }
        if fingerprint.maxTouchPoints == 0 && (fingerprint.platform == "iPhone" || fingerprint.platform == "iPad") {
            issues.append("移动 platform 缺少触控能力")
        }
        if fingerprint.devicePixelRatio < 1.0 || fingerprint.devicePixelRatio > 3.0 {
            issues.append("DPR 超出常见 Safari 设备范围")
        }
        if fingerprint.screenWidth < 320 || fingerprint.screenHeight < 480 {
            issues.append("屏幕尺寸过小")
        }
        return issues
    }

    /// 仅时区对齐的 JS 片段(只改 Intl.DateTimeFormat / Date.getTimezoneOffset,不碰 navigator/screen)。
    /// 指纹脚本与「默认不混淆」时区脚本共用此片段,避免两处时区逻辑漂移。
    private static func timezoneAlignmentBlock(timezone: String) -> String {
        return """
          try {
            const OrigDTF = Intl.DateTimeFormat;
            const TZ = \(jsonLiteral(timezone));
            function DateTimeFormat(locales, options) {
              const o = Object.assign({}, options || {});
              if (!o.timeZone) o.timeZone = TZ;
              return new OrigDTF(locales, o);
            }
            DateTimeFormat.prototype = OrigDTF.prototype;
            for (const k of ['supportedLocalesOf']) {
              if (typeof OrigDTF[k] === 'function') {
                DateTimeFormat[k] = OrigDTF[k].bind(OrigDTF);
                markFake(DateTimeFormat[k], k);
              }
            }
            markFake(DateTimeFormat, 'DateTimeFormat');
            Intl.DateTimeFormat = DateTimeFormat;
            const origResolved = Object.getOwnPropertyDescriptor(OrigDTF.prototype, 'resolvedOptions');
            if (origResolved && typeof origResolved.value === 'function') {
              const origFn = origResolved.value;
              function resolvedOptions() {
                const r = origFn.call(this);
                r.timeZone = TZ;
                return r;
              }
              markFake(resolvedOptions, 'resolvedOptions');
              Object.defineProperty(OrigDTF.prototype, 'resolvedOptions', { value: resolvedOptions, writable: true, configurable: true });
            }
            const origGetTZO = Date.prototype.getTimezoneOffset;
            function getTimezoneOffset() {
              try {
                const parts = new OrigDTF('en-US', { timeZone: TZ, timeZoneName: 'shortOffset' }).formatToParts(this);
                const tzPart = parts.find(p => p.type === 'timeZoneName');
                if (tzPart && tzPart.value) {
                  const m = tzPart.value.match(/GMT([+-])(\\d+)(?::(\\d+))?/);
                  if (m) {
                    const sign = m[1] === '+' ? -1 : 1;
                    const h = parseInt(m[2], 10) || 0;
                    const mi = parseInt(m[3] || '0', 10) || 0;
                    return sign * (h * 60 + mi);
                  }
                }
              } catch (_) {}
              return origGetTZO.call(this);
            }
            markFake(getTimezoneOffset, 'getTimezoneOffset');
            Date.prototype.getTimezoneOffset = getTimezoneOffset;
          } catch (_) {}
        """
    }

    /// 默认真 Safari(不混淆)下也对齐 VPN 出口时区:只改时区,绝不伪造 navigator/screen。
    /// 仅当已解析到出口时区且与系统时区不同(典型 = 开了 VPN)时返回脚本;否则 nil(零注入、零影响)。
    static func timezoneOnlyScript(systemTimezone: String) -> String? {
        guard let timezone = GeoIPResolver.cachedTimezone(), timezone != systemTimezone else {
            return nil
        }
        return """
        (() => {
          if (window.__wkTimezoneAlign) return;
          try {
            Object.defineProperty(window, '__wkTimezoneAlign', { value: true, configurable: false, writable: false });
          } catch (_) {}
          const markFake = window.__wkMarkNative || ((fn) => fn);
        \(timezoneAlignmentBlock(timezone: timezone))
        })();
        """
    }

    static func script(for fingerprint: FingerprintProfile) -> String {
        let languagesJSON = jsonLiteral(fingerprint.acceptLanguages)
        let primaryLanguage = fingerprint.acceptLanguages.first ?? "en-US"
        // A selected preset's own timezone wins; otherwise fall back to the GeoIP-resolved exit
        // timezone so a VPN user's page timezone matches their exit IP's country (Cloudflare flags
        // IP/timezone mismatch). Nil on both -> no override -> system timezone, unchanged behavior.
        let resolvedTimezone = fingerprint.timezone ?? GeoIPResolver.cachedTimezone()
        let timezoneBlock = resolvedTimezone.map { timezoneAlignmentBlock(timezone: $0) } ?? ""

        return """
        (() => {
          if (window.__wkFingerprint) return;
          try {
            Object.defineProperty(window, '__wkFingerprint', { value: true, configurable: false, writable: false });
          } catch (_) {}

          const markFake = window.__wkMarkNative || ((fn) => fn);

          const defGetter = (obj, key, val, getterName) => {
            try {
              const fn = { [getterName]: function () { return val; } }[getterName];
              markFake(fn, getterName);
              Object.defineProperty(obj, key, { get: fn, configurable: true });
            } catch (_) {}
          };

          const langs = Object.freeze(\(languagesJSON).slice ? \(languagesJSON).slice() : \(languagesJSON));

          defGetter(Navigator.prototype, 'userAgent', \(jsonLiteral(fingerprint.userAgent)), 'get userAgent');
          defGetter(Navigator.prototype, 'vendor', 'Apple Computer, Inc.', 'get vendor');
          defGetter(Navigator.prototype, 'platform', \(jsonLiteral(fingerprint.platform)), 'get platform');
          defGetter(Navigator.prototype, 'language', \(jsonLiteral(primaryLanguage)), 'get language');
          defGetter(Navigator.prototype, 'languages', langs, 'get languages');
          defGetter(Navigator.prototype, 'hardwareConcurrency', \(fingerprint.hardwareConcurrency), 'get hardwareConcurrency');
          defGetter(Navigator.prototype, 'maxTouchPoints', \(fingerprint.maxTouchPoints), 'get maxTouchPoints');
          try {
            if ('webdriver' in navigator || 'webdriver' in Navigator.prototype) {
              defGetter(Navigator.prototype, 'webdriver', undefined, 'get webdriver');
            }
          } catch (_) {}
          try {
            if ('deviceMemory' in navigator || 'deviceMemory' in Navigator.prototype) {
              defGetter(Navigator.prototype, 'deviceMemory', undefined, 'get deviceMemory');
            }
          } catch (_) {}

          defGetter(Screen.prototype, 'width', \(fingerprint.screenWidth), 'get width');
          defGetter(Screen.prototype, 'height', \(fingerprint.screenHeight), 'get height');
          defGetter(Screen.prototype, 'availWidth', \(fingerprint.screenWidth), 'get availWidth');
          defGetter(Screen.prototype, 'availHeight', \(fingerprint.screenHeight), 'get availHeight');
          defGetter(Screen.prototype, 'colorDepth', \(fingerprint.colorDepth), 'get colorDepth');
          defGetter(Screen.prototype, 'pixelDepth', \(fingerprint.colorDepth), 'get pixelDepth');

          try {
            const dprFn = { 'get devicePixelRatio': function () { return \(fingerprint.devicePixelRatio); } }['get devicePixelRatio'];
            markFake(dprFn, 'get devicePixelRatio');
            Object.defineProperty(window, 'devicePixelRatio', { get: dprFn, configurable: true });
          } catch (_) {}

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
        // Safari on Apple Silicon always reports "Apple GPU" regardless of touch
        let webGLRenderer = "Apple GPU"

        return """
        (() => {
          if (window.__wkEnhancedPrivacy) return;
          try {
            Object.defineProperty(window, '__wkEnhancedPrivacy', { value: true, configurable: false, writable: false });
          } catch (_) {}

          const seed = \(seed);
          const maxTouchPoints = \(maxTouchPoints);
          const markFake = window.__wkMarkNative || ((fn) => fn);

          const defGetter = (obj, key, val, getterName) => {
            try {
              const fn = { [getterName]: function () { return val; } }[getterName];
              markFake(fn, getterName);
              Object.defineProperty(obj, key, { get: fn, configurable: true });
            } catch (_) {}
          };
          const defValue = (obj, key, val) => {
            try { Object.defineProperty(obj, key, { value: val, configurable: true, writable: false }); } catch (_) {}
          };
          const wrap = (target, key, factory, fakeName) => {
            try {
              const original = target[key];
              if (typeof original !== 'function') return null;
              const replacement = factory(original);
              if (typeof replacement !== 'function') return null;
              markFake(replacement, fakeName || key);
              target[key] = replacement;
              return original;
            } catch (_) { return null; }
          };
          const noise = (i) => {
            let x = (seed + Math.imul(i + 1, 374761393)) | 0;
            x = Math.imul(x ^ (x >>> 13), 1274126177);
            return ((x ^ (x >>> 16)) & 1) ? 1 : -1;
          };

          try {
            if ('userAgentData' in navigator || 'userAgentData' in Navigator.prototype) {
              defGetter(Navigator.prototype, 'userAgentData', undefined, 'get userAgentData');
            }
          } catch (_) {}
          try {
            if ('connection' in navigator || 'connection' in Navigator.prototype) {
              defGetter(Navigator.prototype, 'connection', undefined, 'get connection');
            }
          } catch (_) {}

          if (maxTouchPoints > 0) {
            try {
              if (!('ontouchstart' in window)) defGetter(window, 'ontouchstart', null, 'get ontouchstart');
              if (!window.TouchEvent && window.UIEvent) defValue(window, 'TouchEvent', window.UIEvent);
            } catch (_) {}
            try {
              const origMatchMedia = window.matchMedia;
              if (typeof origMatchMedia === 'function') {
                const touchOverrides = [
                  { re: /\\(\\s*hover\\s*:\\s*hover\\s*\\)/i, value: false },
                  { re: /\\(\\s*hover\\s*:\\s*none\\s*\\)/i, value: true },
                  { re: /\\(\\s*any-hover\\s*:\\s*hover\\s*\\)/i, value: false },
                  { re: /\\(\\s*any-hover\\s*:\\s*none\\s*\\)/i, value: true },
                  { re: /\\(\\s*pointer\\s*:\\s*fine\\s*\\)/i, value: false },
                  { re: /\\(\\s*pointer\\s*:\\s*coarse\\s*\\)/i, value: true },
                  { re: /\\(\\s*pointer\\s*:\\s*none\\s*\\)/i, value: false },
                  { re: /\\(\\s*any-pointer\\s*:\\s*fine\\s*\\)/i, value: false },
                  { re: /\\(\\s*any-pointer\\s*:\\s*coarse\\s*\\)/i, value: true }
                ];
                const mediaOverrideCache = new Map();
                function matchMedia(query) {
                  const result = origMatchMedia.call(this, query);
                  try {
                    const q = String(query || '');
                    if (!/(hover|pointer)/i.test(q)) return result;
                    let override = mediaOverrideCache.get(q);
                    if (override === undefined) {
                      override = null;
                      for (const rule of touchOverrides) {
                        if (rule.re.test(q)) {
                          override = rule.value;
                          break;
                        }
                      }
                      mediaOverrideCache.set(q, override);
                    }
                    if (override === null) return result;
                    return Object.assign({}, result, {
                      matches: override,
                      media: q,
                      onchange: null,
                      addEventListener: result.addEventListener ? result.addEventListener.bind(result) : function () {},
                      removeEventListener: result.removeEventListener ? result.removeEventListener.bind(result) : function () {},
                      addListener: result.addListener ? result.addListener.bind(result) : function () {},
                      removeListener: result.removeListener ? result.removeListener.bind(result) : function () {},
                      dispatchEvent: result.dispatchEvent ? result.dispatchEvent.bind(result) : function () { return true; }
                    });
                  } catch (_) {}
                  return result;
                }
                markFake(matchMedia, 'matchMedia');
                window.matchMedia = matchMedia;
              }
            } catch (_) {}
          }

          const orientation = Object.freeze({
            type: \(jsonLiteral(orientationType)),
            angle: \(orientationAngle),
            onchange: null,
            addEventListener: function () {},
            removeEventListener: function () {},
            dispatchEvent: function () { return true; }
          });
          markFake(orientation.addEventListener, 'addEventListener');
          markFake(orientation.removeEventListener, 'removeEventListener');
          markFake(orientation.dispatchEvent, 'dispatchEvent');
          defGetter(Screen.prototype, 'orientation', orientation, 'get orientation');

          try {
            if (navigator.permissions && navigator.permissions.query) {
              const originalQuery = navigator.permissions.query.bind(navigator.permissions);
              function query(descriptor) {
                try {
                  return originalQuery(descriptor).catch(function () { return Promise.resolve({ state: 'prompt', onchange: null }); });
                } catch (_) {
                  return Promise.resolve({ state: 'prompt', onchange: null });
                }
              }
              markFake(query, 'query');
              navigator.permissions.query = query;
            }
          } catch (_) {}

          try {
            if (!navigator.mediaDevices) {
              const emptyEnumerate = function enumerateDevices() { return Promise.resolve([]); };
              markFake(emptyEnumerate, 'enumerateDevices');
              defGetter(Navigator.prototype, 'mediaDevices', { enumerateDevices: emptyEnumerate }, 'get mediaDevices');
            } else if (navigator.mediaDevices.enumerateDevices) {
              const originalEnumerateDevices = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
              const wrappedEnumerate = function enumerateDevices() {
                return originalEnumerateDevices().catch(function () { return []; });
              };
              markFake(wrappedEnumerate, 'enumerateDevices');
              navigator.mediaDevices.enumerateDevices = wrappedEnumerate;
            }
          } catch (_) {}

          const maxNoiseWrites = 4096;
          const boundedNoiseStep = (length, minimum) => Math.max(minimum, Math.ceil((length || 0) / maxNoiseWrites));
          const applyCanvasNoise = (imageData, offset) => {
            try {
              const data = imageData && imageData.data;
              if (!data) return imageData;
              const step = boundedNoiseStep(data.length, 251);
              for (let i = offset || 0; i < data.length; i += step) {
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
              const width = Math.min(4, canvas.width);
              const height = Math.min(4, canvas.height);
              const imageData = ctx.getImageData(0, 0, width, height);
              applyCanvasNoise(imageData, 3);
              ctx.putImageData(imageData, 0, 0);
            } catch (_) {}
          };
          try {
            const canvas2D = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
            if (canvas2D) {
              wrap(canvas2D, 'getImageData', function (original) {
                return function getImageData() {
                  return applyCanvasNoise(original.apply(this, arguments), 7);
                };
              }, 'getImageData');
            }
            if (window.HTMLCanvasElement) {
              wrap(HTMLCanvasElement.prototype, 'toDataURL', function (original) {
                return function toDataURL() {
                  perturbCanvas(this);
                  return original.apply(this, arguments);
                };
              }, 'toDataURL');
              wrap(HTMLCanvasElement.prototype, 'toBlob', function (original) {
                return function toBlob() {
                  perturbCanvas(this);
                  return original.apply(this, arguments);
                };
              }, 'toBlob');
            }
          } catch (_) {}

          const patchWebGL = (proto) => {
            if (!proto) return;
            wrap(proto, 'getParameter', function (original) {
              return function getParameter(parameter) {
                if (parameter === 37445) return 'Apple Inc.';
                if (parameter === 37446) return \(jsonLiteral(webGLRenderer));
                return original.apply(this, arguments);
              };
            }, 'getParameter');
            wrap(proto, 'readPixels', function (original) {
              return function readPixels() {
                const result = original.apply(this, arguments);
                try {
                  const pixels = arguments[6];
                  if (pixels && typeof pixels.length === 'number') {
                    const step = boundedNoiseStep(pixels.length, 257);
                    for (let i = 0; i < pixels.length; i += step) {
                      pixels[i] = Math.max(0, Math.min(255, pixels[i] + noise(i + 11)));
                    }
                  }
                } catch (_) {}
                return result;
              };
            }, 'readPixels');
          };
          patchWebGL(window.WebGLRenderingContext && WebGLRenderingContext.prototype);
          patchWebGL(window.WebGL2RenderingContext && WebGL2RenderingContext.prototype);

          try {
            if (window.AudioBuffer && AudioBuffer.prototype.getChannelData) {
              wrap(AudioBuffer.prototype, 'getChannelData', function (original) {
                return function getChannelData() {
                  const data = original.apply(this, arguments);
                  try {
                    const step = boundedNoiseStep(data.length, 293);
                    for (let i = 0; i < data.length; i += step) {
                      data[i] += noise(i + 23) * 0.0000001;
                    }
                  } catch (_) {}
                  return data;
                };
              }, 'getChannelData');
            }
            if (window.AnalyserNode && AnalyserNode.prototype.getFloatFrequencyData) {
              wrap(AnalyserNode.prototype, 'getFloatFrequencyData', function (original) {
                return function getFloatFrequencyData(array) {
                  const result = original.apply(this, arguments);
                  try {
                    const step = boundedNoiseStep(array.length, 307);
                    for (let i = 0; i < array.length; i += step) {
                      array[i] += noise(i + 31) * 0.0001;
                    }
                  } catch (_) {}
                  return result;
                };
              }, 'getFloatFrequencyData');
            }
          } catch (_) {}
        })();
        """
    }

    private static func randomMacProfile() -> FingerprintProfile {
        let cores = [4, 6, 8, 10, 12].randomElement() ?? 8
        let memory = [8, 16, 32].randomElement() ?? 16
        let screen = [
            (1470, 956),
            (1512, 982),
            (1920, 1080),
            (2560, 1440),
            (3024, 1964),
        ].randomElement() ?? (1470, 956)

        return FingerprintProfile(
            presetID: "random-\(UUID().uuidString)",
            displayName: "随机：Mac Safari 稳定指纹",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
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
            acceptLanguages: defaultAcceptLanguages,
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
            acceptLanguages: defaultAcceptLanguages,
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
    static func ensurePrivacyBaseline() {
        let profiles = loadProfiles()
        for profile in profiles {
            ensureFingerprintBaseline(for: profile.id)
            let enhancedKey = profileEnhancedPrivacyDefaultsPrefix + profile.id
            if UserDefaults.standard.object(forKey: enhancedKey) == nil {
                UserDefaults.standard.set(false, forKey: enhancedKey)
            }
        }
        UserDefaults.standard.synchronize()
    }

    private static func ensureFingerprintBaseline(for profileID: String) {
        let fingerprintKey = profileFingerprintDefaultsPrefix + profileID
        let disabledKey = profileFingerprintDisabledDefaultsPrefix + profileID
        guard UserDefaults.standard.data(forKey: fingerprintKey) == nil,
              UserDefaults.standard.object(forKey: disabledKey) == nil else {
            return
        }
        disableFingerprint(for: profileID)
    }

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

    static func startupProfileID() -> String {
        let profiles = loadProfiles()
        if let stored = UserDefaults.standard.string(forKey: startupProfileDefaultsKey),
           profiles.contains(where: { $0.id == stored }) {
            return stored
        }
        return defaultProfileID
    }

    @discardableResult
    static func setStartupProfileID(_ id: String) -> Bool {
        var profiles = loadProfiles()
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let profile = profiles.remove(at: idx)
        profiles.insert(profile, at: 0)
        save(profiles)
        UserDefaults.standard.set(id, forKey: startupProfileDefaultsKey)
        UserDefaults.standard.set(id, forKey: currentProfileDefaultsKey)
        UserDefaults.standard.synchronize()
        return true
    }

    static func clearStartupProfileIfNeeded(_ id: String) {
        guard UserDefaults.standard.string(forKey: startupProfileDefaultsKey) == id else {
            return
        }
        UserDefaults.standard.removeObject(forKey: startupProfileDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func applyStartupProfileIfAvailable() {
        guard let stored = UserDefaults.standard.string(forKey: startupProfileDefaultsKey) else {
            return
        }
        let profiles = loadProfiles()
        guard profiles.contains(where: { $0.id == stored }) else {
            UserDefaults.standard.removeObject(forKey: startupProfileDefaultsKey)
            UserDefaults.standard.synchronize()
            return
        }
        if stored != defaultProfileID {
            guard #available(macOS 14.0, *) else {
                return
            }
        }
        setCurrentProfileID(stored)
    }

    static func save(_ profiles: [WebProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        UserDefaults.standard.set(data, forKey: profilesDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func resetDefaultProfile() {
        var profiles = loadProfiles()
        profiles.removeAll { $0.id == defaultProfileID }
        profiles.insert(WebProfile(id: defaultProfileID, name: "默认", createdAt: Date()), at: 0)
        save(profiles)
        removeHomepage(for: defaultProfileID)
        disableFingerprint(for: defaultProfileID)
        setEnhancedPrivacyEnabled(false, for: defaultProfileID)
        clearStartupProfileIfNeeded(defaultProfileID)
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
        UserDefaults.standard.set(enabled, forKey: key)
        UserDefaults.standard.synchronize()
    }

    static func fingerprint(for profileID: String?) -> FingerprintProfile? {
        guard let profileID else {
            return nil
        }
        guard !isFingerprintDisabled(for: profileID) else {
            return nil
        }
        let key = profileFingerprintDefaultsPrefix + profileID
        guard let data = UserDefaults.standard.data(forKey: key),
              let fingerprint = try? JSONDecoder().decode(FingerprintProfile.self, from: data) else {
            return nil
        }
        return fingerprint
    }

    static func isFingerprintDisabled(for profileID: String) -> Bool {
        UserDefaults.standard.bool(forKey: profileFingerprintDisabledDefaultsPrefix + profileID)
    }

    static func setFingerprint(_ fingerprint: FingerprintProfile?, for profileID: String) {
        let key = profileFingerprintDefaultsPrefix + profileID
        let disabledKey = profileFingerprintDisabledDefaultsPrefix + profileID
        guard let fingerprint else {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: disabledKey)
            UserDefaults.standard.synchronize()
            return
        }
        guard let data = try? JSONEncoder().encode(fingerprint) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.removeObject(forKey: disabledKey)
        UserDefaults.standard.synchronize()
    }

    static func disableFingerprint(for profileID: String) {
        UserDefaults.standard.removeObject(forKey: profileFingerprintDefaultsPrefix + profileID)
        UserDefaults.standard.set(true, forKey: profileFingerprintDisabledDefaultsPrefix + profileID)
        UserDefaults.standard.synchronize()
    }
}

private enum PrivacySettings {
    static func isWebRTCProtectionRequested() -> Bool {
        if UserDefaults.standard.object(forKey: webRTCProtectionDefaultsKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: webRTCProtectionDefaultsKey)
    }

    static func isWebRTCProtectionEnabled() -> Bool {
        isWebRTCProtectionRequested()
    }

    static func setWebRTCProtectionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: webRTCProtectionDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    static func keepThirdPartyLinksInApp() -> Bool {
        if UserDefaults.standard.object(forKey: keepThirdPartyLinksInAppDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: keepThirdPartyLinksInAppDefaultsKey)
    }

    static func setKeepThirdPartyLinksInApp(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keepThirdPartyLinksInAppDefaultsKey)
        UserDefaults.standard.synchronize()
    }
}

private let webRTCBlockerScript = """
(() => {
  if (window.__wkRTCGuard) return;
        try {
          Object.defineProperty(window, '__wkRTCGuard', { value: true, configurable: false, writable: false });
        } catch (_) {}
        try {
          const markFake = window.__wkMarkNative || ((fn) => fn);
          const names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection', 'RTCIceCandidate', 'RTCSessionDescription', 'RTCDataChannel'];
          for (const name of names) {
            try {
              Object.defineProperty(window, name, { value: undefined, configurable: false, writable: false });
            } catch (_) {}
          }
          if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
            const original = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
            const enumerateDevices = function enumerateDevices() { return original().then(() => []); };
            markFake(enumerateDevices, 'enumerateDevices');
            navigator.mediaDevices.enumerateDevices = enumerateDevices;
          }
        } catch (_) {}
      })();
"""

private let privacySignalsScript = """
(() => {
  if (window.__wkPrivacySignals) return;
  try {
    Object.defineProperty(window, '__wkPrivacySignals', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const markFake = window.__wkMarkNative || ((fn) => fn);
  const defineBooleanGetter = (target, key, value) => {
    try {
      const getterName = 'get ' + key;
      const fn = { [getterName]: function () { return value; } }[getterName];
      markFake(fn, getterName);
      Object.defineProperty(target, key, { get: fn, configurable: true });
    } catch (_) {}
  };

  defineBooleanGetter(Navigator.prototype, 'globalPrivacyControl', true);
  defineBooleanGetter(navigator, 'globalPrivacyControl', true);
})();
"""

private let openAIPasskeyFallbackScript = """
(() => {
  if (window.__wkOpenAIPasskeyFallbackInstalled) return;

  const trustedHost = (host) => {
    const normalized = String(host || '').toLowerCase();
    return normalized === 'chatgpt.com'
      || normalized.endsWith('.chatgpt.com')
      || normalized === 'chat.openai.com'
      || normalized.endsWith('.chat.openai.com')
      || normalized === 'openai.com'
      || normalized.endsWith('.openai.com');
  };

  if (!trustedHost(location.hostname)) return;

  try {
    Object.defineProperty(window, '__wkOpenAIPasskeyFallbackInstalled', { value: true, configurable: false, writable: false });
    Object.defineProperty(window, '__wkOpenAIPasskeyFallbackActive', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const signalFallback = (reason) => {
    try {
      if (!window.__wkOpenAIPasskeyFallbackUsed) {
        Object.defineProperty(window, '__wkOpenAIPasskeyFallbackUsed', { value: true, configurable: true, writable: false });
      }
      window.__wkOpenAIPasskeyFallbackReason = String(reason || 'passkey');
      window.dispatchEvent(new CustomEvent('chatgpt-swift-passkey-fallback', { detail: { reason: window.__wkOpenAIPasskeyFallbackReason } }));
    } catch (_) {}
  };

  const unsupportedError = () => {
    try {
      return new DOMException('Passkey is unavailable in this local WKWebView wrapper. Use another sign-in method.', 'NotAllowedError');
    } catch (_) {
      const error = new Error('Passkey is unavailable in this local WKWebView wrapper. Use another sign-in method.');
      error.name = 'NotAllowedError';
      return error;
    }
  };

  try {
    Reflect.deleteProperty(window, 'PublicKeyCredential');
  } catch (_) {}

  try {
    if ('PublicKeyCredential' in window) {
      Object.defineProperty(window, 'PublicKeyCredential', {
        get: function () {
          signalFallback('PublicKeyCredential');
          return undefined;
        },
        configurable: true
      });
    }
  } catch (_) {}

  try {
    const credentials = navigator.credentials;
    if (!credentials) return;

    const originalGet = typeof credentials.get === 'function' ? credentials.get.bind(credentials) : null;
    const originalCreate = typeof credentials.create === 'function' ? credentials.create.bind(credentials) : null;

    const hasPublicKeyRequest = (options) => {
      try {
        return !!options && typeof options === 'object' && 'publicKey' in options;
      } catch (_) {
        return false;
      }
    };

    const get = function get(options) {
      if (hasPublicKeyRequest(options)) {
        signalFallback('navigator.credentials.get(publicKey)');
        return Promise.reject(unsupportedError());
      }
      return originalGet ? originalGet(options) : Promise.reject(unsupportedError());
    };

    const create = function create(options) {
      if (hasPublicKeyRequest(options)) {
        signalFallback('navigator.credentials.create(publicKey)');
        return Promise.reject(unsupportedError());
      }
      return originalCreate ? originalCreate(options) : Promise.reject(unsupportedError());
    };

    try {
      Object.defineProperty(credentials, 'get', { value: get, configurable: true, writable: true });
    } catch (_) {
      try { credentials.get = get; } catch (_) {}
    }
    try {
      Object.defineProperty(credentials, 'create', { value: create, configurable: true, writable: true });
    } catch (_) {
      try { credentials.create = create; } catch (_) {}
    }
  } catch (_) {}
})();
"""

private let passkeyLimitationNoticeScript = """
(() => {
  if (window.__wkPasskeyLimitationNoticeInstalled) return;
  try {
    Object.defineProperty(window, '__wkPasskeyLimitationNoticeInstalled', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const trustedHost = (host) => {
    const normalized = String(host || '').toLowerCase();
    return normalized === 'chatgpt.com'
      || normalized.endsWith('.chatgpt.com')
      || normalized === 'chat.openai.com'
      || normalized.endsWith('.chat.openai.com')
      || normalized === 'openai.com'
      || normalized.endsWith('.openai.com');
  };

  const fallbackActive = () => !!window.__wkOpenAIPasskeyFallbackActive;
  const fallbackUsed = () => !!window.__wkOpenAIPasskeyFallbackUsed;

  const pageLooksLikePasskey = () => {
    const href = String(location.href || '').toLowerCase();
    const text = String(document.body ? document.body.innerText || '' : '').toLowerCase();
    const urlSignal = href.includes('passkey')
      || href.includes('webauthn')
      || href.includes('security_key')
      || href.includes('publickeycredential')
      || href.includes('credential');
    const textSignal = text.includes('使用密钥继续')
      || text.includes('通行密钥')
      || text.includes('帐户的密钥')
      || text.includes('账户的密钥')
      || text.includes('passkey to continue')
      || text.includes('continue with passkey')
      || text.includes('use your passkey')
      || text.includes('we found a passkey')
      || text.includes('security key to continue')
      || text.includes('use your security key');
    return urlSignal || textSignal;
  };

  const pageLooksLikeAuthFallback = () => {
    const href = String(location.href || '').toLowerCase();
    return fallbackActive() && (
      fallbackUsed()
      || href.includes('auth')
      || href.includes('login')
      || href.includes('signin')
      || href.includes('verify')
      || href.includes('verification')
      || href.includes('challenge')
      || href.includes('continue')
      || href.includes('credential')
      || href.includes('passkey')
      || href.includes('webauthn')
    );
  };

  const showNotice = () => {
    if (!trustedHost(location.hostname) || (!pageLooksLikePasskey() && !pageLooksLikeAuthFallback())) return;
    if (document.getElementById('chatgpt-swift-passkey-notice')) return;
    if (!document.body || window.__wkPasskeyLimitationNoticeDismissed) return;

    const notice = document.createElement('aside');
    notice.id = 'chatgpt-swift-passkey-notice';
    notice.setAttribute('role', 'status');
    notice.style.cssText = [
      'position:fixed',
      'top:18px',
      'left:50%',
      'transform:translateX(-50%)',
      'z-index:2147483647',
      'box-sizing:border-box',
      'width:min(760px,calc(100vw - 32px))',
      'padding:14px 44px 14px 16px',
      'border:1px solid rgba(255,255,255,.16)',
      'border-radius:10px',
      'background:rgba(17,17,17,.96)',
      'color:#fff',
      'box-shadow:0 14px 40px rgba(0,0,0,.22)',
      'font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
      'text-align:left'
    ].join(';');

    const title = document.createElement('div');
    title.textContent = fallbackActive()
      ? (fallbackUsed() ? '已阻止这个页面调用 passkey / WebAuthn。' : '已为这个本地 WKWebView 关闭 passkey / WebAuthn。')
      : '这个本地 WKWebView wrapper 不能使用 chatgpt.com / openai.com 的 Apple 通行密钥。';
    title.style.cssText = 'font-weight:650;margin:0 0 4px';
    notice.appendChild(title);

    const detail = document.createElement('div');
    detail.textContent = fallbackActive()
      ? '请继续使用邮箱验证码、密码或“尝试其他方法”。如必须用通行密钥，请改用 Safari、Chrome 或官方 ChatGPT App。'
      : '请点“尝试其他方法”，或用 Safari、Chrome、官方 ChatGPT App 完成 passkey 登录。';
    detail.style.cssText = 'color:rgba(255,255,255,.78);margin:0';
    notice.appendChild(detail);

    const close = document.createElement('button');
    close.type = 'button';
    close.setAttribute('aria-label', '关闭提示');
    close.textContent = '×';
    close.style.cssText = [
      'position:absolute',
      'top:8px',
      'right:10px',
      'width:28px',
      'height:28px',
      'border:0',
      'border-radius:999px',
      'background:rgba(255,255,255,.12)',
      'color:#fff',
      'font:20px/26px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
      'cursor:pointer'
    ].join(';');
    close.addEventListener('click', () => {
      window.__wkPasskeyLimitationNoticeDismissed = true;
      notice.remove();
    });
    notice.appendChild(close);

    document.body.appendChild(notice);
  };

  const schedule = () => window.requestAnimationFrame(showNotice);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', schedule, { once: true });
  } else {
    schedule();
  }
  window.addEventListener('chatgpt-swift-passkey-fallback', schedule);
  window.setTimeout(schedule, 1000);
  window.setTimeout(schedule, 3000);

  try {
    const observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, { childList: true, subtree: true });
    window.setTimeout(() => observer.disconnect(), 15000);
  } catch (_) {}
})();
"""

private let nativeShimScript = """
(() => {
  if (window.__wkNativeShim) return;
  try {
    Object.defineProperty(window, '__wkNativeShim', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const origToString = Function.prototype.toString;
  const fakeMap = new WeakMap();

  const patchedToString = function toString() {
    try {
      if (fakeMap.has(this)) return fakeMap.get(this);
    } catch (_) {}
    return origToString.call(this);
  };

  try {
    fakeMap.set(patchedToString, 'function toString() { [native code] }');
    fakeMap.set(origToString, 'function toString() { [native code] }');
  } catch (_) {}

  try {
    Object.defineProperty(Function.prototype, 'toString', {
      value: patchedToString,
      writable: true,
      configurable: true
    });
  } catch (_) {}

  const markFake = (fn, name) => {
    try {
      if (typeof fn === 'function' && typeof name === 'string') {
        fakeMap.set(fn, 'function ' + name + '() { [native code] }');
      }
    } catch (_) {}
    return fn;
  };
  markFake(markFake, 'markFake');

  try {
    Object.defineProperty(window, '__wkMarkNative', {
      value: markFake,
      writable: false,
      configurable: false
    });
  } catch (_) {}
})();
"""

private let applicationDelegate = AppDelegate()

SingleInstance.activateExistingInstanceOrAcquireLock()

let app = NSApplication.shared
app.delegate = applicationDelegate
app.run()

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
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
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
