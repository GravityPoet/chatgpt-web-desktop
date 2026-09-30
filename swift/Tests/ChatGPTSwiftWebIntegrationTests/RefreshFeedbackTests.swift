import AppKit
import Network
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class RefreshFeedbackTests: XCTestCase {
    private func makeController(handler: RefreshFixtureHandler? = nil) -> BrowserWindowController {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if let handler { configuration.setURLSchemeHandler(handler, forURLScheme: "refresh-fixture") }
        return BrowserWindowController(initialURL: nil, title: "Refresh fixture", isPopup: true,
                                       persistent: false, configuration: configuration)
    }

    private func waitForState(_ state: RefreshButtonState, in controller: BrowserWindowController,
                              timeout: TimeInterval = 5) {
        if controller.refreshButtonState == state { return }
        let reached = expectation(description: "refresh state \(state)")
        let render = controller.refreshFeedback.onChange
        var fulfilled = false
        controller.refreshFeedback.onChange = {
            render?()
            if controller.refreshButtonState == state, !fulfilled {
                fulfilled = true
                reached.fulfill()
            }
        }
        defer { controller.refreshFeedback.onChange = render }
        wait(for: [reached], timeout: timeout)
        XCTAssertEqual(controller.refreshButtonState, state)
    }

    private func settle(_ seconds: TimeInterval) {
        let elapsed = expectation(description: "feedback delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 2)
    }

    func testRealReloadImmediatelySpinsThenCompletesWithoutMovingOrDuplicating() throws {
        let handler = RefreshFixtureHandler()
        let controller = makeController(handler: handler)
        defer { controller.dispose() }
        let delegate = RefreshFixtureDelegate(controller: controller)
        controller.webView.navigationDelegate = delegate
        let loaded = expectation(description: "fixture loaded")
        delegate.finished = { loaded.fulfill() }
        controller.webView.load(URLRequest(url: URL(string: "refresh-fixture://page")!))
        wait(for: [loaded], timeout: 5)
        delegate.finished = nil
        controller.window.orderFront(nil)
        let toolbar = try XCTUnwrap(controller.window.toolbar)
        let item = try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: .chatGPTNavigation,
                                                   willBeInsertedIntoToolbar: true))
        let view = try XCTUnwrap(item.view)
        view.layoutSubtreeIfNeeded()
        let before = try XCTUnwrap(controller.navigationReloadButton).frame
        controller.reload(nil)
        let generation = controller.refreshFeedback.generation
        XCTAssertEqual(controller.refreshButtonState, .loading, "Feedback starts synchronously with the click")
        XCTAssertFalse(try XCTUnwrap(controller.navigationReloadSpinner).isHidden)
        XCTAssertFalse(try XCTUnwrap(controller.navigationReloadButton).isEnabled)
        XCTAssertTrue(controller.navigationReloadButton?.accessibilityLabel()?.contains("正在刷新") == true)
        controller.reload(nil)
        XCTAssertEqual(controller.refreshFeedback.generation, generation, "A duplicate click must not restart the load")
        controller.updateNativeChromeStatus()
        XCTAssertTrue(controller.navigationReloadButton?.accessibilityLabel()?.contains("正在刷新") == true)
        waitForState(.completed, in: controller)
        XCTAssertEqual(handler.requestCount, 2, "One initial load and exactly one refresh")
        XCTAssertEqual(controller.navigationReloadButton?.accessibilityLabel(), "刷新完成")
        XCTAssertTrue(controller.navigationReloadSpinner?.isHidden == true)
        XCTAssertTrue(controller.navigationReloadButton?.isEnabled == true)
        XCTAssertEqual(controller.navigationReloadButton?.contentTintColor, .systemGreen)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.navigationReloadButton?.frame, before)
        waitForState(.idle, in: controller)
        XCTAssertEqual(controller.navigationReloadButton?.accessibilityLabel(), "重新加载")
        XCTAssertNil(controller.navigationReloadButton?.contentTintColor)
    }

    func testToolbarRecreationPreservesLoadingAndFailedRetry() throws {
        let controller = makeController()
        defer { controller.dispose() }
        XCTAssertTrue(controller.refreshFeedback.beginRefresh())
        let toolbar = try XCTUnwrap(controller.window.toolbar)
        toolbar.autosavesConfiguration = false
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        toolbar.insertItem(withItemIdentifier: .chatGPTNavigation, at: 0)
        controller.window.orderFront(nil)
        settle(0.1)
        controller.window.contentView?.superview?.layoutSubtreeIfNeeded()
        let item = try XCTUnwrap(toolbar.items.first)
        XCTAssertEqual(controller.refreshButtonState, .loading)
        XCTAssertFalse(try XCTUnwrap(controller.navigationReloadSpinner).isHidden)
        XCTAssertEqual(controller.navigationReloadButton?.bounds.size, NSSize(width: 28, height: 28))
        XCTAssertFalse(try XCTUnwrap(item.menuFormRepresentation?.submenu?.items.last).isEnabled)
        controller.refreshFeedback.trackRequestedNavigation(nil)
        XCTAssertEqual(controller.refreshButtonState, .failed)
        XCTAssertTrue(controller.navigationReloadButton?.isEnabled == true)
        XCTAssertEqual(controller.navigationReloadButton?.accessibilityLabel(), "刷新未完成，点击重试")
        XCTAssertEqual(controller.navigationReloadButton?.contentTintColor, .systemOrange)
        XCTAssertTrue(controller.refreshFeedback.beginRefresh(), "Failure must permit retry")
    }

    func testHTTPFailuresNeverShowSuccessAndANewLoadCanRetry() throws {
        let server = try RefreshHTTPFixtureServer()
        defer { server.stop() }
        let ready = expectation(description: "loopback fixture ready")
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let controller = makeController()
        defer { controller.dispose() }
        let delegate = RefreshFixtureDelegate(controller: controller)
        controller.webView.navigationDelegate = delegate
        for code in [429, 500, 404, 200] {
            server.responseStatus = code
            let finished = expectation(description: "HTTP \(code)")
            delegate.finished = { finished.fulfill() }
            XCTAssertTrue(controller.refreshFeedback.beginRefresh())
            let navigation = controller.webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port.rawValue)/\(code)")!))
            controller.refreshFeedback.trackRequestedNavigation(navigation)
            wait(for: [finished], timeout: 5)
            XCTAssertEqual(delegate.lastHTTPStatus, code, "The real WebKit response delegate must see the status")
            if code == 200 {
                waitForState(.completed, in: controller)
                XCTAssertFalse(controller.hasFailedNavigation)
            } else {
                XCTAssertEqual(controller.refreshButtonState, .failed)
                XCTAssertTrue(controller.hasFailedNavigation)
                XCTAssertTrue(controller.navigationReloadButton?.isEnabled == true)
                XCTAssertTrue(controller.lastFailureStatus?.contains("HTTP \(code)") == true)
            }
        }
    }

    func testCloudflareChallengeResponseIsDistinctFromTerminalHTTPFailure() throws {
        let challenge = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/")!,
            statusCode: 403,
            httpVersion: "HTTP/2",
            headerFields: ["cf-mitigated": "challenge"]
        ))
        let ordinaryForbidden = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/")!,
            statusCode: 403,
            httpVersion: "HTTP/2",
            headerFields: [:]
        ))

        XCTAssertTrue(BrowserWindowController.isCloudflareChallengeResponse(challenge))
        XCTAssertFalse(BrowserWindowController.isCloudflareChallengeResponse(ordinaryForbidden))
        XCTAssertEqual(BrowserWindowController.navigationHTTPFailureMessage(for: ordinaryForbidden.statusCode), "页面请求未完成（HTTP 403），可以重试")
    }

    func testBlankAndChallengeContentCannotProduceCompletion() throws {
        for html in ["<html><body></body></html>",
                     "<html><body><div id='challenge-stage'>Verify you are human</div></body></html>"] {
            let controller = makeController()
            defer { controller.dispose() }
            // Load actual HTTPS DOM without the controller's automatic blank recovery;
            // then exercise its refresh verification against that rendered content.
            let delegate = RefreshFixtureDelegate(controller: controller)
            delegate.forwardsFinish = false
            controller.webView.navigationDelegate = delegate
            let loaded = expectation(description: "content fixture loaded")
            delegate.finished = { loaded.fulfill() }
            XCTAssertTrue(controller.refreshFeedback.beginRefresh())
            let navigation = try XCTUnwrap(controller.webView.loadSimulatedRequest(
                URLRequest(url: URL(string: "https://chatgpt.com/refresh-feedback-fixture")!), responseHTML: html))
            controller.refreshFeedback.trackRequestedNavigation(navigation)
            wait(for: [loaded], timeout: 5)
            XCTAssertTrue(controller.refreshFeedback.navigationFinished(navigation))
            controller.verifyRefreshedPage(navigation: navigation, attempt: 10)
            waitForState(.failed, in: controller)
            XCTAssertTrue(controller.navigationReloadButton?.isEnabled == true)
            XCTAssertFalse(controller.navigationReloadButton?.accessibilityLabel()?.contains("刷新完成") == true)
        }
    }

    func testCancellationFailureAndStaleCallbacksRespectNavigationIdentity() throws {
        let controller = makeController()
        defer { controller.dispose() }
        controller.webView.navigationDelegate = nil
        let first = try XCTUnwrap(controller.webView.loadHTMLString("first fixture", baseURL: nil))
        let second = try XCTUnwrap(controller.webView.loadHTMLString("second fixture", baseURL: nil))
        controller.webView.stopLoading()
        let feedback = controller.refreshFeedback
        XCTAssertTrue(feedback.beginRefresh())
        feedback.trackRequestedNavigation(first)
        controller.webView(controller.webView, didStartProvisionalNavigation: first)
        controller.webView(controller.webView, didFailProvisionalNavigation: first, withError: URLError(.cancelled))
        XCTAssertEqual(feedback.state, .idle)
        XCTAssertTrue(feedback.beginRefresh())
        feedback.trackRequestedNavigation(second)
        let generation = feedback.generation
        controller.webView(controller.webView, didStartProvisionalNavigation: first)
        XCTAssertEqual(feedback.generation, generation, "A stale provisional-start callback cannot replace the active refresh")
        XCTAssertTrue(feedback.accepts(second))
        controller.webView(controller.webView, didStartProvisionalNavigation: second)
        controller.webView(controller.webView, didFinish: first)
        controller.webView(controller.webView, didFailProvisionalNavigation: first, withError: URLError(.timedOut))
        XCTAssertEqual(feedback.state, .loading)
        XCTAssertFalse(controller.hasFailedNavigation)
        controller.webView(controller.webView, didFail: second, withError: URLError(.timedOut))
        XCTAssertEqual(feedback.state, .failed)
        XCTAssertTrue(controller.hasFailedNavigation)
        XCTAssertTrue(feedback.beginRefresh())
        feedback.trackRequestedNavigation(first)
        feedback.navigationBecameDownload()
        XCTAssertEqual(feedback.state, .idle)
        feedback.navigationFailed(first)
        XCTAssertEqual(feedback.state, .idle, "A late download cancellation must not become a refresh failure")
    }

    func testOldVerificationAndCompletionTimerCannotOverrideANewRefresh() throws {
        let controller = makeController()
        defer { controller.dispose() }
        controller.webView.navigationDelegate = nil
        let first = try XCTUnwrap(controller.webView.loadHTMLString("first fixture", baseURL: nil))
        let second = try XCTUnwrap(controller.webView.loadHTMLString("second fixture", baseURL: nil))
        controller.webView.stopLoading()
        let feedback = controller.refreshFeedback
        XCTAssertTrue(feedback.beginRefresh())
        feedback.trackRequestedNavigation(first)
        XCTAssertTrue(feedback.navigationFinished(first))
        let oldGeneration = feedback.generation
        feedback.verified(first, generation: oldGeneration, success: true)
        XCTAssertEqual(feedback.state, .completed)
        XCTAssertTrue(feedback.beginRefresh())
        feedback.trackRequestedNavigation(second)
        feedback.verified(first, generation: oldGeneration, success: true)
        settle(1.1)
        XCTAssertEqual(feedback.state, .loading, "The previous checkmark timer cannot clear the new spinner")
        XCTAssertTrue(feedback.navigationFinished(second))
        feedback.processTerminated()
        feedback.verified(second, generation: feedback.generation - 1, success: true)
        XCTAssertEqual(feedback.state, .failed)
        feedback.invalidate()
        XCTAssertFalse(feedback.accepts(second))
    }
}

