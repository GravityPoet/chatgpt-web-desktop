import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class BrowserNavigationNoticeIntegrationTests: XCTestCase {
    func testBackgroundSubframeIsBlockedWithoutReplacingPageStatus() throws {
        let (controller, delegate) = try makeHarness()
        defer { controller.window.close() }
        let normalStatus = controller.lastPresentedStatusText

        let action = try navigate(
            "document.querySelector('iframe').src = 'notice-test://private-payload/path?token=secret-fragment';",
            controller: controller,
            delegate: delegate
        )

        XCTAssertEqual(action.navigationType, .other)
        XCTAssertEqual(action.targetFrame?.isMainFrame, false)
        XCTAssertEqual(delegate.lastPolicy, .cancel)
        XCTAssertNil(controller.blockedNavigationStatus)
        controller.updateNativeChromeStatus()
        XCTAssertEqual(controller.lastPresentedStatusText, normalStatus)
        let report = controller.diagnosticsReport()
        XCTAssertTrue(report.contains("reason=unsupportedScheme, frame=subframe"))
        XCTAssertTrue(report.contains("target=notice-test:<redacted>"))
        XCTAssertFalse(report.contains("private-payload"))
        XCTAssertFalse(report.contains("secret-fragment"))
    }

    func testMainFrameNoticeSurvivesStatusUpdatesThenExpires() throws {
        let (controller, delegate) = try makeHarness()
        defer { controller.window.close() }
        let normalStatus = controller.lastPresentedStatusText

        let action = try navigate(
            "location.href = 'notice-test://example/action';",
            controller: controller,
            delegate: delegate
        )

        XCTAssertEqual(action.targetFrame?.isMainFrame, true)
        XCTAssertEqual(delegate.lastPolicy, .cancel)
        let notice = "已阻止不支持的 notice-test: 链接"
        XCTAssertEqual(controller.blockedNavigationStatus, notice)
        controller.updateNativeChromeStatus()
        XCTAssertEqual(controller.statusLabel?.stringValue, notice)

        let expired = expectation(description: "notice expires after six seconds")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.2) { expired.fulfill() }
        wait(for: [expired], timeout: 8)
        XCTAssertNil(controller.blockedNavigationStatus)
        XCTAssertEqual(controller.statusLabel?.stringValue, normalStatus)
    }

    func testUserClickFromSubframeToMainFrameStillGetsNotice() throws {
        let (controller, delegate) = try makeHarness()
        defer { controller.window.close() }

        let action = try navigate("""
        const frameDocument = document.querySelector('iframe').contentDocument;
        const link = frameDocument.createElement('a');
        link.href = 'notice-test://example/action';
        link.target = '_top';
        frameDocument.body.appendChild(link);
        link.click();
        """, controller: controller, delegate: delegate)

        XCTAssertFalse(action.sourceFrame.isMainFrame)
        XCTAssertEqual(action.targetFrame?.isMainFrame, true)
        XCTAssertEqual(action.navigationType, .linkActivated)
        XCTAssertEqual(delegate.lastPolicy, .cancel)
        XCTAssertEqual(controller.blockedNavigationStatus, "已阻止不支持的 notice-test: 链接")
    }

    func testMainFramePopupUsesSameSpecificNotice() throws {
        let (controller, delegate) = try makeHarness()
        defer { controller.window.close() }

        let created = expectation(description: "popup navigation policy applied")
        delegate.created = created
        controller.webView.evaluateJavaScript("window.open('notice-test://example/action');")
        wait(for: [created], timeout: 5)
        let action = try XCTUnwrap(delegate.lastAction)

        XCTAssertNil(action.targetFrame)
        XCTAssertTrue(action.sourceFrame.isMainFrame)
        XCTAssertNotNil(controller.blockedNavigationStatus)
        XCTAssertTrue(controller.diagnosticsReport().contains("frame=new-window"))
        XCTAssertEqual(controller.statusLabel?.stringValue, "已阻止不支持的 notice-test: 链接")
    }

    func testBackgroundSubframePopupDoesNotReplaceMainStatus() throws {
        let (controller, delegate) = try makeHarness()
        defer { controller.window.close() }
        let normalStatus = controller.lastPresentedStatusText
        let created = expectation(description: "background popup rejected")
        delegate.created = created
        controller.webView.evaluateJavaScript("""
        document.querySelector('iframe').contentWindow.eval("window.open('notice-test://private-target/');");
        """)
        wait(for: [created], timeout: 5)
        let action = try XCTUnwrap(delegate.lastAction)
        XCTAssertNil(action.targetFrame)
        XCTAssertFalse(action.sourceFrame.isMainFrame)
        XCTAssertNil(controller.blockedNavigationStatus)
        XCTAssertEqual(controller.lastPresentedStatusText, normalStatus)
        XCTAssertTrue(controller.diagnosticsReport().contains("frame=subframe-new-window"))
        XCTAssertFalse(controller.diagnosticsReport().contains("private-target"))
    }

    func testNewerStatusAndNewNavigationClearOldNotice() throws {
        let (controller, delegate) = try makeHarness()
        defer { controller.window.close() }
        _ = try navigate("location.href = 'notice-test://example/one';", controller: controller, delegate: delegate)
        controller.setStatus("页面加载失败", showsProgress: false)
        XCTAssertNil(controller.blockedNavigationStatus)
        XCTAssertEqual(controller.statusLabel?.stringValue, "页面加载失败")

        _ = try navigate("location.href = 'notice-test://example/two';", controller: controller, delegate: delegate)
        XCTAssertNotNil(controller.blockedNavigationStatus)
        let loaded = expectation(description: "next document loads")
        delegate.finished = loaded
        controller.webView.loadHTMLString(Self.pageHTML, baseURL: Self.baseURL)
        wait(for: [loaded], timeout: 5)
        XCTAssertNil(controller.blockedNavigationStatus)
        XCTAssertEqual(controller.lastPresentedStatusText, "notice.test · 100%")
    }

    func testCredentialAndHTTPFailuresAreDistinctAndRedacted() throws {
        let (controller, delegate) = try makeHarness()
        defer { controller.window.close() }
        let credentials = expectation(description: "credential URL rejected")
        delegate.decided = credentials
        let credentialURL = [
            "https://",
            ["test-user", "test-password"].joined(separator: ":"),
            "@notice.test/auth/private?token=test-token#test-secret"
        ].joined()
        controller.webView.load(URLRequest(url: try XCTUnwrap(URL(string: credentialURL))))
        wait(for: [credentials], timeout: 5)
        XCTAssertEqual(delegate.lastPolicy, .cancel)
        XCTAssertEqual(controller.blockedNavigationStatus, "已阻止含用户名或密码的链接")
        let report = controller.diagnosticsReport()
        XCTAssertTrue(report.contains("reason=embeddedCredentials"))
        for secret in ["test-user", "test-password", "test-token", "test-secret"] {
            XCTAssertFalse(report.contains(secret))
        }

        _ = try navigate("location.href = 'http://notice.test/';", controller: controller, delegate: delegate)
        XCTAssertEqual(delegate.lastPolicy, .cancel)
        XCTAssertEqual(controller.blockedNavigationStatus, "已阻止未加密的 HTTP 链接")
    }

    private static let baseURL = URL(string: "https://notice.test/")!
    private static let pageHTML = """
    <!doctype html><html><body>
      <main style="width:600px;height:400px">Local navigation test</main>
      <iframe src="about:blank"></iframe>
    </body></html>
    """

    private func makeHarness() throws -> (BrowserWindowController, NoticeNavigationDelegate) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = BrowserWindowController(
            initialURL: nil,
            title: "Navigation notice test",
            isPopup: false,
            persistent: false,
            configuration: configuration
        )
        controller.statusLabel = NSTextField(labelWithString: "")
        let loaded = expectation(description: "local HTML loaded")
        let delegate = NoticeNavigationDelegate(controller: controller, finished: loaded)
        controller.webView.navigationDelegate = delegate
        controller.webView.uiDelegate = delegate
        controller.webView.loadHTMLString(Self.pageHTML, baseURL: Self.baseURL)
        wait(for: [loaded], timeout: 5)
        controller.updateNativeChromeStatus()
        return (controller, delegate)
    }

    @discardableResult
    private func navigate(
        _ script: String,
        controller: BrowserWindowController,
        delegate: NoticeNavigationDelegate
    ) throws -> WKNavigationAction {
        let decided = expectation(description: "navigation policy applied")
        delegate.lastAction = nil
        delegate.lastPolicy = nil
        delegate.decided = decided
        controller.webView.evaluateJavaScript("(() => { \(script) })()")
        wait(for: [decided], timeout: 5)
        return try XCTUnwrap(delegate.lastAction)
    }
}

@MainActor
private final class NoticeNavigationDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    let controller: BrowserWindowController
    var finished: XCTestExpectation?
    var decided: XCTestExpectation?
    var created: XCTestExpectation?
    var lastAction: WKNavigationAction?
    var lastPolicy: WKNavigationActionPolicy?

    init(controller: BrowserWindowController, finished: XCTestExpectation) {
        self.controller = controller
        self.finished = finished
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        controller.webView(webView, decidePolicyFor: navigationAction) { policy in
            self.lastAction = navigationAction
            self.lastPolicy = policy
            decisionHandler(policy)
            self.decided?.fulfill()
            self.decided = nil
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        controller.webView(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        controller.updateNativeChromeStatus()
        finished?.fulfill()
        finished = nil
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        lastAction = navigationAction
        let child = controller.webView(
            webView,
            createWebViewWith: configuration,
            for: navigationAction,
            windowFeatures: windowFeatures
        )
        created?.fulfill()
        created = nil
        return child
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        controller.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
}
