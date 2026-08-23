import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class BrowserPageScriptIntegrationTests: XCTestCase {
    func testDraftAndCompletionScriptsWorkWithoutWholePageDraftObservation() throws {
        let promptExpectation = expectation(description: "prompt draft bridged")
        let completionExpectation = expectation(description: "completion state bridged")
        let sink = ScriptMessageSink(expectations: [
            "promptDraft": promptExpectation,
            "completionState": completionExpectation,
        ])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }

        wait(for: [harness.navigationExpectation], timeout: 3)
        XCTAssertEqual(try stringResult("location.hostname", in: harness.webView), "chatgpt.com")

        harness.webView.evaluateJavaScript("""
        (() => {
          const composer = document.getElementById('prompt-textarea');
          composer.textContent = 'local draft';
          composer.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'local draft' }));
        })()
        """)

        wait(for: [promptExpectation, completionExpectation], timeout: 3)
        XCTAssertEqual(sink.payload(named: "promptDraft")?["text"] as? String, "local draft")
        XCTAssertEqual(sink.payload(named: "completionState")?["busy"] as? Bool, true)
    }

    func testChallengePageSkipsAuxiliaryObserversAndIsReportedAsChallenge() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.challengePageHTML)
        defer { harness.close() }

        wait(for: [harness.navigationExpectation], timeout: 3)
        harness.webView.evaluateJavaScript("""
        (() => {
          const composer = document.getElementById('prompt-textarea');
          composer.textContent = 'should not bridge';
          composer.dispatchEvent(new InputEvent('input', { bubbles: true, data: 'should not bridge' }));
        })()
        """)

        let settled = expectation(description: "challenge observers remain idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertTrue(sink.messages.isEmpty)

        let report = try dictionaryResult(BrowserWindowController.renderedContentProbeScript, in: harness.webView)
        XCTAssertEqual(report["cloudflareChallenge"] as? Bool, true)
        XCTAssertEqual(report["blank"] as? Bool, false)
    }

    func testDraftRestoreWorksOnlyOnTrustedChatGPTOrigin() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let trusted = try makeHarness(
            sink: sink,
            html: Self.genericTextAreaHTML,
            baseURL: try XCTUnwrap(URL(string: "https://chatgpt.com/"))
        )
        defer { trusted.close() }
        wait(for: [trusted.navigationExpectation], timeout: 3)

        let trustedReport = try dictionaryResult(
            BrowserWindowController.restorePromptDraftScript(text: "private local draft"),
            in: trusted.webView
        )
        XCTAssertEqual(trustedReport["restored"] as? Bool, true)
        XCTAssertEqual(try stringResult("document.querySelector('textarea').value", in: trusted.webView), "private local draft")

        let untrusted = try makeHarness(
            sink: ScriptMessageSink(expectations: [:]),
            html: Self.genericTextAreaHTML,
            baseURL: try XCTUnwrap(URL(string: "https://example.com/"))
        )
        defer { untrusted.close() }
        wait(for: [untrusted.navigationExpectation], timeout: 3)

        let untrustedReport = try dictionaryResult(
            BrowserWindowController.restorePromptDraftScript(text: "private local draft"),
            in: untrusted.webView
        )
        XCTAssertEqual(untrustedReport["restored"] as? Bool, false)
        XCTAssertEqual(untrustedReport["reason"] as? String, "untrusted origin")
        XCTAssertEqual(try stringResult("document.querySelector('textarea').value", in: untrusted.webView), "")
    }

    func testNativeDraftRestoreGateRejectsThirdPartyAndNonHTTPSURLs() throws {
        XCTAssertTrue(BrowserWindowController.canInjectPromptContent(
            into: try XCTUnwrap(URL(string: "https://chatgpt.com/c/example"))
        ))
        XCTAssertTrue(BrowserWindowController.canInjectPromptContent(
            into: try XCTUnwrap(URL(string: "https://chat.openai.com/"))
        ))
        XCTAssertFalse(BrowserWindowController.canInjectPromptContent(
            into: try XCTUnwrap(URL(string: "https://example.com/"))
        ))
        XCTAssertFalse(BrowserWindowController.canInjectPromptContent(
            into: try XCTUnwrap(URL(string: "http://chatgpt.com/"))
        ))
    }

    func testNativePromptInjectionScriptRejectsThirdPartyOrigin() throws {
        let trusted = try makeHarness(
            sink: ScriptMessageSink(expectations: [:]),
            html: Self.genericTextAreaHTML,
            baseURL: try XCTUnwrap(URL(string: "https://chatgpt.com/"))
        )
        defer { trusted.close() }
        wait(for: [trusted.navigationExpectation], timeout: 3)
        let trustedReport = try dictionaryResult(
            BrowserWindowController.insertPromptTextScript(text: "selected note"),
            in: trusted.webView
        )
        XCTAssertEqual(trustedReport["ok"] as? Bool, true)
        XCTAssertEqual(try stringResult("document.querySelector('textarea').value", in: trusted.webView), "selected note")

        let untrusted = try makeHarness(
            sink: ScriptMessageSink(expectations: [:]),
            html: Self.genericTextAreaHTML,
            baseURL: try XCTUnwrap(URL(string: "https://example.com/"))
        )
        defer { untrusted.close() }
        wait(for: [untrusted.navigationExpectation], timeout: 3)
        let untrustedReport = try dictionaryResult(
            BrowserWindowController.insertPromptTextScript(text: "selected note"),
            in: untrusted.webView
        )
        XCTAssertEqual(untrustedReport["ok"] as? Bool, false)
        XCTAssertEqual(untrustedReport["reason"] as? String, "untrusted origin")
        XCTAssertEqual(try stringResult("document.querySelector('textarea').value", in: untrusted.webView), "")
    }

    private func makeHarness(
        sink: ScriptMessageSink,
        html: String,
        baseURL: URL? = URL(string: "https://chatgpt.com/")
    ) throws -> WebViewHarness {
        let controller = WKUserContentController()
        controller.add(sink, name: "promptDraft")
        controller.add(sink, name: "completionState")
        controller.addUserScript(WKUserScript(
            source: BrowserWindowController.promptDraftCaptureScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        controller.addUserScript(WKUserScript(
            source: BrowserWindowController.completionStateObserverScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        let waiter = NavigationWaiter(expectation: expectation(description: "HTML loaded"))
        webView.navigationDelegate = waiter

        webView.loadHTMLString(html, baseURL: try XCTUnwrap(baseURL))
        return WebViewHarness(webView: webView, waiter: waiter)
    }

    private func stringResult(_ script: String, in webView: WKWebView) throws -> String {
        let completed = expectation(description: "JavaScript string result")
        var output: String?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in
            output = result as? String
            failure = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        if let failure { throw failure }
        return try XCTUnwrap(output)
    }

    private func dictionaryResult(_ script: String, in webView: WKWebView) throws -> [String: Any] {
        let completed = expectation(description: "JavaScript dictionary result")
        var output: [String: Any]?
        var failure: Error?
        webView.evaluateJavaScript(script) { result, error in
            output = result as? [String: Any]
            failure = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        if let failure { throw failure }
        return try XCTUnwrap(output)
    }

    private static let chatPageHTML = """
    <!doctype html><html><body>
      <main style="width:600px;height:400px">
        <div id="prompt-textarea" data-testid="prompt-textarea" contenteditable="true"></div>
        <button data-testid="stop-button" aria-label="Stop generating">Stop</button>
      </main>
    </body></html>
    """

    private static let challengePageHTML = """
    <!doctype html><html><body>
      <main id="challenge-stage" style="width:600px;height:400px">
        <div id="prompt-textarea" data-testid="prompt-textarea" contenteditable="true"></div>
        <button data-testid="stop-button" aria-label="Stop generating">Stop</button>
      </main>
    </body></html>
    """

    private static let genericTextAreaHTML = """
    <!doctype html><html><body>
      <main style="width:600px;height:400px"><textarea></textarea></main>
    </body></html>
    """
}

@MainActor
private final class WebViewHarness {
    let webView: WKWebView
    let waiter: NavigationWaiter

    var navigationExpectation: XCTestExpectation { waiter.expectation }

    init(webView: WKWebView, waiter: NavigationWaiter) {
        self.webView = webView
        self.waiter = waiter
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "promptDraft")
        controller.removeScriptMessageHandler(forName: "completionState")
        controller.removeAllUserScripts()
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }
}

private final class ScriptMessageSink: NSObject, WKScriptMessageHandler {
    private let expectations: [String: XCTestExpectation]
    private(set) var messages: [(name: String, payload: [String: Any])] = []

    init(expectations: [String: XCTestExpectation]) {
        self.expectations = expectations
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        messages.append((message.name, payload))
        expectations[message.name]?.fulfill()
    }

    func payload(named name: String) -> [String: Any]? {
        messages.first(where: { $0.name == name })?.payload
    }
}
