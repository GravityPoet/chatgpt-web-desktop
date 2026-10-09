import AppKit
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class DataLoadRecoveryTests: XCTestCase {
    private let page = URL(string: "https://chatgpt.com/c/recovery-fixture")!
    private let html = """
    <html><body><nav id="service-errors"></nav><main>
    <textarea id="prompt-textarea" data-testid="prompt-textarea"></textarea>
    <button aria-label="选择 ChatGPT 模型">Pro</button></main></body></html>
    """

    private func makeController() -> BrowserWindowController {
        let controller = BrowserWindowController(initialURL: nil, title: "Data recovery fixture", isPopup: true, persistent: false)
        let scripts = controller.webView.configuration.userContentController.userScripts.map {
            WKUserScript(source: $0.source, injectionTime: $0.injectionTime, forMainFrameOnly: $0.isForMainFrameOnly)
        }
        controller.webView.configuration.userContentController.removeAllUserScripts()
        controller.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
        window.__fixtureRequests=[];window.__fixtureStatus=200;window.__fixtureChallenge=false;
        window.fetch=function(input,options){
          const url=typeof input==='string' || input instanceof URL?String(input):input.url;
          const method=options?.method || input?.method || 'GET';
          window.__fixtureRequests.push({url,method});
          const headers=window.__fixtureChallenge?{'cf-mitigated':'challenge'}:{};
          window.__fixturePromise=Promise.resolve(new Response('fixture response body',{status:window.__fixtureStatus,headers}));
          return window.__fixturePromise;
        };
        window.XMLHttpRequest=class extends EventTarget {
          constructor(){super();this.status=200;this.header='';}
          open(){} getResponseHeader(){return this.header;}
        };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.forEach { controller.webView.configuration.userContentController.addUserScript($0) }
        controller.webView.loadSimulatedRequest(URLRequest(url: page), responseHTML: html)
        waitUntil { controller.webView.url == self.page && !controller.webView.isLoading }
        return controller
    }

    private func waitUntil(timeout: TimeInterval = 6, _ condition: @escaping () -> Bool) {
        let reached = expectation(description: "recovery condition")
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() || Date() >= deadline { reached.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
        }
        poll()
        wait(for: [reached], timeout: timeout + 1)
        XCTAssertTrue(condition())
    }

    @discardableResult
    private func evaluate(_ script: String, in controller: BrowserWindowController) throws -> Any? {
        let done = expectation(description: "fixture JavaScript")
        var output: Any?, failure: Error?
        controller.webView.evaluateJavaScript(script) { value, error in output = value; failure = error; done.fulfill() }
        wait(for: [done], timeout: 3)
        if let failure { throw failure }
        return output
    }

    private func settle() {
        let done = expectation(description: "debounced health report")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }

    func testLateFailuresBeyondFirst240ControlsAreDetectedAndClearOnRecovery() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        (()=>{const nav=document.getElementById('service-errors');
        for(let i=0;i<350;i++){const b=document.createElement('button');b.textContent='Item '+i;nav.append(b);}
        nav.insertAdjacentHTML('beforeend','<span>无法加载 ChatGPT 模型</span><span>无法加载历史记录</span><h1>无法加载你的账户</h1><span>无法加载项目</span>');})()
        """, in: controller)
        waitUntil { controller.dataLoadState.failures.count == 4 }
        XCTAssertTrue(controller.modelLoadFailureActive)
        XCTAssertGreaterThan(controller.modelLoadFailureCount, 0)
        XCTAssertTrue(controller.diagnosticsReport().contains("dataLoadFailures: 账户, 模型, 历史记录, 项目"))
        let report = try XCTUnwrap(try evaluate(BrowserWindowController.renderedContentProbeScript, in: controller) as? [String: Any])
        XCTAssertEqual(report["dataLoadFailure"] as? Bool, true)

        try evaluate("document.getElementById('service-errors').replaceChildren()", in: controller)
        waitUntil { !controller.dataLoadState.hasFailure }
        XCTAssertFalse(controller.modelLoadFailureActive)
    }

    func testQuotedErrorsHiddenContentAndComposerDoNotBecomeServiceFailures() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        document.querySelector('main').insertAdjacentHTML('beforeend',
          '<article>无法加载 ChatGPT 模型</article><div data-message-author-role="assistant">无法加载历史记录</div><span hidden>无法加载你的账户</span><span style="display:none">无法加载项目</span>');
        document.querySelector('textarea').value='无法加载 ChatGPT 模型';
        """, in: controller)
        settle()
        XCTAssertFalse(controller.dataLoadState.hasFailure)
        let report = try XCTUnwrap(try evaluate(BrowserWindowController.renderedContentProbeScript, in: controller) as? [String: Any])
        XCTAssertEqual(report["dataLoadFailure"] as? Bool, false)
    }

    func testFetchKeepsOriginalPromiseAndIgnoresPostsForeignOriginsAndOrdinary403() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        window.__fixtureStatus=403;window.__fixtureChallenge=true;
        fetch('/backend-api/conversation',{method:'POST'});
        fetch('https://example.com/backend-api/models');fetch('/assets/model.json');'requested';
        """, in: controller)
        settle()
        XCTAssertFalse(controller.dataLoadState.requiresVerification)
        try evaluate("window.__fixtureChallenge=false;fetch('/backend-api/models');'requested'", in: controller)
        settle()
        XCTAssertFalse(controller.dataLoadState.requiresVerification)
        let samePromise = try evaluate("window.__fixtureChallenge=true;fetch(new URL('/backend-api/models',location.origin))===window.__fixturePromise", in: controller)
        XCTAssertEqual(samePromise as? Bool, true)
        waitUntil { controller.dataLoadState.requiresVerification }
        waitUntil { controller.dataVerificationWindow != nil }
        XCTAssertEqual(controller.navigationReloadButton?.accessibilityLabel(), "完成安全验证并重试")
        try evaluate("window.__fixtureStatus=200;window.__fixtureChallenge=false;fetch('/backend-api/conversations');'requested'", in: controller)
        settle()
        XCTAssertTrue(controller.dataLoadState.requiresVerification)
        try evaluate("fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { !controller.dataLoadState.requiresVerification }
    }

    func testChallengeAutomaticallyOpensSameAccountVerificationWindowWithoutClick() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        XCTAssertEqual(child.window.title, "完成 ChatGPT 安全验证")
        XCTAssertTrue(child.window.isVisible)
        XCTAssertTrue(child.webView.configuration.websiteDataStore === controller.webView.configuration.websiteDataStore)
        XCTAssertEqual(child.dataVerificationURL?.path, "/backend-api/models")
        child.window.performClose(nil)
        waitUntil { controller.dataVerificationWindow == nil }
        XCTAssertTrue(controller.dataLoadState.requiresVerification)
    }

    func testReusedXHRUsesCurrentRequestAndCannotTreatPostAsChallengedGet() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        window.fixtureXHR=new XMLHttpRequest();fixtureXHR.open('GET','/backend-api/models');
        fixtureXHR.open('POST','/backend-api/conversation');fixtureXHR.status=403;fixtureXHR.header='challenge';fixtureXHR.dispatchEvent(new Event('load'));
        """, in: controller)
        settle()
        XCTAssertFalse(controller.dataLoadState.requiresVerification)
        try evaluate("fixtureXHR.open('GET','/backend-api/models');fixtureXHR.dispatchEvent(new Event('load'))", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        try evaluate("fixtureXHR.status=200;fixtureXHR.header='';fixtureXHR.dispatchEvent(new Event('load'))", in: controller)
        waitUntil { !controller.dataLoadState.requiresVerification }
    }

    func testVerificationUsesChallengedAccountEndpointAndRejectsOtherPaths() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/api/auth/session');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        XCTAssertEqual(controller.dataLoadState.verificationPath, "/api/auth/session")
        try evaluate("fetch('/backend-api/models');'requested'", in: controller)
        settle()
        XCTAssertEqual(controller.dataLoadState.verificationPath, "/api/auth/session")
        XCTAssertTrue(BrowserWindowController.isAllowedDataVerificationPath("/backend-api/accounts/check/v4-2026-10-05"))
        for path in ["/backend-api/logout", "/api/auth/signout", "/backend-api/models?code=fixture", "/backend-api/../logout", "https://example.com/backend-api/models"] {
            XCTAssertFalse(BrowserWindowController.isAllowedDataVerificationPath(path))
        }
        try evaluate("window.__fixtureStatus=200;window.__fixtureChallenge=false;fetch('/api/auth/session');fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { !controller.dataLoadState.requiresVerification }
        try evaluate("window.webkit.messageHandlers.dataLoad.postMessage({path:location.pathname,failures:{},challenged:true,verificationPath:'/api/auth/signout'});'posted'", in: controller)
        settle()
        XCTAssertFalse(controller.dataLoadState.requiresVerification)
    }

    func testProtectedEndpointCanFinishChallengeWith401WithoutClaimingDataLoaded() throws {
        let controller = makeController()
        defer { controller.dispose() }
        let url = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2026-10-05")!
        controller.dataVerificationURL = url
        controller.dataLoadState.failures = ["账户"]
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: ["Content-Type":"application/json"]))
        var finished = false
        controller.dataVerificationCompleted = { finished = true }
        controller.noteDataVerificationResponse(response)
        XCTAssertFalse(controller.finishDataVerificationIfReady())
        controller.cloudflareChallengeCount = 1
        controller.noteDataVerificationResponse(response)
        XCTAssertTrue(controller.finishDataVerificationIfReady())
        XCTAssertTrue(finished)
        XCTAssertTrue(controller.dataLoadState.hasFailure)
    }

    func testAuthenticationJSONIsCancelledBeforeDisplayOrDownload() throws {
        let controller = makeController()
        defer { controller.dispose() }
        let url = URL(string: "https://chatgpt.com/api/auth/session")!
        controller.dataVerificationURL = url
        var finished = false
        controller.dataVerificationCompleted = { finished = true }
        let responseURL = try XCTUnwrap(URL(string: url.absoluteString + "?__cf_chl_tk=fixture"))
        let response = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"]))
        let policy = controller.dataVerificationResponsePolicy(response)
        XCTAssertEqual(policy, .cancel)
        waitUntil { finished }
    }

    func testVerificationCompletionRequiresExactSuccessfulJSONResponse() throws {
        let controller = makeController()
        defer { controller.dispose() }
        let verification = URL(string: "https://chatgpt.com/backend-api/models")!
        controller.dataVerificationURL = verification
        var completions = 0
        controller.dataVerificationCompleted = { completions += 1 }
        for (url, status, headers) in [
            (verification, 403, ["Content-Type":"text/html", "cf-mitigated":"challenge"]),
            (verification, 401, ["Content-Type":"application/json"]),
            (verification, 200, ["Content-Type":"text/html"]),
            (URL(string: "https://example.com/backend-api/models")!, 200, ["Content-Type":"application/json"])
        ] {
            controller.noteDataVerificationResponse(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
            XCTAssertFalse(controller.finishDataVerificationIfReady())
        }
        XCTAssertEqual(completions, 0)
        controller.noteDataVerificationResponse(try XCTUnwrap(HTTPURLResponse(url: verification, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])))
        XCTAssertTrue(controller.finishDataVerificationIfReady())
        XCTAssertFalse(controller.finishDataVerificationIfReady())
        XCTAssertEqual(completions, 1)
    }

    func testVerifyButtonSharesSessionThenReloadsOriginalPageAndRestoresUnsentDraft() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("document.querySelector('textarea').value='保留的未发送草稿';window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        let action = try XCTUnwrap(buttons(in: controller.window.contentView!).first { $0.title == "验证并重试" })
        action.performClick(nil)
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        child.webView.stopLoading()
        XCTAssertTrue(child.webView.configuration.websiteDataStore === controller.webView.configuration.websiteDataStore)
        XCTAssertEqual(controller.webView.url, page)
        action.performClick(nil)
        XCTAssertTrue(controller.dataVerificationWindow === child)
        child.webView.stopLoading()

        let delegate = RecoveryReloadDelegate(controller: controller, html: html)
        controller.webView.navigationDelegate = delegate
        let url = try XCTUnwrap(child.dataVerificationURL)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"]))
        let verificationDelegate = RecoveryVerificationDelegate(controller: child, response: response)
        child.webView.navigationDelegate = verificationDelegate
        child.webView.loadSimulatedRequest(URLRequest(url: url), response: response, responseData: Data("{\"models\":[]}".utf8))
        waitUntil { delegate.reloads == 1 && !controller.webView.isLoading && controller.dataRecoveryDraft == nil }
        if delegate.reloads == 0 {
            print("RECOVERY_VERIFICATION_RESPONSE", verificationDelegate.summary,
                  "ready", child.dataVerificationResponseReady, "callback", child.dataVerificationCompleted != nil)
            print(child.diagnosticsReport())
        }
        XCTAssertNil(controller.dataVerificationWindow)
        XCTAssertEqual(controller.webView.url, page)
        XCTAssertEqual(try evaluate("document.querySelector('textarea').value", in: controller) as? String, "保留的未发送草稿")
        XCTAssertEqual(try evaluate("window.__fixtureRequests.filter(r=>r.method==='POST').length", in: controller) as? Int, 0)
        waitUntil { !controller.dataLoadState.hasFailure }
        _ = delegate
    }

    func testActiveResponseCannotBeInterruptedAndClosingVerificationKeepsDraft() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("document.querySelector('textarea').value='仍在编辑';window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        if let automaticWindow = controller.dataVerificationWindow {
            automaticWindow.window.performClose(nil)
            waitUntil { controller.dataVerificationWindow == nil }
        }
        controller.isAssistantResponseInProgress = true
        controller.recoverDataLoad()
        XCTAssertNil(controller.dataVerificationWindow)
        controller.isAssistantResponseInProgress = false
        controller.recoverDataLoad()
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        child.webView.stopLoading()
        child.window.performClose(nil)
        waitUntil { controller.dataVerificationWindow == nil }
        XCTAssertTrue(controller.dataLoadState.requiresVerification)
        XCTAssertEqual(try evaluate("document.querySelector('textarea').value", in: controller) as? String, "仍在编辑")
    }
}