/// The fixture scheme has no network or persistent data. Production response and
/// lifecycle delegates still handle real WebKit callbacks, including real reload().
@MainActor
private final class RefreshFixtureDelegate: NSObject, WKNavigationDelegate {
    let controller: BrowserWindowController
    var finished: (() -> Void)?
    var forwardsFinish = true
    var lastHTTPStatus: Int?
    init(controller: BrowserWindowController) { self.controller = controller }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        controller.webView(webView, didStartProvisionalNavigation: navigation)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        lastHTTPStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        controller.webView(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if forwardsFinish { controller.webView(webView, didFinish: navigation) }
        finished?()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        controller.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        controller.webView(webView, didFail: navigation, withError: error)
    }
}

/// Simulated requests and custom schemes lose HTTP status metadata in WebKit.
/// Keep this server on loopback and forward real response/lifecycle callbacks.
@MainActor
private final class RefreshHTTPFixtureServer {
    let listener: NWListener
    var responseStatus = 200
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(ready: @escaping @MainActor @Sendable () -> Void) {
        listener.stateUpdateHandler = { state in
            if case .ready = state { Task { @MainActor in ready() } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
                    Task { @MainActor in
                        guard let self else { connection.cancel(); return }
                        let body = "<html><body><main>Rendered HTTP fixture content</main></body></html>"
                        let response = "HTTP/1.1 \(self.responseStatus) Fixture\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}

@MainActor
private final class RefreshFixtureHandler: NSObject, WKURLSchemeHandler {
    private(set) var requestCount = 0
    private var pending: [ObjectIdentifier: DispatchWorkItem] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        requestCount += 1
        let key = ObjectIdentifier(urlSchemeTask)
        let work = DispatchWorkItem { [weak self] in
            guard self?.pending.removeValue(forKey: key) != nil else { return }
            let data = Data("<html><body><main>Rendered refresh fixture content</main></body></html>".utf8)
            urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                                 expectedContentLength: data.count, textEncodingName: "utf-8"))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
        pending[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
