import AppKit
import ChatGPTSwiftWebCore
import Darwin
import Foundation
import OSLog
import Sparkle
import UniformTypeIdentifiers
import UserNotifications
import WebKit

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
    private var updateCheckStatus = "未检查；未配置 Sparkle 时会回退到 GitHub Releases 检查。"
    private var didFinishLaunchingAt: Date?
    private var previousRunSummary = "未记录"
    private var notificationPermissionStatus = "未检查"
    private let performanceMonitor = ProcessPerformanceMonitor()
    private let completionNotificationService = CompletionNotificationService(
        scheduler: SystemCompletionNotificationScheduler()
    )
    private var sparkleUpdaterController: SPUStandardUpdaterController?
    private var sparkleStatus = "未启用：Info.plist 未提供 SUFeedURL / SUPublicEDKey"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let smokeTestRun = SmokeTestEnvironment.isEnabled
        didFinishLaunchingAt = Date()
        if smokeTestRun {
            previousRunSummary = "smoke test run"
        } else {
            capturePreviousRunState()
            markRunStarted()
        }
        performanceMonitor.start()
        UNUserNotificationCenter.current().delegate = self
        refreshNotificationPermissionStatus()
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        configureSparkleUpdaterIfAvailable()
        installKeyboardZoomShortcuts()
        let needsIsolationFallbackNotice = smokeTestRun ? false : reconcileProfileIsolationOnLaunch()
        if !smokeTestRun {
            ProfileStore.applyStartupProfileIfAvailable()
            ProfileStore.ensurePrivacyBaseline()
        }

        let profile = smokeTestRun ? nil : ProfileStore.currentProfile()
        let controller = BrowserWindowController(
            initialURL: smokeTestRun ? chatGPTURL : ProfileStore.homepageURL(for: profile?.id ?? defaultProfileID),
            title: profile.map(mainWindowTitle(for:)) ?? "ChatGPT Swift Smoke Test",
            isPopup: false,
            persistent: !smokeTestRun,
            profileID: profile?.id
        )
        mainController = controller
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
        scheduleSmokeTestIfRequested()

        if !smokeTestRun,
           BrowserPerformancePolicy.shouldRefreshExitTimezoneCache(
               hasExplicitFingerprint: ProfileStore.fingerprint(for: profile?.id) != nil
           ) {
            refreshExitTimezoneCache()
        }

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
        performanceMonitor.stop()
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
    }

    private func markRunEndedCleanly() {
        let defaults = UserDefaults.standard
        defaults.set(Date(), forKey: lastRunEndedAtDefaultsKey)
        defaults.set(true, forKey: lastRunCleanExitDefaultsKey)
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

    private func configureSparkleUpdaterIfAvailable() {
        guard Self.hasSparkleConfiguration() else {
            sparkleUpdaterController = nil
            sparkleStatus = "未启用：Info.plist 未提供 SUFeedURL / SUPublicEDKey"
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        sparkleUpdaterController = controller
        sparkleStatus = "已启用：Sparkle 自动检查按自身调度执行"
    }

    private static func hasSparkleConfiguration() -> Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme?.lowercased() == "https",
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return true
    }

    func postBackgroundCompletionNotification(from controller: BrowserWindowController) {
        completionNotificationService.postIfAuthorized(
            enabled: BackgroundCompletionNotifications.isEnabled(),
            context: controller.notificationContextText()
        ) { [weak self] outcome in
            switch outcome {
            case .notAuthorized(let status):
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.notificationPermissionStatus = Self.notificationStatusText(status)
                    if status == .denied {
                        BackgroundCompletionNotifications.setEnabled(false)
                    }
                    self.refreshNativeUtilityWindows()
                }
            case .failed(let message):
                browserLogger.error("Failed to post background completion notification: \(message, privacy: .public)")
            case .disabled, .scheduled:
                break
            }
        }
    }

    private static func notificationStatusText(_ status: CompletionNotificationAuthorization) -> String {
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
        case .unknown:
            return "未知"
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
        let notesContextItem = editMenu.addItem(withTitle: "插入选中备忘录正文", action: #selector(insertNotesContextAction(_:)), keyEquivalent: "")
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
                    setWindowTitleDisplayMode: { [weak self] mode in
                        self?.setWindowTitleDisplayModeFromSettings(mode)
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
                        self?.checkForUpdatesFromUserAction(nil)
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
        checkForUpdatesFromUserAction(sender)
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

    private func setWindowTitleDisplayModeFromSettings(_ mode: WindowTitleDisplayMode) {
        WindowTitleSettings.setMode(mode)
        BrowserWindowController.refreshWindowTitles()
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

    private func scheduleSmokeTestIfRequested() {
        guard let rawPath = SmokeTestEnvironment.reportPath else {
            return
        }

        let timeout = ProcessInfo.processInfo.environment[smokeTimeoutEnvironmentKey].flatMap(Double.init) ?? 25
        let boundedTimeout = min(max(timeout, 5), 120)
        let reportURL = URL(fileURLWithPath: rawPath)
        let deadline = Date().addingTimeInterval(boundedTimeout)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.runSmokeTestAttempt(reportURL: reportURL, deadline: deadline)
        }
    }

    private func runSmokeTestAttempt(reportURL: URL, deadline: Date) {
        guard let controller = mainController else {
            finishSmokeTest(reportURL: reportURL, passed: false, report: "mainController=nil")
            return
        }

        controller.runSmokeTestProbe { [weak self] passed, report in
            guard let self else {
                return
            }
            if passed || Date() >= deadline {
                self.finishSmokeTest(reportURL: reportURL, passed: passed, report: report)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runSmokeTestAttempt(reportURL: reportURL, deadline: deadline)
            }
        }
    }

    private func finishSmokeTest(reportURL: URL, passed: Bool, report: String) {
        let status = passed ? "pass" : "fail"
        let body = """
        SMOKE_STATUS=\(status)
        generatedAt=\(Self.timestampString(Date()))
        \(report)
        """

        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: reportURL, atomically: true, encoding: .utf8)
        } catch {
            browserLogger.error("Failed to write smoke test report: \(error.localizedDescription, privacy: .public)")
        }

        NSApp.terminate(nil)
    }

    private func openNotesAutomationPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openReleasePage() {
        NSWorkspace.shared.open(releasePageURL)
    }

    private func checkForUpdatesFromUserAction(_ sender: Any?) {
        if let sparkleUpdaterController {
            updateCheckStatus = "已交给 Sparkle 检查更新；\(sparkleStatus)。当前版本：\(Self.appVersionText())。"
            refreshNativeUtilityWindows()
            sparkleUpdaterController.checkForUpdates(sender)
            return
        }

        checkForUpdates(showAlert: true)
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
                    self.updateCheckStatus = "最新发布：\(title)\(date)。当前版本：\(Self.appVersionText())。\(self.sparkleStatus)，GitHub Releases 仅用于手动查看。"
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
            windowTitleDisplayMode: WindowTitleSettings.mode(),
            notesAutomationStatus: "按需请求；首次插入选中备忘录正文时由 macOS 弹出授权。",
            updateStatus: updateCheckStatus,
            distributionStatus: "\(sparkleStatus)。本地构建已走 codesign；Developer ID 分发需执行 packaging/notarize-dmg.sh 并 stapler。"
        )
    }

    private func makeDiagnosticsState() -> AppDiagnosticsState {
        let generatedAt = Self.timestampString(Date())
        return AppDiagnosticsState(generatedAt: generatedAt, report: makeDiagnosticsReport(generatedAt: generatedAt))
    }

    private func exportDiagnosticsPackage(_ state: AppDiagnosticsState) {
        let panel = NSSavePanel()
        panel.title = "导出诊断包"
        panel.message = "导出默认脱敏后的当前诊断、最近 10 分钟本 App 统一日志和崩溃报告。不会主动读取 cookies、localStorage 或聊天正文；账号名、会话标题、完整 URL、邮箱和用户主目录会按已知模式脱敏。分享前仍请检查包内文本。"
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
                note: This package does not intentionally read cookies, localStorage, IndexedDB, or chat transcript content. App diagnostics remove profile names, page titles, and full page URLs; logs and crash reports redact known URL, email, and user-home patterns. Review the text before sharing.
                """
                try manifest.write(
                    to: packageDir.appendingPathComponent("manifest.txt"),
                    atomically: true,
                    encoding: .utf8
                )

                let performanceCSV = self?.performanceMonitor.csvText() ?? "timestamp,cpu_percent_one_core,resident_bytes,footprint_bytes\n"
                try performanceCSV.write(
                    to: packageDir.appendingPathComponent("performance-samples.csv"),
                    atomically: true,
                    encoding: .utf8
                )

                let crashReports = Self.recentCrashReportURLs(limit: 5)
                if !crashReports.isEmpty {
                    let crashReportDir = packageDir.appendingPathComponent("crash-reports", isDirectory: true)
                    try fileManager.createDirectory(at: crashReportDir, withIntermediateDirectories: true)
                    for reportURL in crashReports {
                        let destination = crashReportDir.appendingPathComponent(reportURL.lastPathComponent)
                        let reportData = try Data(contentsOf: reportURL)
                        guard let reportText = String(data: reportData, encoding: .utf8) else {
                            continue
                        }
                        try DiagnosticRedactor.text(reportText).write(
                            to: destination,
                            atomically: true,
                            encoding: .utf8
                        )
                    }
                }

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
                try DiagnosticRedactor.text(logText).write(
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
        let profileLabel = DiagnosticRedactor.profileLabel(isDefault: profile.id == defaultProfileID)
        let startupProfileLabel = ProfileStore.startupProfileID() == defaultProfileID
            ? defaultProfileID
            : "<custom-profile>"
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
            ("最近崩溃报告", Self.crashReportSummary(limit: 5)),
        ]))

        sections.append(Self.diagnosticSection("性能趋势", performanceMonitor.diagnosticRows()))

        sections.append(Self.diagnosticSection("账号空间 / 隐私", [
            ("当前空间", profileLabel),
            ("首页", DiagnosticRedactor.url(ProfileStore.homepageURL(for: profile.id))),
            ("启动默认空间", startupProfileLabel),
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
            ("Sparkle", sparkleStatus),
            ("发行页", releasePageURL.absoluteString),
            ("notarization", "运行时不能证明 DMG 是否已 stapled；用 packaging/notarize-dmg.sh / spctl / stapler 验证。"),
        ]))

        return DiagnosticRedactor.text(sections.joined(separator: "\n\n"))
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

    private static func recentCrashReportURLs(limit: Int) -> [URL] {
        let diagnosticReportsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let reportURLs = try? FileManager.default.contentsOfDirectory(
            at: diagnosticReportsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return reportURLs
            .filter { url in
                let name = url.lastPathComponent
                return name.contains("ChatGPTSwiftWeb")
                    && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
            }
            .sorted { lhs, rhs in
                Self.fileModificationDate(lhs) > Self.fileModificationDate(rhs)
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func crashReportSummary(limit: Int) -> String {
        let reports = recentCrashReportURLs(limit: limit)
        guard !reports.isEmpty else {
            return "无"
        }
        return reports.map { url in
            "\(url.lastPathComponent)（\(Self.timestampString(Self.fileModificationDate(url)))）"
        }.joined(separator: "\n")
    }

    private static func fileModificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
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
            title: ProfileWindowTitle.format(
                profileName: "无痕",
                isDefault: false,
                mode: WindowTitleSettings.mode()
            ),
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

    /// Refresh the optional fingerprint's exit timezone for the next WebView. Never rebuild a live
    /// session after launch: changing browser characteristics mid-session invalidates challenge state
    /// and turns an otherwise background lookup into a visible second page load.
    private func refreshExitTimezoneCache() {
        GeoIPResolver.refresh()
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
        ProfileWindowTitle.format(
            profileName: profile.name,
            isDefault: profile.id == defaultProfileID,
            mode: WindowTitleSettings.mode()
        )
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
        NavigationRules.validatedExternalURL(raw)
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
