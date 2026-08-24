import AppKit
import AVFoundation
import ChatGPTSwiftWebCore
import Darwin
import Foundation
import OSLog
import Sparkle
import UniformTypeIdentifiers
import UserNotifications
import WebKit

final class BrowserWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private static var controllers: [BrowserWindowController] = []

    static func disposeControllers(for profileID: String, completion: @escaping () -> Void = {}) {
        let matchingControllers = controllers.filter { $0.profileID == profileID }
        guard !matchingControllers.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        matchingControllers.forEach { controller in
            group.enter()
            controller.dispose {
                group.leave()
            }
        }
        group.notify(queue: .main, execute: completion)
    }

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
    var isDisposing = false
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    private var remoteImageLoaders: [UUID: RemoteImageLoader] = [:]
    private var didTearDownWebView = false
    private var didFinishWindowClose = false
    // All asynchronous writes to this controller's WebKit store are drained before a destructive
    // profile mutation removes the store.  Cookie consent is one such write, but imports, pruning,
    // and profile cloning also need the same lifetime boundary.
    private let websiteDataMutationGroup = DispatchGroup()
    private let ownsNativeMessageHandlers: Bool
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
    var isCloudflareChallengeActive = false
    private var isAssistantResponseInProgress = false
    private var lastCompletionObservationSummary = "未运行"
    private var lastBackgroundCompletionNotificationAt: Date?
    private var framePersistenceWorkItem: DispatchWorkItem?
    var isNativeChromeUpdateScheduled = false
    var lastPresentedStatusText: String?
    var lastPresentedStatusShowsProgress = false
    var lastPresentedProgressPercent = -1
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
        self.ownsNativeMessageHandlers = configuration == nil
        super.init()
        Self.controllers.append(self)

        let webConfiguration = configuration ?? Self.makeConfiguration(messageHandler: self, persistent: persistent, profileID: profileID)
        let fingerprint = ProfileStore.fingerprint(for: profileID)
        if fingerprint == nil {
            // Popup configurations supplied by WKUIDelegate do not pass through makeConfiguration;
            // apply the same engine-consistent Safari product token to every native-profile WebView.
            webConfiguration.applicationNameForUserAgent = SafariUserAgentPolicy.currentApplicationName
        }

        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        if let fingerprint {
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
            let initialRequest = Self.privacyRequest(for: initialURL, sourceURL: nil, profileID: profileID)
            let consentGroup = websiteDataMutationGroup
            consentGroup.enter()
            applyDefaultCookieConsent { [weak self] in
                consentGroup.leave()
                guard let self, !self.isDisposing else {
                    return
                }
                self.webView.load(initialRequest)
            }
        }

        updateNativeChromeStatus()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        scheduleRenderedContentProbe(reason: "window shown", delay: 1.5)
    }

    @objc func reload(_ sender: Any?) {
        guard !isDisposing else { return }
        if isShowingBlankContent {
            setStatus("正在恢复空白页面…", showsProgress: true)
            recoverFromBlankContent(reason: "reload action")
            return
        }

        // Reload immediately instead of waiting for a JS probe round-trip: when the page's main
        // thread is busy (exactly when users reach for reload) the probe callback is delayed and the
        // reload feels stuck. Blank pages are still caught by the scheduled post-navigation probe.
        webView.reload()
    }

    /// True when the web view has no live, loaded content — the content process crashed, a provisional
    /// load failed, or nothing ever loaded. In these states `reload()` is a no-op and the view stays blank.
    var isShowingBlankContent: Bool {
        webView.url == nil || webView.backForwardList.currentItem == nil || lastRenderProbeWasBlank
    }

    /// Re-issue a full load (restarting a dead content process) instead of refreshing the back-forward
    /// list. Falls back to the profile homepage when there is no current URL to recover.
    func hardReload(ignoringCache: Bool = false) {
        guard !isDisposing else { return }
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
        guard !isDisposing else { return }
        guard webView.canGoBack else {
            return
        }
        webView.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        guard !isDisposing else { return }
        guard webView.canGoForward else {
            return
        }
        webView.goForward()
    }

    @objc func goHome(_ sender: Any?) {
        guard !isDisposing else { return }
        let target = ProfileStore.homepageURL(for: profileID ?? ProfileStore.currentProfileID())
        webView.stopLoading()
        webView.load(Self.privacyRequest(for: target, sourceURL: nil, profileID: profileID))
    }

    @objc func openCurrentURLInSystemBrowser(_ sender: Any?) {
        let target = webView.url ?? ProfileStore.homepageURL(for: profileID ?? ProfileStore.currentProfileID())
        guard let safeTarget = NavigationRules.sanitizedUserFacingURL(target, sourceURL: webView.url) else {
            presentError("当前页面不是可安全交给系统浏览器的 HTTPS 地址。登录临时参数不会被外带。")
            return
        }
        if safeTarget != target {
            setStatus("已移除登录临时参数后打开", showsProgress: false)
        }
        NSWorkspace.shared.open(safeTarget)
    }

    func navigate(to url: URL) {
        guard !isDisposing else { return }
        webView.load(Self.privacyRequest(for: url, sourceURL: webView.url, profileID: profileID))
    }

    func currentURL() -> URL? {
        webView.url
    }

    func applyDefaultCookieConsent(completion: @escaping () -> Void) {
        let dataStore = webView.configuration.websiteDataStore
        CookieConsentSettings.applyIfEnabled(
            to: dataStore,
            completion: {
                // The preference can change while WebKit is asynchronously writing the four
                // managed cookies. Re-read it at the end and remove a stale batch before the
                // first page load, so disabling the default cannot leave a rejection cookie behind.
                if CookieConsentSettings.isEnabled() {
                    completion()
                } else {
                    CookieConsentSettings.clearManagedRejectionCookies(
                        from: dataStore,
                        completion: completion
                    )
                }
            }
        )
    }

    func notificationContextText() -> String {
        // Notification bodies are visible outside the app (including on a lock screen). Never
        // copy a conversation title, URL, or account name into that channel.
        return "ChatGPT"
    }

    func diagnosticsReport() -> String {
        let frame = window.frame
        let currentItemURL = webView.backForwardList.currentItem?.url
        let profileLabel = DiagnosticRedactor.profileLabel(
            isDefault: profileID == nil || profileID == defaultProfileID,
            persistent: persistent
        )
        let rows: [(String, String)] = [
            ("窗口标题", isPopup ? "弹窗（标题已脱敏）" : "ChatGPT Swift"),
            ("窗口 frame", "x=\(Int(frame.origin.x)), y=\(Int(frame.origin.y)), w=\(Int(frame.size.width)), h=\(Int(frame.size.height))"),
            ("窗口类型", isPopup ? "弹窗" : "主窗口"),
            ("持久数据", persistent ? "是" : "否"),
            ("空间", profileLabel),
            ("当前 URL", webView.url.map(Self.loggableURL) ?? "nil"),
            ("历史当前项", currentItemURL.map(Self.loggableURL) ?? "nil"),
            ("标题", DiagnosticRedactor.pageTitle(webView.title)),
            ("isLoading", webView.isLoading ? "true" : "false"),
            ("estimatedProgress", String(format: "%.3f", webView.estimatedProgress)),
            ("canGoBack / canGoForward", "\(webView.canGoBack) / \(webView.canGoForward)"),
            ("zoom", "\(Int(round(currentZoom * 100)))%"),
            ("isShowingBlankContent", isShowingBlankContent ? "true" : "false"),
            ("lastRenderProbeWasBlank", lastRenderProbeWasBlank ? "true" : "false"),
            ("lastRenderProbe", DiagnosticRedactor.text(lastRenderProbeSummary)),
            ("blankRecoveryAttempts", "\(blankRecoveryAttempts)"),
            ("lastBlankRecovery", DiagnosticRedactor.text(lastBlankRecoverySummary)),
            ("nativeStatusOverlay", DiagnosticRedactor.text(currentOverlayMode.diagnosticDescription)),
            ("webContentProcessTerminationCount", "\(webContentProcessTerminationCount)"),
            ("navigationFailureCount", "\(navigationFailureCount)"),
            ("lastNavigationFailure", DiagnosticRedactor.text(lastNavigationFailureDescription)),
            ("controllerCreatedAt", Self.diagnosticDateString(controllerCreatedAt)),
            ("firstNavigationFinishedAt", Self.diagnosticDateString(firstNavigationFinishedAt)),
            ("lastNavigationStartedAt", Self.diagnosticDateString(lastNavigationStartedAt)),
            ("lastNavigationFinishedAt", Self.diagnosticDateString(lastNavigationFinishedAt)),
            ("lastNavigationDuration", Self.diagnosticDurationString(from: lastNavigationStartedAt, to: lastNavigationFinishedAt)),
            ("cloudflareChallengeActive", isCloudflareChallengeActive ? "true" : "false"),
            ("assistantResponseInProgress", isAssistantResponseInProgress ? "true" : "false"),
            ("lastCompletionObservation", lastCompletionObservationSummary),
            ("lastBackgroundCompletionNotificationAt", Self.diagnosticDateString(lastBackgroundCompletionNotificationAt)),
            ("userAgent override", webView.customUserAgent ?? "nil"),
        ]
        return Self.diagnosticSection("WebView", rows)
    }

    func runSmokeTestProbe(completion: @escaping (Bool, String) -> Void) {
        runRenderedContentProbe(reason: "smoke test", recoverIfBlank: false) { [weak self] _ in
            guard let self else {
                completion(false, "controller=deallocated")
                return
            }
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                DispatchQueue.main.async {
                    guard let self else {
                        completion(false, "controller=deallocated")
                        return
                    }
                    let snapshot = self.smokeTestSnapshot()
                    let consentDefaultEnabled = CookieConsentSettings.isEnabled()
                    let rejectionApplied = CookieConsentSettings.rejectionIsApplied(in: cookies)
                    let consentHealthy = !consentDefaultEnabled || rejectionApplied
                    let consentState = consentDefaultEnabled ? String(rejectionApplied) : "disabled"
                    let report = snapshot.report + "\ncookieConsentRejectionApplied=\(consentState)"
                    completion(snapshot.passed && consentHealthy, report)
                }
            }
        }
    }

    private func smokeTestSnapshot() -> (passed: Bool, report: String) {
        let overlayHealthy: Bool
        switch currentOverlayMode {
        case .hidden:
            overlayHealthy = true
        case .recovering, .failed, .blank:
            overlayHealthy = false
        }

        let windowVisible = window?.isVisible == true
        let currentItemURL = webView.backForwardList.currentItem?.url
        let hasContentAddress = webView.url != nil || currentItemURL != nil
        let renderProbeSucceeded = lastRenderProbeSummary.hasPrefix("blank=")
        let renderProbeNonBlank = renderProbeSucceeded && !lastRenderProbeWasBlank
        let diagnosticsHealthy = navigationFailureCount == 0
            && webContentProcessTerminationCount == 0
            && overlayHealthy
            && !isCloudflareChallengeActive
        let passed = windowVisible
            && hasContentAddress
            && !webView.isLoading
            && renderProbeNonBlank
            && diagnosticsHealthy

        let rows = [
            "windowVisible=\(windowVisible)",
            "currentURL=\(webView.url.map(Self.loggableURL) ?? "nil")",
            "historyCurrentURL=\(currentItemURL.map(Self.loggableURL) ?? "nil")",
            "title=\(DiagnosticRedactor.pageTitle(webView.title))",
            "isLoading=\(webView.isLoading)",
            "estimatedProgress=\(String(format: "%.3f", webView.estimatedProgress))",
            "renderProbeSucceeded=\(renderProbeSucceeded)",
            "renderProbeNonBlank=\(renderProbeNonBlank)",
            "lastRenderProbeWasBlank=\(lastRenderProbeWasBlank)",
            "lastRenderProbe=\(DiagnosticRedactor.text(lastRenderProbeSummary))",
            "diagnosticsHealthy=\(diagnosticsHealthy)",
            "nativeStatusOverlay=\(DiagnosticRedactor.text(currentOverlayMode.diagnosticDescription))",
            "cloudflareChallengeActive=\(isCloudflareChallengeActive)",
            "navigationFailureCount=\(navigationFailureCount)",
            "lastNavigationFailure=\(DiagnosticRedactor.text(lastNavigationFailureDescription))",
            "webContentProcessTerminationCount=\(webContentProcessTerminationCount)",
        ]
        return (passed, rows.joined(separator: "\n"))
    }

    func loadFingerprintTestPage() {
        webView.stopLoading()
        webView.loadHTMLString(Self.fingerprintTestShellHTML, baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.renderFingerprintReport()
        }
    }

    func copyCookies(toProfileID targetProfileID: String, completion: @escaping (Int, Int, Bool) -> Void) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            completion(0, 0, false)
            return
        }

        let operationGroup = websiteDataMutationGroup
        operationGroup.enter()
        let completionLock = NSLock()
        var didFinishOperation = false
        let finishOperation = {
            completionLock.lock()
            let shouldLeave = !didFinishOperation
            didFinishOperation = true
            completionLock.unlock()
            if shouldLeave {
                operationGroup.leave()
            }
        }

        let sourceStore = webView.configuration.websiteDataStore.httpCookieStore
        let targetStore = Self.resolveDataStore(persistent: true, profileID: targetProfileID).httpCookieStore

        sourceStore.getAllCookies { [weak self] cookies in
            guard let self, !self.isDisposing, ProfileStore.pendingDataMutation == nil else {
                finishOperation()
                DispatchQueue.main.async {
                    completion(0, 0, false)
                }
                return
            }
            let transferableCookies = BrowserDataBoundary.transferableCookies(cookies)
            guard !transferableCookies.isEmpty else {
                finishOperation()
                DispatchQueue.main.async {
                    completion(0, 0, false)
                }
                return
            }

            let boundedCookies = Self.boundedCookiesForProfileTransfer(transferableCookies)
            let skippedCount = transferableCookies.count - boundedCookies.count
            let boundedIdentities = Set(boundedCookies.map(CookieIdentity.init))
            let essentialSkipped = transferableCookies.contains { cookie in
                CookieImportParser.isEssentialCookieName(cookie.name)
                    && !boundedIdentities.contains(CookieIdentity(cookie))
            }
            guard !boundedCookies.isEmpty else {
                finishOperation()
                DispatchQueue.main.async {
                    completion(0, skippedCount, essentialSkipped)
                }
                return
            }

            let group = DispatchGroup()
            for cookie in boundedCookies {
                group.enter()
                targetStore.setCookie(cookie) {
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                finishOperation()
                completion(boundedCookies.count, skippedCount, essentialSkipped)
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
        panel.message = "仅导出 ChatGPT/OpenAI cookie。导出的文件等同登录凭证，请保存到本机私密位置。"
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

            let exportableCookies = BrowserDataBoundary.transferableCookies(cookies)
            guard !exportableCookies.isEmpty else {
                self.presentError("当前账号空间内没有可导出的 cookie。")
                return
            }

            let exported = exportableCookies.map { ExportedBrowserCookie(cookie: $0) }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(exported)
                try BrowserDataBoundary.writeSensitiveData(data, to: url)
                self.presentInfo("已导出 \(exportableCookies.count) 个 ChatGPT/OpenAI cookie。文件等同登录凭证，请勿上传或同步到不可信位置。")
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

    func confirmBurnCurrentProfileData(
        onCancel: @escaping () -> Void = {},
        completion: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "焚烧当前空间？"
        alert.informativeText = "这会删除当前空间在本 App WebView 内所有站点的 cookies、缓存、localStorage、IndexedDB、Service Worker 等网站数据和本机未发送草稿，关闭当前空间弹窗，清空页面历史，重建浏览器视图，并恢复默认 Safari 指纹。\n\n会保留：空间名称、首页、增强隐私设置。其他空间不受影响。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "焚烧并重建")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                onCancel()
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

        cancelScheduledMainWindowFramePersistence()
        persistMainWindowFrame()
        window.orderOut(nil)
        return false
    }

    func dispose(completion: @escaping () -> Void = {}) {
        cancelScheduledMainWindowFramePersistence()
        cancelRemoteImageLoads()
        webViewObservations.removeAll()
        childControllers.forEach { $0.window.close() }
        childControllers.removeAll()
        closeHandler = nil
        isDisposing = true
        tearDownWebView()
        // Remove the live document after its native bridges are detached. This prevents page timers
        // and queued bridge messages from continuing to target the persistent store while a caller
        // waits for websiteDataMutationGroup before deleting it.
        webView.loadHTMLString("", baseURL: nil)
        window.close()
        websiteDataMutationGroup.notify(queue: .main) { [weak self] in
            self?.finishWindowClose()
            completion()
        }
    }

    func windowDidMove(_ notification: Notification) {
        scheduleMainWindowFramePersistence()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleMainWindowFramePersistence()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        cancelScheduledMainWindowFramePersistence()
        persistMainWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleRenderedContentProbe(reason: "window activation", delay: 0.8)
    }

    func windowWillClose(_ notification: Notification) {
        cancelScheduledMainWindowFramePersistence()
        cancelRemoteImageLoads()
        persistMainWindowFrame()
        isDisposing = true
        tearDownWebView()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        websiteDataMutationGroup.notify(queue: .main) { [weak self] in
            self?.finishWindowClose()
        }
    }

    private func finishWindowClose() {
        guard !didFinishWindowClose else {
            return
        }
        didFinishWindowClose = true
        Self.controllers.removeAll { $0 === self }
        let handler = closeHandler
        closeHandler = nil
        handler?()
    }

    private func tearDownWebView() {
        guard !didTearDownWebView else {
            return
        }
        didTearDownWebView = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        guard ownsNativeMessageHandlers else {
            return
        }
        let userContentController = webView.configuration.userContentController
        for name in ["downloadBlob", "promptDraft", "completionState"] {
            userContentController.removeScriptMessageHandler(forName: name)
        }
        userContentController.removeAllUserScripts()
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
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
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

            let isChallenge = Self.boolValue(report["cloudflareChallenge"])
            let isBlank = !isChallenge && Self.boolValue(report["blank"])
            isCloudflareChallengeActive = isChallenge
            lastRenderProbeWasBlank = isBlank
            let readyState = report["readyState"] as? String ?? "unknown"
            let textLength = Self.intValue(report["textLength"])
            let visibleElements = Self.intValue(report["visibleElements"])
            let bodyChildren = Self.intValue(report["bodyChildren"])
            lastRenderProbeSummary = "blank=\(isBlank), cloudflareChallenge=\(isChallenge), readyState=\(readyState), textLength=\(textLength), visibleElements=\(visibleElements), bodyChildren=\(bodyChildren)"
            updateNativeChromeStatus()

            if isChallenge {
                blankRecoveryAttempts = 0
                hideStatusOverlayIfTransient()
                setStatus("正在完成人机验证…", showsProgress: false)
            } else if isBlank {
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
        guard BrowserPerformancePolicy.shouldPersistWindowFrame(persistent: persistent, isPopup: isPopup),
              window != nil else {
            return
        }

        let frame = window.frame
        UserDefaults.standard.set([
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height,
        ], forKey: mainFrameDefaultsKey)
    }

    private func scheduleMainWindowFramePersistence() {
        guard BrowserPerformancePolicy.shouldPersistWindowFrame(persistent: persistent, isPopup: isPopup) else {
            return
        }

        framePersistenceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isDisposing else {
                return
            }
            self.framePersistenceWorkItem = nil
            self.persistMainWindowFrame()
        }
        framePersistenceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BrowserPerformancePolicy.windowFramePersistenceDelay,
            execute: workItem
        )
    }

    private func cancelScheduledMainWindowFramePersistence() {
        framePersistenceWorkItem?.cancel()
        framePersistenceWorkItem = nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
        lastNavigationStartedAt = Date()
        lastRenderProbeWasBlank = false
        isCloudflareChallengeActive = false
        invalidateRenderedContentProbes()
        if case .recovering = currentOverlayMode {
            statusOverlay?.update(mode: currentOverlayMode)
        } else {
            showStatusOverlay(.hidden)
        }
        startLoadingWatchdog(reason: "navigation started")
        updateNativeChromeStatus()
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            decisionHandler(.cancel)
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let sourceURL = webView.url
        let cleanedURL = Self.cleanTrackingParameters(from: url)

        guard NavigationRules.isAllowedWebViewNavigationURL(cleanedURL, sourceURL: sourceURL) else {
            setStatus("已阻止不安全的导航协议或凭据链接", showsProgress: false)
            decisionHandler(.cancel)
            return
        }

        if NavigationRules.shouldBlockInsecureThirdPartyNavigation(cleanedURL, sourceURL: sourceURL) {
            setStatus("已阻止明文第三方链接", showsProgress: false)
            decisionHandler(.cancel)
            return
        }

        if #available(macOS 11.3, *),
           navigationAction.shouldPerformDownload,
           navigationAction.navigationType == .linkActivated,
           Self.isTrustedChatGPTURL(sourceURL),
           navigationAction.targetFrame?.isMainFrame == true {
            // Links flagged for download (e.g. <a download> for large blob/data exports) stream to disk
            // through WKDownload instead of the base64 bridge, so there is no size ceiling.
            decisionHandler(.download)
            return
        }
        if #available(macOS 11.3, *), navigationAction.shouldPerformDownload {
            setStatus("已阻止非 ChatGPT 页面自动下载", showsProgress: false)
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame == nil {
            // New window / window.open / target=_blank. The privacy menu decides whether third-party
            // destinations stay in an app popup or leave through the user's default browser.
            if Self.shouldOpenNewWindowInSystemBrowser(cleanedURL, sourceURL: sourceURL) {
                guard let safeURL = NavigationRules.sanitizedUserFacingURL(cleanedURL, sourceURL: sourceURL) else {
                    setStatus("已阻止不安全的外部链接", showsProgress: false)
                    decisionHandler(.cancel)
                    return
                }
                browserLogger.info("Opening user-clicked third-party URL in system browser: \(Self.loggableURL(safeURL), privacy: .public)")
                NSWorkspace.shared.open(safeURL)
            } else {
                openPopup(url: cleanedURL)
            }
            decisionHandler(.cancel)
            return
        }

        let staysInsideTrustedSurface = Self.shouldOpenInsideApp(cleanedURL, sourceURL: sourceURL)
        if !staysInsideTrustedSurface,
           Self.shouldOpenInSystemBrowser(cleanedURL, sourceURL: sourceURL, navigationType: navigationAction.navigationType) {
            guard let safeURL = NavigationRules.sanitizedUserFacingURL(cleanedURL, sourceURL: sourceURL) else {
                setStatus("已阻止不安全的外部链接", showsProgress: false)
                decisionHandler(.cancel)
                return
            }
            browserLogger.info("Opening user-clicked third-party URL in system browser: \(Self.loggableURL(safeURL), privacy: .public)")
            NSWorkspace.shared.open(safeURL)
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame?.isMainFrame == true,
           let sourceURL,
           let method = navigationAction.request.httpMethod?.uppercased(),
           method != "GET", method != "HEAD",
           sourceURL.host?.lowercased() != cleanedURL.host?.lowercased(),
           !staysInsideTrustedSurface {
            setStatus("已阻止跨站表单提交", showsProgress: false)
            decisionHandler(.cancel)
            return
        }

        // Apply the same tracking cleanup, privacy headers, language override and referrer trimming to
        // every main-frame request that remains in this WebView, including third-party redirects and
        // destinations the user explicitly chose to keep in-app.
        if navigationAction.targetFrame?.isMainFrame == true,
           Self.canRewriteForPrivacy(navigationAction.request),
           Self.needsPrivacyRewrite(
               request: navigationAction.request,
               cleanedURL: cleanedURL,
               sourceURL: sourceURL,
               profileID: profileID
           ) {
            webView.load(Self.privacyRequest(for: cleanedURL, sourceURL: sourceURL, profileID: profileID))
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
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
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
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
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
        guard !Self.isBenignNavigationError(error) else {
            updateNativeChromeStatus()
            return
        }

        // Surface the failure so a blank window after a failed load is diagnosable in the unified log.
        navigationFailureCount += 1
        let safeErrorDescription = DiagnosticRedactor.text(error.localizedDescription)
        lastNavigationFailureDescription = safeErrorDescription
        lastRenderProbeWasBlank = true
        stopLoadingWatchdog()
        setStatus("页面加载失败", showsProgress: false)
        showStatusOverlay(.failed(safeErrorDescription))
        browserLogger.error("Provisional navigation failed: \(safeErrorDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
        guard !Self.isBenignNavigationError(error) else {
            updateNativeChromeStatus()
            return
        }

        navigationFailureCount += 1
        let safeErrorDescription = DiagnosticRedactor.text(error.localizedDescription)
        lastNavigationFailureDescription = safeErrorDescription
        lastRenderProbeWasBlank = true
        stopLoadingWatchdog()
        setStatus("页面加载失败", showsProgress: false)
        showStatusOverlay(.failed(safeErrorDescription))
        browserLogger.error("Navigation failed: \(safeErrorDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return nil
        }
        if let url = navigationAction.request.url {
            let cleanedURL = Self.cleanTrackingParameters(from: url)
            guard NavigationRules.isAllowedWebViewNavigationURL(cleanedURL, sourceURL: webView.url) else {
                setStatus("已阻止不安全的外部弹窗协议或凭据链接", showsProgress: false)
                return nil
            }
            if Self.shouldOpenNewWindowInSystemBrowser(cleanedURL, sourceURL: webView.url) {
                guard let safeURL = NavigationRules.sanitizedUserFacingURL(cleanedURL, sourceURL: webView.url) else {
                    setStatus("已阻止不安全的外部弹窗链接", showsProgress: false)
                    return nil
                }
                browserLogger.info("Opening user-clicked third-party popup URL in system browser: \(Self.loggableURL(safeURL), privacy: .public)")
                NSWorkspace.shared.open(safeURL)
                return nil
            }
        }

        let child = BrowserWindowController(
            initialURL: nil,
            title: makePopupTitle(),
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
        if isPopup, !isDisposing {
            window.close()
        }
    }

    @MainActor
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        guard Self.isTrustedChatGPTOrigin(frame.securityOrigin) else {
            completionHandler(nil)
            return
        }
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

    @available(macOS 12.0, *)
    @MainActor
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let kind: MediaCaptureKind
        switch type {
        case .camera:
            kind = .camera
        case .microphone:
            kind = .microphone
        case .cameraAndMicrophone:
            kind = .cameraAndMicrophone
        @unknown default:
            decisionHandler(.deny)
            return
        }

        let decision = MediaCapturePermissionPolicy.decision(
            originScheme: origin.protocol,
            originHost: origin.host,
            originPort: origin.port == 0 ? nil : origin.port,
            kind: kind,
            microphoneStatus: Self.mediaAuthorizationStatus(for: .audio),
            cameraStatus: Self.mediaAuthorizationStatus(for: .video)
        )
        switch decision {
        case .prompt:
            decisionHandler(.prompt)
        case .grant:
            decisionHandler(.grant)
        case .deny:
            decisionHandler(.deny)
        }
    }

    private static func mediaAuthorizationStatus(for mediaType: AVMediaType) -> MediaDeviceAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        @unknown default:
            return .restricted
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
    @MainActor
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
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
              !isDisposing,
              ProfileStore.pendingDataMutation == nil,
              PromptDraftStore.isRestoreEnabled(),
              message.frameInfo.isMainFrame,
              Self.isTrustedChatGPTBridgeOrigin(message.frameInfo.securityOrigin),
              let payload = message.body as? [String: Any],
              let rawText = payload["text"] as? String,
              rawText.count <= 24_000
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
        let reason = Self.redactedCompletionReason(payload["reason"] as? String)
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
        let suggestedName = (payload["filename"] as? String)
            .map { String($0.prefix(512)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let dataURL = payload["dataURL"] as? String {
            do {
                guard Self.isImageDataURL(dataURL) else {
                    throw NSError(domain: "ChatGPTSwiftWeb", code: 9, userInfo: [NSLocalizedDescriptionKey: "仅支持图像数据"])
                }
                let filename = Self.imageFilename(
                    suggestedFilename: suggestedName,
                    fallback: "chatgpt-image",
                    mimeType: Self.dataURLMimeType(dataURL)
                )
                let data = try decodeDataURL(dataURL)
                let outputURL = try DownloadStore.save(data, suggestedFilename: filename)
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch {
                presentError("保存下载失败：\(error.localizedDescription)")
            }
            return
        }

        if let rawURL = payload["url"] as? String,
           let url = NavigationRules.validatedExternalURL(rawURL) {
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

        let x = CGFloat(Self.finiteDouble(payload["x"]) ?? Double(webView.bounds.midX))
        let y = CGFloat(Self.finiteDouble(payload["y"]) ?? Double(webView.bounds.midY))
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
                guard Self.isImageDataURL(dataURL) else {
                    throw NSError(domain: "ChatGPTSwiftWeb", code: 9, userInfo: [NSLocalizedDescriptionKey: "仅支持图像数据"])
                }
                let data = try decodeDataURL(dataURL)
                try copyImageDataToPasteboard(data)
            } catch {
                presentError("拷贝图像失败：\(error.localizedDescription)")
            }
            return
        }

        if let rawURL = payload["url"] as? String,
           let url = NavigationRules.validatedExternalURL(rawURL) {
            copyRemoteImage(from: url)
            return
        }

        presentError("拷贝图像失败：下载桥没有收到有效图像数据。")
    }

    private func copyImageDataToPasteboard(_ data: Data) throws {
        guard let image = NSImage(data: data) else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 8, userInfo: [NSLocalizedDescriptionKey: "图像数据无法解码"])
        }
        try writeImageToPasteboard(image)
    }

    private func writeImageToPasteboard(_ image: NSImage) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func clearInjectedZoomState() {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
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
              !isDisposing,
              ProfileStore.pendingDataMutation == nil,
              PromptDraftStore.isRestoreEnabled(),
              Self.canInjectPromptContent(into: webView.url) else {
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
              !isDisposing,
              ProfileStore.pendingDataMutation == nil,
              PromptDraftStore.isRestoreEnabled(),
              !PromptDraftStore.draft(for: profileID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        for delay in [0.9, 2.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.webView === webView,
                      !self.isDisposing,
                      ProfileStore.pendingDataMutation == nil else {
                    return
                }
                self.restorePromptDraftIfAvailable(reason: reason)
            }
        }
    }

    private func renderFingerprintReport() {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
        webView.evaluateJavaScript(Self.fingerprintTestRenderScript) { [weak self] _, error in
            guard let self, !self.isDisposing, ProfileStore.pendingDataMutation == nil else {
                return
            }
            if let error {
                let message = Self.javascriptStringLiteral(error.localizedDescription)
                let script = "document.body.innerHTML = '<main><h1>指纹检测页</h1><p>报告脚本执行失败：' + \(message) + '</p></main>';"
                self.webView.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }

    private func setWebZoom(_ zoom: CGFloat) {
        let clamped = min(max(zoom, minimumWebZoom), maximumWebZoom)
        currentZoom = clamped
        webView.pageZoom = clamped
        UserDefaults.standard.set(Double(clamped), forKey: webZoomDefaultsKey)
    }

    private func openPopup(url: URL) {
        let child = BrowserWindowController(
            initialURL: url,
            title: makePopupTitle(),
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

    private func makePopupTitle() -> String {
        preferredWindowTitle()
    }

    private func preferredWindowTitle() -> String {
        let mode = WindowTitleSettings.mode()
        guard persistent else {
            return ProfileWindowTitle.format(profileName: "无痕", isDefault: false, mode: mode)
        }
        guard let name = profileDisplayName() else {
            return "ChatGPT Swift"
        }
        return ProfileWindowTitle.format(profileName: name, isDefault: false, mode: mode)
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
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            return
        }
        let parsedCount = cookies.count
        let importableCookies = cookies.filter { Self.isChatGPTEssentialCookieName($0.name) }
        let skippedCount = parsedCount - importableCookies.count
        guard !importableCookies.isEmpty else {
            presentError("Cookie 导入失败：未发现关键 ChatGPT 登录 cookie。为避免请求头过大导致白屏，已拒绝导入低价值 cookie。")
            return
        }
        let importedHeaderBytes = Self.cookieHeaderBytes(importableCookies)
        guard importedHeaderBytes <= maximumChatGPTCookieHeaderBytes else {
            presentError("Cookie 导入失败：关键登录 cookie 总大小超过 \(maximumChatGPTCookieHeaderBytes / 1024) KB，已拒绝写入以避免页面白屏。")
            return
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let operationGroup = websiteDataMutationGroup
        operationGroup.enter()
        let completionLock = NSLock()
        var didFinishOperation = false
        let finishOperation = {
            completionLock.lock()
            let shouldLeave = !didFinishOperation
            didFinishOperation = true
            completionLock.unlock()
            if shouldLeave {
                operationGroup.leave()
            }
        }
        let group = DispatchGroup()
        let importedIdentities = Set(importableCookies.map(CookieIdentity.init))

        for cookie in importableCookies {
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, !self.isDisposing, ProfileStore.pendingDataMutation == nil else {
                finishOperation()
                return
            }

            self.pruneOversizedChatGPTCookies(in: cookieStore) { [weak self] prunedCount in
                guard let self, !self.isDisposing, ProfileStore.pendingDataMutation == nil else {
                    finishOperation()
                    return
                }

                cookieStore.getAllCookies { [weak self] storedCookies in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isDisposing, ProfileStore.pendingDataMutation == nil else {
                            finishOperation()
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
                        finishOperation()
                        self.presentAlert(lines.joined(separator: "\n"), style: missingCookies.isEmpty && missingLoginNames.isEmpty ? .informational : .warning)
                        self.webView.reload()
                    }
                }
            }
        }
    }

    private func pruneOversizedChatGPTCookies(in cookieStore: WKHTTPCookieStore, completion: @escaping (Int) -> Void) {
        let finish: (Int) -> Void = { count in
            DispatchQueue.main.async {
                completion(count)
            }
        }
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else {
            finish(0)
            return
        }

        cookieStore.getAllCookies { [weak self] storedCookies in
            guard let self, !self.isDisposing, ProfileStore.pendingDataMutation == nil else {
                finish(0)
                return
            }
            let headerBytes = Self.cookieHeaderBytes(storedCookies.filter(Self.isChatGPTRelatedCookie))
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

    private static func boundedCookiesForProfileTransfer(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        let prioritized = cookies.sorted { lhs, rhs in
            let leftEssential = CookieImportParser.isEssentialCookieName(lhs.name)
            let rightEssential = CookieImportParser.isEssentialCookieName(rhs.name)
            if leftEssential != rightEssential {
                return leftEssential && !rightEssential
            }
            return lhs.name < rhs.name
        }
        var selected: [HTTPCookie] = []
        for cookie in prioritized {
            guard cookie.value.utf8.count <= CookieImportParser.maximumCookieValueBytes,
                  Self.cookieHeaderBytes(selected + [cookie]) <= maximumChatGPTCookieHeaderBytes else {
                continue
            }
            selected.append(cookie)
        }
        return selected
    }

    private static func cookieHeaderBytes(_ cookies: [HTTPCookie]) -> Int {
        cookies.enumerated().reduce(0) { total, item in
            let (index, cookie) = item
            return total + cookie.name.utf8.count + cookie.value.utf8.count + 1 + (index == 0 ? 0 : 2)
        }
    }

    fileprivate static func isAllowedCookieDomain(_ domain: String) -> Bool {
        CookieImportParser.isAllowedDomain(domain)
    }

    fileprivate static func isChatGPTEssentialCookieName(_ name: String) -> Bool {
        CookieImportParser.isEssentialCookieName(name)
    }

    fileprivate static func isChatGPTSessionCookieName(_ name: String) -> Bool {
        CookieImportParser.isSessionCookieName(name)
    }

    private func downloadRemoteImage(from url: URL, suggestedFilename: String?) {
        loadRemoteImage(from: url) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .success(remoteImage):
                defer { try? FileManager.default.removeItem(at: remoteImage.fileURL) }
                let filename = Self.remoteImageFilename(
                    suggestedFilename: suggestedFilename,
                    sourceURL: url,
                    mimeType: remoteImage.mimeType
                )
                do {
                    let outputURL = try DownloadStore.moveTemporaryFile(
                        remoteImage.fileURL,
                        suggestedFilename: filename
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                } catch {
                    self.presentError("保存下载失败：\(error.localizedDescription)")
                }
            case let .failure(error):
                self.presentError("保存下载失败：\(error.localizedDescription)")
            }
        }
    }

    private func copyRemoteImage(from url: URL) {
        loadRemoteImage(from: url) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case let .success(remoteImage):
                let fileURL = remoteImage.fileURL
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    defer { try? FileManager.default.removeItem(at: fileURL) }
                    do {
                        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                        guard let image = NSImage(data: data) else {
                            throw NSError(
                                domain: "ChatGPTSwiftWeb",
                                code: 8,
                                userInfo: [NSLocalizedDescriptionKey: "图像数据无法解码"]
                            )
                        }
                        DispatchQueue.main.async {
                            guard let self, !self.isDisposing else {
                                return
                            }
                            do {
                                try self.writeImageToPasteboard(image)
                            } catch {
                                self.presentError("拷贝图像失败：\(error.localizedDescription)")
                            }
                        }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            self?.presentError("拷贝图像失败：\(error.localizedDescription)")
                        }
                    }
                }
            case let .failure(error):
                self.presentError("拷贝图像失败：\(error.localizedDescription)")
            }
        }
    }

    private func loadRemoteImage(
        from url: URL,
        completion: @escaping (Result<RemoteImageFile, Error>) -> Void
    ) {
        let loaderID = UUID()
        let loader = RemoteImageLoader(
            sourceURL: url,
            maximumBytes: maximumBridgeDownloadBytes
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                guard self.remoteImageLoaders.removeValue(forKey: loaderID) != nil else {
                    return
                }
                guard !self.isDisposing else {
                    return
                }
                completion(result)
            }
        }
        remoteImageLoaders[loaderID] = loader
        loader.start()
    }

    private func cancelRemoteImageLoads() {
        let loaders = Array(remoteImageLoaders.values)
        remoteImageLoaders.removeAll()
        loaders.forEach { $0.cancel() }
    }

    private static func remoteImageFilename(suggestedFilename: String?, sourceURL: URL, mimeType: String?) -> String {
        DownloadFilename.remoteImageFilename(suggestedFilename: suggestedFilename, sourceURL: sourceURL, mimeType: mimeType)
    }

    private static func imageFilename(suggestedFilename: String?, fallback: String, mimeType: String?) -> String {
        DownloadFilename.imageFilename(suggestedFilename: suggestedFilename, fallback: fallback, mimeType: mimeType)
    }

    private static func fileExtension(forMIMEType mimeType: String?) -> String? {
        DownloadFilename.fileExtension(forMIMEType: mimeType)
    }

    private func burnWebsiteData(completion: @escaping () -> Void) {
        // Stop the current document and close child windows before deleting the persistent store.
        // Otherwise timers/navigation in an active page can write cookies or local storage back
        // while WebKit is reporting a successful cleanup.
        ProfileStore.markPendingDataMutation(
            kind: "burn",
            profileID: profileID ?? defaultProfileID
        )
        isDisposing = true
        tearDownWebView()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        let children = childControllers
        childControllers.removeAll()
        let group = DispatchGroup()
        for child in children {
            group.enter()
            child.dispose {
                group.leave()
            }
        }
        group.enter()
        websiteDataMutationGroup.notify(queue: .main) {
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            WebsiteDataCleaner.removeAllData(from: self.webView.configuration.websiteDataStore) { [weak self] in
                guard let self else {
                    return
                }

                self.currentZoom = 1.0
                UserDefaults.standard.removeObject(forKey: webZoomDefaultsKey)
                completion()
            }
        }
    }

    private static func loadCookieExport(from url: URL) throws -> [HTTPCookie] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > CookieImportParser.maximumImportBytes {
            throw cookieImportError("Cookie 文件过大")
        }

        let data = try Data(contentsOf: url)
        return try parseCookieImport(data: data)
    }

    private static func parseCookieImport(data: Data) throws -> [HTTPCookie] {
        try CookieImportParser.parse(data: data)
    }

    private static func safeCookieImportMessage(_ error: Error) -> String {
        CookieImportParser.safeMessage(error)
    }

    fileprivate static func cookieImportError(_ message: String) -> NSError {
        CookieImportParser.cookieImportError(message)
    }

    private func decodeDataURL(_ dataURL: String) throws -> Data {
        guard dataURL.utf8.count <= maximumBridgeDownloadPayloadCharacters else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 4, userInfo: [NSLocalizedDescriptionKey: "下载内容超过 \(maximumBridgeDownloadBytes / 1024 / 1024)MB 限制"])
        }
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 1, userInfo: [NSLocalizedDescriptionKey: "不是有效的 data URL"])
        }

        let header = dataURL[..<commaIndex]
        let body = String(dataURL[dataURL.index(after: commaIndex)...])
        if header.contains(";base64") {
            let estimatedDecodedBytes = (body.utf8.count * 3) / 4
            guard estimatedDecodedBytes <= maximumBridgeDownloadBytes else {
                throw NSError(domain: "ChatGPTSwiftWeb", code: 5, userInfo: [NSLocalizedDescriptionKey: "下载内容超过 \(maximumBridgeDownloadBytes / 1024 / 1024)MB 限制"])
            }
            guard let data = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
                throw NSError(domain: "ChatGPTSwiftWeb", code: 2, userInfo: [NSLocalizedDescriptionKey: "Base64 数据无法解码"])
            }
            guard data.count <= maximumBridgeDownloadBytes else {
                throw NSError(domain: "ChatGPTSwiftWeb", code: 6, userInfo: [NSLocalizedDescriptionKey: "下载内容超过 \(maximumBridgeDownloadBytes / 1024 / 1024)MB 限制"])
            }
            return data
        }

        guard let decoded = body.removingPercentEncoding,
              let data = decoded.data(using: .utf8)
        else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 3, userInfo: [NSLocalizedDescriptionKey: "文本数据无法解码"])
        }
        guard data.count <= maximumBridgeDownloadBytes else {
            throw NSError(domain: "ChatGPTSwiftWeb", code: 7, userInfo: [NSLocalizedDescriptionKey: "下载内容超过 \(maximumBridgeDownloadBytes / 1024 / 1024)MB 限制"])
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
        DownloadStore.destinationURL(suggestedFilename: suggestedFilename)
    }

    private func sanitizeFilename(_ filename: String) -> String {
        DownloadFilename.sanitize(filename)
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

    private static func finiteDouble(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? Double {
            number = value
        } else if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite else {
            return nil
        }
        return number
    }

    private static func redactedCompletionReason(_ rawReason: String?) -> String {
        let bounded = String((rawReason ?? "unknown").prefix(128))
        let normalized = bounded.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        return DiagnosticRedactor.text(normalized)
    }

    private static func isImageDataURL(_ dataURL: String) -> Bool {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            return false
        }
        let header = dataURL[..<commaIndex].lowercased()
        return header.hasPrefix("data:image/") && !header.hasPrefix("data:image/svg+xml")
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

    static let renderedContentProbeScript = """
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
          cloudflareChallenge: false,
          readyState: document.readyState,
          href: location.href,
          title: document.title,
          textLength: 0,
          visibleElements: 0,
          bodyChildren: document.body ? document.body.children.length : 0
        };
      }

      const body = document.body;
      const cloudflareChallenge = location.pathname.startsWith('/cdn-cgi/challenge-platform/') || !!document.querySelector([
        'iframe[src*="challenges.cloudflare.com"]',
        '.cf-turnstile',
        '#cf-challenge-running',
        '#challenge-stage',
        '[data-cf-challenge]'
      ].join(','));
      // Sample text length with an early exit instead of materializing body.textContent: long
      // conversations make the full concatenation a multi-megabyte main-thread pause, while the
      // blank verdict only needs to know whether at least 8 characters exist.
      let textLength = 0;
      if (body) {
        const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
        while (textLength < 64) {
          const node = walker.nextNode();
          if (!node) break;
          textLength += String(node.nodeValue || '').trim().length;
        }
      }

      let visibleElements = 0;
      if (body && textLength < 8 && !cloudflareChallenge) {
        const visualCandidates = body.querySelectorAll('main,[role="main"],form,iframe,canvas,video,img,svg');
        for (const element of Array.from(visualCandidates).slice(0, 24)) {
          try {
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) continue;
            const rect = element.getBoundingClientRect();
            if (rect.width > 1 && rect.height > 1) {
              visibleElements = 1;
              break;
            }
          } catch (_) {}
        }
      }

      const bodyChildren = body ? body.children.length : 0;
      return {
        blank: !cloudflareChallenge && (!body || (textLength < 8 && visibleElements === 0)),
        cloudflareChallenge,
        readyState: document.readyState,
        href: location.href,
        title: document.title,
        textLength,
        visibleElements,
        bodyChildren
      };
    })()
    """

    static let promptDraftCaptureScript = """
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const isChatGPTPage = location.protocol === 'https:' && (
        host === 'chatgpt.com' ||
        host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' ||
        host.endsWith('.chat.openai.com')
      );
      const isCloudflareChallenge = location.pathname.startsWith('/cdn-cgi/challenge-platform/') || !!document.querySelector([
        'iframe[src*="challenges.cloudflare.com"]',
        '.cf-turnstile',
        '#cf-challenge-running',
        '#challenge-stage',
        '[data-cf-challenge]'
      ].join(','));
      if (!isChatGPTPage || isCloudflareChallenge || window.__chatgptSwiftPromptDraftBridgeInstalled) return;
      window.__chatgptSwiftPromptDraftBridgeInstalled = true;

      const maxLength = 12000;
      const readText = (element) => {
        if (!element) return '';
        if (element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement) {
          return String(element.value || '').slice(0, maxLength);
        }
        return String(element.innerText || element.textContent || '').slice(0, maxLength);
      };
      const composerFromEvent = (event) => {
        const target = event.target;
        if (!(target instanceof Element)) return null;
        return target.closest([
          'textarea[data-testid="prompt-textarea"]',
          '[contenteditable="true"][data-testid="prompt-textarea"]',
          '#prompt-textarea'
        ].join(','));
      };

      let publishTimer = 0;
      let pendingComposer = null;
      const publish = (composer) => {
        pendingComposer = composer;
        window.clearTimeout(publishTimer);
        publishTimer = window.setTimeout(() => {
          try {
            window.webkit.messageHandlers.promptDraft.postMessage({ text: readText(pendingComposer) });
          } catch (_) {}
        }, 250);
      };

      ['input', 'change'].forEach((eventName) => {
        document.addEventListener(eventName, (event) => {
          const composer = composerFromEvent(event);
          if (composer) publish(composer);
        }, true);
      });
    })()
    """

    static let completionStateObserverScript = """
    (() => {
      const host = String(location.hostname || '').toLowerCase();
      const isChatGPTPage = location.protocol === 'https:' && (
        host === 'chatgpt.com' ||
        host.endsWith('.chatgpt.com') ||
        host === 'chat.openai.com' ||
        host.endsWith('.chat.openai.com')
      );
      const isCloudflareChallenge = location.pathname.startsWith('/cdn-cgi/challenge-platform/') || !!document.querySelector([
        'iframe[src*="challenges.cloudflare.com"]',
        '.cf-turnstile',
        '#cf-challenge-running',
        '#challenge-stage',
        '[data-cf-challenge]'
      ].join(','));
      if (!isChatGPTPage || isCloudflareChallenge || window.__chatgptSwiftCompletionObserverInstalled) return;
      window.__chatgptSwiftCompletionObserverInstalled = true;

      // The scan forces synchronous layout (rect/computed style/innerText), so it must stay rare
      // and cheap: rect short-circuits before computed style, candidates are capped, and scans run
      // through requestIdleCallback so streaming-mutation storms never reflow every frame.
      const visible = (element) => {
        if (!element) return false;
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return false;
        const style = window.getComputedStyle(element);
        return style.visibility !== 'hidden' && style.display !== 'none';
      };
      const textOf = (element) => String(
        element?.getAttribute?.('aria-label') ||
        element?.getAttribute?.('data-testid') ||
        element?.innerText ||
        element?.textContent ||
        ''
      ).toLowerCase();
      const busyReason = () => {
        const candidates = Array.from(document.querySelectorAll([
          '[aria-busy="true"]',
          '[data-testid*="stop" i]',
          'button[aria-label*="stop" i]',
          'button[aria-label*="停止"]',
          '[role="button"][aria-label*="stop" i]',
          '[role="button"][aria-label*="停止"]'
        ].join(',')))
          .slice(0, 12)
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
      let scanScheduled = false;
      const scheduleIdleScan = window.requestIdleCallback
        ? ((scan) => window.requestIdleCallback(scan, { timeout: 500 }))
        : ((scan) => window.setTimeout(scan, 250));
      const publish = () => {
        if (scanScheduled) return;
        scanScheduled = true;
        window.setTimeout(() => {
          scheduleIdleScan(() => {
            scanScheduled = false;
            const reason = busyReason();
            const busy = reason.length > 0;
            if (busy === lastBusy) return;
            lastBusy = busy;
            try {
              window.webkit.messageHandlers.completionState.postMessage({ busy, reason });
            } catch (_) {}
          });
        }, 600);
      };

      publish();
      new MutationObserver(publish).observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['aria-label', 'aria-busy', 'data-testid', 'disabled']
      });
      // Poll only while a generation is in flight; an idle page costs nothing until the
      // MutationObserver reports activity again.
      window.setInterval(() => {
        if (lastBusy) publish();
      }, 3000);
    })()
    """

    static func canInjectPromptContent(into url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "https",
              let host = url?.host?.lowercased() else {
            return false
        }
        return NavigationRules.isChatGPTHost(host)
    }

    static func restorePromptDraftScript(text: String) -> String {
        let textLiteral = javascriptStringLiteral(text)
        return """
        (() => {
          const host = String(location.hostname || '').toLowerCase();
          const isChatGPTPage = location.protocol === 'https:' && (
            host === 'chatgpt.com' ||
            host.endsWith('.chatgpt.com') ||
            host === 'chat.openai.com' ||
            host.endsWith('.chat.openai.com')
          );
          if (!isChatGPTPage) {
            return { restored: false, reason: 'untrusted origin' };
          }

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
        if fingerprint != nil || enhancedPrivacyEnabled || webRTCProtectionEnabled {
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

        guard let profileID else {
            return .default()
        }
        if profileID == defaultProfileID {
            return .default()
        }
        guard let uuid = UUID(uuidString: profileID) else {
            // Never silently put malformed custom metadata into the shared default store.
            return .nonPersistent()
        }

        if #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: uuid)
        }
        return .nonPersistent()
    }

    private static func isChatGPTHost(_ host: String) -> Bool {
        NavigationRules.isChatGPTHost(host)
    }

    private static func isOpenAIAuthHost(_ host: String) -> Bool {
        NavigationRules.isOpenAIAuthHost(host)
    }

    private static func isOpenAISentinelHost(_ host: String) -> Bool {
        NavigationRules.isOpenAISentinelHost(host)
    }

    private static func isCloudflareChallengeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        return host == "challenges.cloudflare.com"
    }

    private static func isOpenAIFamilyHost(_ host: String) -> Bool {
        NavigationRules.isOpenAIFamilyHost(host)
    }

    /// OpenAI's own surfaces beyond the bare ChatGPT host: the marketing/help/platform sites, the
    /// static and user-content CDNs, and Sora. They belong to the same product family, so links into
    /// them open in-app instead of bouncing to the system browser.
    private static func isOpenAIEcosystemHost(_ host: String) -> Bool {
        NavigationRules.isOpenAIEcosystemHost(host)
    }

    private static func isTrustedAuthSourceHost(_ host: String) -> Bool {
        isChatGPTHost(host)
            || isOpenAIAuthHost(host)
            || isOpenAIFamilyHost(host)
            || isOAuthProviderHost(host)
    }

    private static func isOAuthProviderHost(_ host: String) -> Bool {
        NavigationRules.isOAuthProviderHost(host)
    }

    private static func isAuthLikeURL(_ url: URL, expanded: Bool = false) -> Bool {
        NavigationRules.isAuthLikeURL(url, expanded: expanded)
    }

    private static func isOAuthContinuationHost(_ url: URL) -> Bool {
        NavigationRules.isOAuthContinuationHost(url)
    }

    private static func isAuthContinuationFromTrustedSource(_ url: URL, sourceURL: URL?) -> Bool {
        NavigationRules.isAuthContinuationFromTrustedSource(url, sourceURL: sourceURL)
    }

    private static func isTrustedChatGPTBridgeOrigin(_ origin: WKSecurityOrigin) -> Bool {
        guard isTrustedChatGPTOrigin(origin) else {
            return false
        }
        return true
    }

    private static func isTrustedChatGPTOrigin(_ origin: WKSecurityOrigin) -> Bool {
        guard origin.protocol == "https",
              (origin.port == 0 || origin.port == 443) else {
            return false
        }
        return NavigationRules.isChatGPTHost(origin.host.lowercased())
    }

    private static func isTrustedChatGPTURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              (url.port == nil || url.port == 443),
              let host = url.host else {
            return false
        }
        return NavigationRules.isChatGPTHost(host.lowercased())
    }

    private static func shouldOpenInsideApp(_ url: URL, sourceURL: URL? = nil) -> Bool {
        NavigationRules.shouldOpenInsideApp(url, sourceURL: sourceURL)
    }

    /// Only a deliberate user click on a genuine third-party https link should leave the app for the
    /// system browser. Automatic redirects, script-driven navigations, and ChatGPT's own popups stay
    /// in-app, so the user is never bounced to the default browser unexpectedly mid-session.
    private static func shouldOpenInSystemBrowser(_ url: URL, sourceURL: URL? = nil, navigationType: WKNavigationType) -> Bool {
        NavigationRules.shouldOpenInSystemBrowser(
            url,
            sourceURL: sourceURL,
            navigationType: navigationType == .linkActivated ? .linkActivated : .other,
            keepThirdPartyLinksInApp: PrivacySettings.keepThirdPartyLinksInApp()
        )
    }

    /// WebKit often reports JS-mediated target=_blank/window.open as `.other`, even when it came from
    /// a user click. For new-window requests the menu setting is the source of truth.
    private static func shouldOpenNewWindowInSystemBrowser(_ url: URL, sourceURL: URL? = nil) -> Bool {
        NavigationRules.shouldOpenNewWindowInSystemBrowser(
            url,
            sourceURL: sourceURL,
            keepThirdPartyLinksInApp: PrivacySettings.keepThirdPartyLinksInApp()
        )
    }

    private static func loggableURL(_ url: URL) -> String {
        DiagnosticRedactor.url(url)
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
        NavigationRules.cleanTrackingParameters(from: url)
    }

    private static func isTrackingQueryParameter(_ name: String) -> Bool {
        NavigationRules.isTrackingQueryParameter(name)
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

    static func refreshWindowTitles() {
        controllers.forEach { controller in
            controller.window.title = controller.preferredWindowTitle()
        }
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

    static let downloadBridgeScript = """
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
          return location.protocol === 'https:' && (location.port === '' || location.port === '443') && (host === 'chatgpt.com' || host.endsWith('.chatgpt.com') || host === 'chat.openai.com' || host.endsWith('.chat.openai.com'));
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

              function containsTooltip(node) {
                if (!(node instanceof Element)) return false;
                return node.matches(tooltipSelector) || !!node.querySelector(tooltipSelector);
              }

              const root = document.documentElement || document.body;
              if (!root) {
                document.addEventListener('DOMContentLoaded', installStopTooltipGuard, { once: true });
                return;
              }

              scheduleGuard();
              new MutationObserver((mutations) => {
                for (const mutation of mutations) {
                  if (Array.from(mutation.addedNodes).some(containsTooltip)) {
                    scheduleGuard();
                    return;
                  }
                }
              }).observe(root, {
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
        if (url.origin === location.origin) {
          try {
            const response = await fetch(url.href, { credentials: 'same-origin', cache: 'no-store' });
            if (response.ok) {
              return { filename, dataURL: await readBlob(await response.blob()) };
            }
          } catch (_) {}
        } else {
          // Never let a page-origin cookie cross to an image CDN or another OpenAI/third-party host.
          // The native fallback uses an isolated, cookie-free URLSession for these URLs.
          return { filename, url: url.href };
        }
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
