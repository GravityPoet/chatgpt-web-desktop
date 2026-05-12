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
private var singleInstanceLockFileDescriptor: CInt = -1

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainController: BrowserWindowController?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        installKeyboardZoomShortcuts()

        let controller = BrowserWindowController(initialURL: chatGPTURL, title: "ChatGPT Swift", isPopup: false)
        mainController = controller
        controller.show()
        NSApp.activate(ignoringOtherApps: true)
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
        appMenu.addItem(withTitle: "About ChatGPT Swift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit ChatGPT Swift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let importCookiesItem = fileMenu.addItem(withTitle: "Import ChatGPT Cookies...", action: #selector(importChatGPTCookies(_:)), keyEquivalent: "")
        importCookiesItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(BrowserWindowController.reload(_:)), keyEquivalent: "r")
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(BrowserWindowController.zoomIn(_:)), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(BrowserWindowController.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(BrowserWindowController.resetZoom(_:)), keyEquivalent: "0")
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
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

    @objc private func importChatGPTCookies(_ sender: Any?) {
        mainController?.importChatGPTCookiesFromPanel()
    }
}

final class BrowserWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    private static var controllers: [BrowserWindowController] = []

    private(set) var window: NSWindow!
    private(set) var webView: WKWebView!
    private var childControllers: [BrowserWindowController] = []
    private let isPopup: Bool
    private var closeHandler: (() -> Void)?
    private var currentZoom: CGFloat = BrowserWindowController.savedWebZoom()

    init(initialURL: URL?, title: String, isPopup: Bool, configuration: WKWebViewConfiguration? = nil, closeHandler: (() -> Void)? = nil) {
        self.isPopup = isPopup
        self.closeHandler = closeHandler
        super.init()
        Self.controllers.append(self)

        let webConfiguration = configuration ?? Self.makeConfiguration(messageHandler: self)

        webView = WKWebView(frame: .zero, configuration: webConfiguration)
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
            webView.load(URLRequest(url: initialURL))
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func reload(_ sender: Any?) {
        webView.reload()
    }

    func importChatGPTCookiesFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import ChatGPT Cookies"
        panel.message = "选择从 Chrome 导出的 ChatGPT cookie JSON 文件。"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }

            self?.importChatGPTCookies(from: url)
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
        if isPopup {
            return true
        }

        persistMainWindowFrame()
        window.orderOut(nil)
        return false
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

        if navigationAction.targetFrame == nil {
            if Self.shouldOpenInsideApp(url) {
                openPopup(url: url)
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }

        if Self.shouldOpenInsideApp(url) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.pageZoom = currentZoom
        clearInjectedZoomState()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = BrowserWindowController(initialURL: nil, title: navigationAction.request.url?.host ?? "ChatGPT", isPopup: true, configuration: configuration) { [weak self] in
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
        let child = BrowserWindowController(initialURL: url, title: url.host ?? "ChatGPT", isPopup: true) { [weak self] in
            self?.childControllers.removeAll { $0.window.isVisible == false }
        }
        childControllers.append(child)
        child.show()
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

    private func importChatGPTCookies(from url: URL) {
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
                self?.presentInfo("已导入 \(cookies.count) 个 ChatGPT cookie，正在刷新页面。")
                self?.webView.reload()
            }
        } catch {
            presentError("Cookie 导入失败：\(Self.safeCookieImportMessage(error))")
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

    private static func makeConfiguration(messageHandler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let userContentController = WKUserContentController()
        userContentController.add(messageHandler, name: "downloadBlob")
        userContentController.addUserScript(WKUserScript(source: downloadBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.allowsAirPlayForMediaPlayback = true
        return configuration
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

private struct ExportedBrowserCookie: Decodable {
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

    func makeCookie() throws -> HTTPCookie {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cookiePath = path.isEmpty ? "/" : path

        guard !trimmedName.isEmpty else {
            throw BrowserWindowController.cookieImportError("cookie 名称为空")
        }
        guard Self.isAllowedDomain(trimmedDomain) else {
            throw BrowserWindowController.cookieImportError("包含非 ChatGPT/OpenAI 域名")
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

    private static func isAllowedDomain(_ domain: String) -> Bool {
        let normalized = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return normalized == "chatgpt.com"
            || normalized.hasSuffix(".chatgpt.com")
            || normalized == "openai.com"
            || normalized.hasSuffix(".openai.com")
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
