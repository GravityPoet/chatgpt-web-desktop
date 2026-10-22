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
        window.__fixtureChallengeBody='<html><head></head><body id="cf-challenge-running">Fixture browser check</body></html>';
        window.fetch=function(input,options){
          const url=typeof input==='string' || input instanceof URL?String(input):input.url;
          const method=options?.method || input?.method || 'GET';
          window.__fixtureRequests.push({url,method});
          const headers=window.__fixtureChallenge?{'cf-mitigated':'challenge','Content-Type':'text/html'}:{'Content-Type':'application/json'};
          if(window.__fixtureChallenge && window.__fixtureChallengeCSP)headers['Content-Security-Policy']=window.__fixtureChallengeCSP;
          window.__fixturePromise=Promise.resolve(window.__fixtureResponse || new Response(window.__fixtureChallenge?window.__fixtureChallengeBody:'fixture response body',{status:window.__fixtureStatus,headers}));
          return window.__fixturePromise;
        };
        window.XMLHttpRequest=class extends EventTarget {
          constructor(){super();this.status=200;this.header='';this.responseType='';this.responseText=window.__fixtureChallengeBody;}
          open(method,url){this.responseURL=new URL(url,location.href).href;}
          send(){}
          getResponseHeader(name){return name==='cf-mitigated'?this.header:(name==='content-type'?(this.header==='challenge'?'text/html':'application/json'):null);}
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
        XCTAssertNotEqual(controller.navigationReloadButton?.accessibilityLabel(), "完成安全验证并重试")
        try evaluate("window.__fixtureStatus=200;window.__fixtureChallenge=false;fetch('/backend-api/conversations');'requested'", in: controller)
        settle()
        XCTAssertTrue(controller.dataLoadState.requiresVerification)
        try evaluate("fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { !controller.dataLoadState.requiresVerification }
    }

    func testChallengeAutomaticallyShowsSameAccountVerificationInCurrentWindowWithoutClick() throws {
        let controller = makeController()
        defer { controller.dispose() }
        controller.show()
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        XCTAssertEqual(child.window.title, "完成 ChatGPT 安全验证")
        XCTAssertFalse(child.window.isVisible)
        XCTAssertTrue(controller.diagnosticsReport().contains("dataVerificationPresentation: in-window"))
        XCTAssertTrue(child.webView.configuration.websiteDataStore === controller.webView.configuration.websiteDataStore)
        XCTAssertEqual(child.dataVerificationURL?.path, "/backend-api/models")
        XCTAssertEqual(child.dataVerificationTargetPath, "/backend-api/models")
        controller.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(child.webView.window === controller.window)
        XCTAssertTrue(controller.webView.isHidden)
        XCTAssertEqual(child.webView.bounds.width, controller.webView.bounds.width, accuracy: 1)
        XCTAssertEqual(child.webView.bounds.height, controller.webView.bounds.height, accuracy: 1)
        try evaluate("fetch('/backend-api/models');'requested'", in: controller)
        settle()
        XCTAssertTrue(controller.dataVerificationWindow === child)
        controller.dismissDataVerification()
        waitUntil { controller.dataVerificationWindow == nil }
        XCTAssertTrue(controller.dataLoadState.requiresVerification)
    }

    func testTopLevelVerificationWindowDoesNotRecursivelyOpenAnotherWindow() throws {
        let controller = makeController()
        defer { controller.dispose() }
        controller.dataVerificationURL = URL(string: "https://chatgpt.com/")
        controller.dataVerificationTargetPath = "/backend-api/models"
        controller.dataLoadState.requiresVerification = true
        controller.scheduleAutomaticDataVerification()
        settle()
        XCTAssertNil(controller.dataVerificationWindow)
    }

    func testReusedXHRUsesCurrentRequestAndCannotTreatPostAsChallengedGet() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        window.fixtureXHR=new XMLHttpRequest();fixtureXHR.open('GET','/backend-api/models');
        fixtureXHR.open('POST','/backend-api/conversation');fixtureXHR.send();fixtureXHR.status=403;fixtureXHR.header='challenge';fixtureXHR.dispatchEvent(new Event('load'));
        """, in: controller)
        settle()
        XCTAssertFalse(controller.dataLoadState.requiresVerification)
        try evaluate("fixtureXHR.open('GET','/backend-api/models');fixtureXHR.send();fixtureXHR.dispatchEvent(new Event('load'))", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        try evaluate("fixtureXHR.open('GET','/backend-api/models');fixtureXHR.send();fixtureXHR.status=200;fixtureXHR.header='';fixtureXHR.dispatchEvent(new Event('load'))", in: controller)
        waitUntil { !controller.dataLoadState.requiresVerification }
    }

    func testXHRTracksSendOrderAndUnsentOpenCannotInvalidateInFlightResponse() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        window.fixtureOpenedFirst=new XMLHttpRequest();
        window.fixtureSentFirst=new XMLHttpRequest();
        fixtureOpenedFirst.open('GET','/backend-api/models?fixture=xhr-order');
        fixtureSentFirst.open('GET','/backend-api/models?fixture=xhr-order');
        fixtureSentFirst.send();
        fixtureOpenedFirst.send();
        window.fixtureNeverSent=new XMLHttpRequest();
        fixtureNeverSent.open('GET','/backend-api/models?fixture=xhr-order');
        fixtureOpenedFirst.status=200;fixtureOpenedFirst.header='';
        fixtureOpenedFirst.dispatchEvent(new Event('load'));'received';
        """, in: controller)
        waitUntil { controller.dataLoadState.responseStatus["/backend-api/models"] == 200 }
        try evaluate("""
        fixtureSentFirst.status=403;fixtureSentFirst.header='challenge';
        fixtureSentFirst.dispatchEvent(new Event('load'));'received';
        """, in: controller)
        settle()
        XCTAssertEqual(controller.dataLoadState.responseStatus["/backend-api/models"], 200)
        XCTAssertFalse(controller.dataLoadState.requiresVerification)
        XCTAssertNil(controller.dataVerificationChallengeDocument)
        XCTAssertNil(controller.dataVerificationWindow)
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

    func testVerifierExecutesOriginalChallengedHTMLWithoutUnauthenticatedRefetch() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        window.__fixtureChallengeBody='<html><head></head><body id="cf-challenge-running"><script>window.originalChallengeExecuted=true;<\\/script>Original challenge fixture</body></html>';
        document.querySelector('textarea').value='保留原网页草稿';
        window.__fixtureStatus=403;window.__fixtureChallenge=true;
        fetch('/backend-api/models?fixture=original').then(response=>response.text()).then(body=>{window.originalResponseReadable=body.includes('Original challenge fixture');});'requested';
        """, in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        waitUntil { !child.webView.isLoading }
        guard controller.dataVerificationWindow === child else {
            return XCTFail("A new unauthenticated request closed the verifier before the original challenge ran")
        }
        XCTAssertEqual(try evaluate("window.originalChallengeExecuted === true", in: child) as? Bool, true)
        XCTAssertEqual(try evaluate("location.origin + location.pathname + location.search", in: child) as? String,
                       "https://chatgpt.com/backend-api/models?fixture=original")
        XCTAssertEqual(try evaluate("typeof window.__chatgptSwiftDataLoadMonitor", in: child) as? String, "undefined")
        XCTAssertEqual(try evaluate("window.originalResponseReadable", in: controller) as? Bool, true)
        XCTAssertEqual(try evaluate("document.querySelector('textarea').value", in: controller) as? String, "保留原网页草稿")
        XCTAssertFalse(controller.diagnosticsReport().contains("Original challenge fixture"))
    }

    func testUnchallenged401CannotClaimVerificationFinishedOrDisplayAuthenticationJSON() throws {
        let controller = makeController()
        defer { controller.dispose() }
        settle()
        controller.dataLoadState.requiresVerification = true
        controller.openDataVerificationWindow()
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        child.webView.stopLoading()
        var completed = false
        child.dataVerificationCompleted = { completed = true }
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(child.dataVerificationURL), statusCode: 401,
                                                   httpVersion: nil, headerFields: ["Content-Type":"application/json"]))
        XCTAssertFalse(child.dataVerificationChallengeSeen)
        XCTAssertEqual(child.dataVerificationResponsePolicy(response), .cancel)
        settle()
        XCTAssertFalse(completed)
        XCTAssertTrue(controller.dataLoadState.requiresVerification)
    }

    func testOriginalChallengeRetainsItsContentSecurityPolicy() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        window.__fixtureChallengeCSP="default-src 'none'; script-src 'nonce-fixture'";
        window.__fixtureChallengeBody='<html><head></head><body id="cf-challenge-running"><script nonce="fixture">window.allowedChallengeScript=true;<\\/script><script>window.disallowedChallengeScript=true;<\\/script>Challenge CSP fixture</body></html>';
        window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested';
        """, in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        waitUntil { !child.webView.isLoading }
        XCTAssertEqual(try evaluate("window.allowedChallengeScript === true", in: child) as? Bool, true)
        XCTAssertEqual(try evaluate("window.disallowedChallengeScript === true", in: child) as? Bool, false)
    }

    func testOriginalXHRChallengeExecutesWithoutIssuingAnotherAPIRequest() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        const xhr=new XMLHttpRequest();
        xhr.open('GET','/backend-api/accounts/check/v4-fixture');
        xhr.send();
        xhr.status=403;xhr.header='challenge';
        xhr.responseText='<html><head></head><body id="cf-challenge-running"><script>window.originalXHRChallengeExecuted=true;<\\/script>XHR challenge fixture</body></html>';
        xhr.dispatchEvent(new Event('load'));'requested';
        """, in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        waitUntil { !child.webView.isLoading }
        XCTAssertEqual(try evaluate("window.originalXHRChallengeExecuted === true", in: child) as? Bool, true)
        XCTAssertEqual(child.webView.url?.path, "/backend-api/accounts/check/v4-fixture")
    }

    func testChallengeDocumentRejectsForeignOriginJSONAndOversizedBodies() throws {
        let headers = ["content-type":"text/html; charset=UTF-8", "cf-mitigated":"challenge",
                       "content-security-policy":"default-src 'self'; script-src 'nonce-fixture'"]
        let payload: [String: Any] = ["url":"https://chatgpt.com/backend-api/models?fixture=original",
                                      "status":403, "headers":headers, "html":"<html>fixture challenge</html>"]
        let document = try XCTUnwrap(BrowserDataChallengeDocument(payload: payload, pageURL: page, path: "/backend-api/models"))
        XCTAssertEqual(document.response.value(forHTTPHeaderField: "Content-Security-Policy"), headers["content-security-policy"])
        for (key, value) in [("url", "https://example.com/backend-api/models" as Any),
                             ("url", "https://chatgpt.com/backend-api/me" as Any),
                             ("status", 200 as Any),
                             ("html", String(repeating: "界", count: BrowserDataChallengeDocument.maximumBytes / 2) as Any),
                             ("headers", ["content-type":"application/json", "cf-mitigated":"challenge"] as Any),
                             ("headers", ["content-type":"text/html"] as Any),
                             ("headers", headers.merging(["set-cookie":"fixture=private"]) { _, new in new } as Any)] {
            var invalid = payload
            invalid[key] = value
            XCTAssertNil(BrowserDataChallengeDocument(payload: invalid, pageURL: page, path: "/backend-api/models"))
        }
    }

    func testOrdinaryAuthenticationResponseIsNeverClonedForVerification() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        window.fixtureCloneCount=0;
        const originalClone=Response.prototype.clone;
        Response.prototype.clone=function(){window.fixtureCloneCount++;return originalClone.call(this);};
        fetch('/api/auth/session');'requested';
        """, in: controller)
        waitUntil { controller.dataLoadState.responseStatus["/api/auth/session"] == 200 }
        XCTAssertEqual(try evaluate("window.fixtureCloneCount", in: controller) as? Int, 0)
        XCTAssertNil(controller.dataVerificationWindow)
    }

    func testLateChallengeBodyCannotOverrideNewerSuccessfulResponse() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        (()=>{
          const stream=new ReadableStream({start(reader){window.fixtureChallengeWriter=reader;}});
          window.__fixtureResponse=new Response(stream,{status:403,headers:{'cf-mitigated':'challenge','content-type':'text/html'}});
          fetch('/backend-api/models');
          window.__fixtureResponse=null;
          fetch('/backend-api/models');
          setTimeout(()=>{fixtureChallengeWriter.enqueue(new TextEncoder().encode(window.__fixtureChallengeBody));fixtureChallengeWriter.close();},100);
          return 'requested';
        })()
        """, in: controller)
        waitUntil { controller.dataLoadState.responseStatus["/backend-api/models"] == 200 }
        settle()
        XCTAssertFalse(controller.dataLoadState.requiresVerification)
        XCTAssertNil(controller.dataVerificationWindow)
    }

    func testOlderRequestChallengeArrivingAfterNewerSuccessCannotReopenVerification() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        window.__fixtureResponse=new Promise(resolve=>{window.fixtureResolveOlderRequest=resolve;});
        fetch('/backend-api/models?fixture=request-order');
        window.__fixtureResponse=null;
        fetch('/backend-api/models?fixture=request-order');'requested';
        """, in: controller)
        waitUntil { controller.dataLoadState.responseStatus["/backend-api/models"] == 200 }
        try evaluate("""
        fixtureResolveOlderRequest(new Response(window.__fixtureChallengeBody,{
          status:403,headers:{'cf-mitigated':'challenge','content-type':'text/html'}
        }));'resolved';
        """, in: controller)
        settle()
        XCTAssertEqual(controller.dataLoadState.responseStatus["/backend-api/models"], 200)
        XCTAssertFalse(controller.dataLoadState.requiresVerification)
        XCTAssertNil(controller.dataVerificationChallengeDocument)
        XCTAssertNil(controller.dataVerificationWindow)
    }

    func testRecoveryContinuesToNextEndpointOnlyAfterAuthenticatedProgress() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let first = try XCTUnwrap(controller.dataVerificationWindow)
        let delegate = RecoveryReloadDelegate(controller: controller, html: html)
        controller.webView.navigationDelegate = delegate
        let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(first.dataVerificationURL), statusCode: 401,
                                                   httpVersion: nil, headerFields: ["Content-Type":"application/json"]))
        XCTAssertEqual(first.dataVerificationResponsePolicy(response), .cancel)
        waitUntil { delegate.reloads == 1 && !controller.webView.isLoading }
        XCTAssertNil(controller.dataVerificationWindow)
        try evaluate("""
        window.__fixtureStatus=200;window.__fixtureChallenge=false;fetch('/backend-api/models');
        window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/accounts/check/v4-fixture');'requested';
        """, in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let second = try XCTUnwrap(controller.dataVerificationWindow)
        XCTAssertFalse(second === first)
        XCTAssertEqual(second.dataVerificationTargetPath, "/backend-api/accounts/check/v4-fixture")
        XCTAssertEqual(controller.dataVerificationAttemptedPaths.count, 2)
        controller.dismissDataVerification()
        try evaluate("window.__fixtureStatus=200;window.__fixtureChallenge=false;fetch('/backend-api/accounts/check/v4-fixture');'requested'", in: controller)
        waitUntil { !controller.dataLoadState.hasFailure }
        XCTAssertFalse(controller.dataVerificationAutomaticAttempted)
        XCTAssertTrue(controller.dataVerificationAttemptedPaths.isEmpty)
    }

    func testAnotherEndpointCannotReopenVerificationWithoutProgress() throws {
        let controller = makeController()
        defer { controller.dispose() }
        settle()
        controller.dataVerificationAutomaticAttempted = true
        controller.dataVerificationAttemptedPaths = ["/backend-api/models"]
        controller.dataVerificationCompletedPath = "/backend-api/models"
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');fetch('/backend-api/accounts/check/v4-fixture');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        settle()
        XCTAssertNil(controller.dataVerificationWindow)
        XCTAssertTrue(controller.dataVerificationAutomaticAttempted)
    }

    func testRecoveryContinuesToFourthDistinctEndpointAfterAuthenticatedProgress() throws {
        let controller = makeController()
        defer { controller.dispose() }
        settle()
        controller.dataVerificationAutomaticAttempted = true
        controller.dataVerificationAttemptedPaths = ["/backend-api/models", "/backend-api/me", "/backend-api/gizmos/snorlax/sidebar"]
        controller.dataVerificationCompletedPath = "/backend-api/models"
        try evaluate("""
        window.__fixtureStatus=200;window.__fixtureChallenge=false;fetch('/backend-api/models');
        window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/accounts/check/v4-fixture');'requested';
        """, in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        XCTAssertEqual(controller.dataVerificationWindow?.dataVerificationTargetPath, "/backend-api/accounts/check/v4-fixture")
        XCTAssertEqual(controller.dataVerificationAttemptedPaths.count, 4)
    }

    func testAttemptedPriorityEndpointCannotStarveUnattemptedChallenge() throws {
        let controller = makeController()
        defer { controller.dispose() }
        settle()
        controller.dataVerificationAutomaticAttempted = true
        controller.dataVerificationAttemptedPaths = ["/backend-api/models", "/backend-api/accounts/check/v4-fixture"]
        controller.dataVerificationCompletedPath = "/backend-api/models"
        try evaluate("""
        window.__fixtureStatus=200;window.__fixtureChallenge=false;fetch('/backend-api/models');
        window.__fixtureStatus=403;window.__fixtureChallenge=true;
        fetch('/backend-api/accounts/check/v4-fixture');fetch('/backend-api/conversations');'requested';
        """, in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        XCTAssertEqual(controller.dataVerificationWindow?.dataVerificationTargetPath, "/backend-api/conversations")
        XCTAssertEqual(controller.dataVerificationSource, "original-response")
        XCTAssertEqual(controller.dataVerificationAttemptedPaths.count, 3)
    }

    func testAccountVersionChangeDoesNotReopenAlreadyAttemptedEndpoint() throws {
        let controller = makeController()
        defer { controller.dispose() }
        settle()
        controller.dataVerificationAutomaticAttempted = true
        controller.dataVerificationAttemptedPaths = ["/backend-api/models", "/backend-api/accounts/check/v4-fixture"]
        controller.dataVerificationCompletedPath = "/backend-api/models"
        try evaluate("""
        window.__fixtureStatus=200;window.__fixtureChallenge=false;fetch('/backend-api/models');
        window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/accounts/check/v5-fixture');'requested';
        """, in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        settle()
        XCTAssertNil(controller.dataVerificationWindow)
        XCTAssertEqual(controller.dataVerificationAttemptedPaths.count, 2)
        XCTAssertTrue(controller.dataVerificationAutomaticAttempted)
    }

    func testVerifier200CannotRearmWhenOriginalAuthenticatedRequestStillReturns403() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/conversations?limit=20');'requested'", in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        let delegate = RecoveryReloadDelegate(controller: controller, html: html)
        controller.webView.navigationDelegate = delegate
        let responseURL = try XCTUnwrap(URL(string: "https://chatgpt.com/backend-api/conversations?limit=20&__cf_chl_tk=fixture"))
        let response = try XCTUnwrap(HTTPURLResponse(url: responseURL, statusCode: 200,
                                                   httpVersion: nil, headerFields: ["Content-Type":"application/json"]))
        XCTAssertEqual(child.dataVerificationResponsePolicy(response), .cancel)
        waitUntil { delegate.reloads == 1 && !controller.webView.isLoading }
        XCTAssertEqual(controller.dataVerificationLastResponseStatus["/backend-api/conversations"], 200)
        try evaluate("""
        window.__fixtureStatus=403;window.__fixtureChallenge=true;
        fetch('/backend-api/conversations?limit=20');fetch('/backend-api/models');'requested';
        """, in: controller)
        waitUntil { controller.dataLoadState.responseStatus["/backend-api/conversations"] == 403 }
        settle()
        XCTAssertNil(controller.dataVerificationWindow)
        XCTAssertEqual(controller.dataVerificationAttemptedPaths, ["/backend-api/conversations"])
        XCTAssertTrue(controller.dataVerificationAutomaticAttempted)
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
            (verification, 200, ["Content-Type":"text/html"]),
            (URL(string: "https://example.com/backend-api/models")!, 200, ["Content-Type":"application/json"])
        ] {
            controller.noteDataVerificationResponse(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
            XCTAssertFalse(controller.finishDataVerificationIfReady())
        }
        XCTAssertEqual(completions, 0)
        controller.noteDataVerificationResponse(try XCTUnwrap(HTTPURLResponse(url: verification, statusCode: 401, httpVersion: nil, headerFields: ["Content-Type":"application/json"])))
        XCTAssertTrue(controller.finishDataVerificationIfReady())
        XCTAssertEqual(completions, 1)
        controller.dataVerificationCompleted = { completions += 1 }
        controller.noteDataVerificationResponse(try XCTUnwrap(HTTPURLResponse(url: verification, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])))
        XCTAssertTrue(controller.finishDataVerificationIfReady())
        XCTAssertFalse(controller.finishDataVerificationIfReady())
        XCTAssertEqual(completions, 2)
    }

    func testAutomaticVerificationReloadsOriginalPageAndRestoresDraftWithoutAnyAppClick() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("document.querySelector('textarea').value='保留的未发送草稿';window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        XCTAssertTrue(child.webView.configuration.websiteDataStore === controller.webView.configuration.websiteDataStore)
        XCTAssertEqual(controller.webView.url, page)
        XCTAssertTrue(controller.dataVerificationWindow === child)

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

    func testChallengeDuringResponseAutomaticallyStartsWhenResponseFinishes() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("document.querySelector('main').insertAdjacentHTML('beforeend','<button data-testid=stop-button>停止</button>')", in: controller)
        waitUntil { controller.isAssistantResponseInProgress }
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        settle()
        XCTAssertNil(controller.dataVerificationWindow)
        XCTAssertTrue(controller.diagnosticsReport().contains("nativeStatusOverlay: verifying"))
        XCTAssertNil(BrowserStatusOverlayMode.verifying("等待回答结束").primaryButtonTitle)
        try evaluate("document.querySelector('[data-testid=stop-button]').remove()", in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        XCTAssertFalse(controller.isAssistantResponseInProgress)
    }

    func testVerificationSuccessDuringResponseAutomaticallyReloadsAfterCompletion() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("document.querySelector('textarea').value='回答期间保留的草稿';window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        try evaluate("window.webkit.messageHandlers.completionState.postMessage({busy:true,reason:'fixture'});'posted'", in: controller)
        waitUntil { controller.isAssistantResponseInProgress }
        let delegate = RecoveryReloadDelegate(controller: controller, html: html)
        controller.webView.navigationDelegate = delegate
        let url = try XCTUnwrap(child.dataVerificationURL)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"]))
        XCTAssertEqual(child.dataVerificationResponsePolicy(response), .cancel)
        waitUntil { controller.dataVerificationReloadURL == self.page && controller.dataVerificationWindow == nil }
        XCTAssertEqual(delegate.reloads, 0)
        XCTAssertFalse(controller.webView.isHidden)
        XCTAssertEqual(try evaluate("document.querySelector('textarea').value", in: controller) as? String, "回答期间保留的草稿")
        try evaluate("window.webkit.messageHandlers.completionState.postMessage({busy:false,reason:'fixture'});'posted'", in: controller)
        waitUntil { delegate.reloads == 1 && !controller.webView.isLoading && controller.dataRecoveryDraft == nil }
        XCTAssertNil(controller.dataVerificationReloadURL)
        XCTAssertTrue(controller.dataVerificationAutomaticAttempted)
        XCTAssertEqual(try evaluate("document.querySelector('textarea').value", in: controller) as? String, "回答期间保留的草稿")

        // The recovery reload must keep the automatic-attempt guard. If the page is
        // challenged again before a successful authenticated API response arrives,
        // it must stop at the in-page error state instead of opening another window.
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        settle()
        XCTAssertNil(controller.dataVerificationWindow)
    }

    func testSrcdocChallengeSubframeExecutesWithoutNativeRecoveryPrivileges() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("""
        (()=>{
          window.__srcdocRoundTrip='waiting';
          window.addEventListener('message',event=>{if(event.data==='srcdoc-ready')window.__srcdocRoundTrip=event.data;});
          const frame=document.createElement('iframe');
          frame.srcdoc='<script>window.webkit.messageHandlers.dataLoad.postMessage({path:parent.location.pathname,failures:{models:true},challenged:true,verificationPath:"/backend-api/models"});parent.postMessage("srcdoc-ready","*");<\\/script>';
          document.querySelector('main').append(frame);return true;
        })()
        """, in: controller)
        settle()
        XCTAssertEqual(try evaluate("window.__srcdocRoundTrip", in: controller) as? String, "srcdoc-ready")
        XCTAssertFalse(controller.dataLoadState.hasFailure)
        XCTAssertNil(controller.dataVerificationWindow)
        XCTAssertTrue(controller.diagnosticsReport().contains("blockedNavigationCount: 0"))
    }

    func testClosingParentDisposesInlineVerificationAndItsNativeHandler() throws {
        let controller = makeController()
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        let contentController = child.webView.configuration.userContentController
        controller.dispose()
        waitUntil { child.isDisposing && controller.dataVerificationWindow == nil }
        XCTAssertFalse(child.ownsDataVerificationMessageHandler)
        XCTAssertNil(child.webView.navigationDelegate)
        XCTAssertNil(child.dataVerificationCompleted)
        // Registering this name again would raise an exception if teardown left it installed.
        contentController.add(controller, name: "dataLoad")
        contentController.removeScriptMessageHandler(forName: "dataLoad")
    }

    func testReloadRetriesVisibleVerificationAndOriginalNavigationDismissesIt() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataVerificationWindow != nil }
        let child = try XCTUnwrap(controller.dataVerificationWindow)
        let verificationURL = try XCTUnwrap(child.dataVerificationURL)
        child.webView.stopLoading()
        let delegate = RecoveryReloadDelegate(controller: child, html: "<html><body id=cf-challenge-running>正在验证</body></html>")
        child.webView.navigationDelegate = delegate
        controller.reload(nil)
        waitUntil { delegate.reloads == 1 && !child.webView.isLoading }
        XCTAssertEqual(child.webView.url, verificationURL)
        XCTAssertEqual(controller.webView.url, page)
        let nextPage = URL(string: "https://chatgpt.com/c/another-fixture")!
        controller.webView.loadSimulatedRequest(URLRequest(url: nextPage), responseHTML: html)
        waitUntil { controller.webView.url == nextPage && !controller.webView.isLoading }
        XCTAssertNil(controller.dataVerificationWindow)
        XCTAssertNil(controller.dataVerificationReloadURL)
        XCTAssertTrue(child.isDisposing)
        XCTAssertFalse(controller.webView.isHidden)
    }

    func testActiveResponseCannotBeInterruptedAndClosingVerificationKeepsDraft() throws {
        let controller = makeController()
        defer { controller.dispose() }
        try evaluate("document.querySelector('textarea').value='仍在编辑';window.__fixtureStatus=403;window.__fixtureChallenge=true;fetch('/backend-api/models');'requested'", in: controller)
        waitUntil { controller.dataLoadState.requiresVerification }
        if let automaticWindow = controller.dataVerificationWindow {
            controller.dismissDataVerification()
            waitUntil { controller.dataVerificationWindow == nil }
            _ = automaticWindow
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