@MainActor
private final class RecoveryReloadDelegate: NSObject, WKNavigationDelegate {
    let controller: BrowserWindowController
    let html: String
    var reloads = 0
    init(controller: BrowserWindowController, html: String) { self.controller = controller; self.html = html }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if reloads == 0 {
            reloads += 1
            decisionHandler(.cancel)
            let navigation = webView.loadSimulatedRequest(action.request, responseHTML: html)
            controller.refreshFeedback.trackRequestedNavigation(navigation)
        } else {
            controller.webView(webView, decidePolicyFor: action, decisionHandler: decisionHandler)
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { controller.webView(webView, didStartProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { controller.webView(webView, didFinish: navigation) }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        controller.webView(webView, decidePolicyFor: response, decisionHandler: decisionHandler)
    }
}

@MainActor
private final class RecoveryVerificationDelegate: NSObject, WKNavigationDelegate {
    let controller: BrowserWindowController
    let response: HTTPURLResponse
    var summary = "no response"
    init(controller: BrowserWindowController, response: HTTPURLResponse) { self.controller = controller; self.response = response }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        summary = "\(type(of: response.response)) mime=\(response.response.mimeType ?? "nil") canShow=\(response.canShowMIMEType) status=\((response.response as? HTTPURLResponse)?.statusCode ?? -1)"
        controller.webView(webView, decidePolicyFor: response, decisionHandler: decisionHandler)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { controller.webView(webView, didStartProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // loadSimulatedRequest renders an HTTPS document without invoking response policy.
        // Supply that document's known response metadata before its real finish callback.
        if webView.url == response.url { controller.noteDataVerificationResponse(response) }
        controller.webView(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { controller.webView(webView, didFailProvisionalNavigation: navigation, withError: error) }
}
