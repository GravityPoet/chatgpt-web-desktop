import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class BrowserPageScriptIntegrationTests: XCTestCase {
    func testSilentDraftDoesNotAddUIOrOverwriteExistingInput() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        let countBefore = try stringResult("String(document.body.querySelectorAll('*').length)", in: harness.webView)
        let reportBefore = try dictionaryResult("""
        (() => {
          const c = document.getElementById('prompt-textarea');
          const top = c.getBoundingClientRect().top;
          window.__chatgptSwiftDraftUI.configure({enabled:true,path:'/',autofocus:false});
          return {top,after:c.getBoundingClientRect().top,banner:!!document.getElementById('chatgpt-swift-draft-status')};
        })()
        """, in: harness.webView)
        settle(0.2)
        XCTAssertEqual(reportBefore["top"] as? Double, reportBefore["after"] as? Double)
        XCTAssertEqual(reportBefore["banner"] as? Bool, false)
        XCTAssertEqual(try stringResult("String(document.body.querySelectorAll('*').length)", in: harness.webView), countBefore)
        _ = try stringResult("document.getElementById('prompt-textarea').textContent = 'keep this'", in: harness.webView)
        let report = try dictionaryResult(BrowserWindowController.restorePromptDraftScript(text: "saved draft"), in: harness.webView)
        XCTAssertEqual(report["restored"] as? Bool, false)
        XCTAssertEqual(report["reason"] as? String, "composer not empty")
        XCTAssertEqual(try stringResult("document.getElementById('prompt-textarea').textContent", in: harness.webView), "keep this")
    }

    func testReplyAndEmptyComposerDoNotEmitDeletionOrAddDraftUI() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try dictionaryResult("""
        (() => {
          const c = document.getElementById('prompt-textarea');
          c.textContent = 'synthetic question';
          c.dispatchEvent(new InputEvent('input', {bubbles:true}));
          c.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));
          c.textContent = '';
          c.dispatchEvent(new InputEvent('input', {bubbles:true}));
          const sent = document.createElement('div');
          sent.setAttribute('data-message-author-role','user'); sent.textContent='synthetic question';
          document.querySelector('main').append(sent);
          return {ok:true};
        })()
        """, in: harness.webView)
        settle(0.5)
        XCTAssertFalse(sink.messages.contains { $0.payload["action"] as? String == "sent" })
        XCTAssertEqual(sink.messages.first { $0.payload["action"] as? String == "save" }?.payload["text"] as? String, "synthetic question")
        _ = try dictionaryResult("""
        (() => {
          const reply=document.createElement('div'); reply.setAttribute('data-message-author-role','assistant');
          reply.textContent='Synthetic reply'; document.querySelector('main').append(reply);
          return {ok:true};
        })()
        """, in: harness.webView)
        settle(0.4)
        XCTAssertFalse(sink.messages.contains { ["sent", "discard", "clear"].contains($0.payload["action"] as? String ?? "") })
        let saves = sink.messages.filter { $0.payload["action"] as? String == "save" }
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(saves.first?.payload["text"] as? String, "synthetic question")
        XCTAssertEqual(try stringResult("String(!!document.getElementById('chatgpt-swift-draft-status'))", in: harness.webView), "false")
        XCTAssertEqual(try stringResult("document.getElementById('prompt-textarea').textContent", in: harness.webView), "")
    }

    func testIMECompositionAndNewlineDraftCaptureWithoutLayoutReads() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        _ = try dictionaryResult("""
        (() => {
          const c=document.getElementById('prompt-textarea');
          Object.defineProperty(c,'innerText',{get(){throw new Error('layout text read');}});
          c.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));
          c.innerHTML='<p>你好</p><p>第二行</p>';
          c.dispatchEvent(new InputEvent('input',{bubbles:true,isComposing:true}));
          c.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,isComposing:true}));
          return {ok:true};
        })()
        """, in: harness.webView)
        settle(0.5)
        XCTAssertFalse(sink.messages.contains { $0.payload["action"] as? String == "save" || $0.payload["action"] as? String == "sent" })
        _ = try dictionaryResult("""
        (() => { document.getElementById('prompt-textarea').dispatchEvent(new CompositionEvent('compositionend',{bubbles:true})); return {ok:true}; })()
        """, in: harness.webView)
        settle(0.5)
        XCTAssertEqual(sink.messages.first { $0.payload["action"] as? String == "save" }?.payload["text"] as? String, "你好\n第二行")
    }

    func testGenerationObserverHandlesControlReplacementAndVisibility() throws {
        let sink = ScriptMessageSink(expectations: [:])
        let harness = try makeHarness(sink: sink, html: Self.chatPageHTML)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 3)
        settle(0.3)
        _ = try dictionaryResult("(() => {document.querySelector('[data-testid=stop-button]').remove();return {ok:true};})()", in: harness.webView)
        settle(0.3)
        _ = try dictionaryResult("""
        (() => { const b=document.createElement('button'); b.setAttribute('aria-label','停止'); b.textContent='Stop'; document.querySelector('main').append(b); return {ok:true}; })()
        """, in: harness.webView)
        settle(0.3)
        _ = try dictionaryResult("(() => {document.querySelector('button').hidden=true;return {ok:true};})()", in: harness.webView)
        settle(0.3)
        XCTAssertEqual(sink.messages.filter { $0.name == "completionState" }.compactMap { $0.payload["busy"] as? Bool }, [true, false, true, false])
    }

    private func settle(_ delay: TimeInterval) {
        let done = expectation(description: "page events settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { done.fulfill() }
        wait(for: [done], timeout: delay + 2)
    }

    func testStreamingObserverWorkOnLongConversation() throws {
        let history = String(repeating: "<article><p>Long conversation response</p><button>Copy</button></article>", count: 6000)
        let html = "<html><body><main id='history'>\(history)</main><form><div id='prompt-textarea' contenteditable='true'></div><button data-testid='stop-button'>Stop</button></form></body></html>"
        let harness = try makeHarness(sink: ScriptMessageSink(expectations: [:]), html: html)
        defer { harness.close() }
        wait(for: [harness.navigationExpectation], timeout: 5)
        _ = try dictionaryResult("""
        (() => {
          const metrics = window.__observerMetrics = { scans: 0, scanMs: 0 };
          for (const proto of [Document.prototype, Element.prototype]) {
            const original = proto.querySelectorAll;
            proto.querySelectorAll = function(selector) {
              const start = performance.now();
              const result = original.call(this, selector);
              if (String(selector).includes('stop') || String(selector).includes('aria-busy')) {
                metrics.scans++; metrics.scanMs += performance.now() - start;
              }
              return result;
            };
          }
          const target = document.getElementById('history').lastElementChild;
          let count = 0;
          const timer = setInterval(() => {
            target.append(document.createTextNode(' streamed token'));
            if (++count >= 60) clearInterval(timer);
          }, 30);
          return { started: true };
        })()
        """, in: harness.webView)
        let finished = expectation(description: "streaming fixture settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { finished.fulfill() }
        wait(for: [finished], timeout: 4)
        let metrics = try dictionaryResult("window.__observerMetrics", in: harness.webView)
        print("STREAMING_OBSERVER_METRICS \(metrics)")
        XCTAssertEqual(metrics["scans"] as? Int, 0, "Text streaming must not rescan busy selectors across the long conversation")
    }

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
        if payload["action"] as? String != "ready" { expectations[message.name]?.fulfill() }
    }

    func payload(named name: String) -> [String: Any]? {
        messages.first(where: { $0.name == name && $0.payload["action"] as? String != "ready" })?.payload
    }
}
