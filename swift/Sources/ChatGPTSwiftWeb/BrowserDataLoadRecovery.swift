import AppKit
import Foundation
import WebKit

struct BrowserDataLoadState {
    var failures: [String] = []
    var requiresVerification = false
    var verificationPath = "/backend-api/models"
    var responseStatus: [String: Int] = [:]
    var hasFailure: Bool { requiresVerification || !failures.isEmpty }
    var summary: String { failures.isEmpty ? "ChatGPT 数据" : failures.joined(separator: "、") }
}

/// The actual challenged response, kept only in memory within its account's WebKit session.
/// Never transport request headers, cookies, or successful authentication response bodies.
struct BrowserDataChallengeDocument {
    static let maximumBytes = 131_072
    static let headerNames = ["date", "content-type", "cf-mitigated", "cf-ray", "content-security-policy",
                              "content-security-policy-report-only", "referrer-policy", "cross-origin-embedder-policy",
                              "cross-origin-opener-policy", "cross-origin-resource-policy", "origin-agent-cluster",
                              "x-content-type-options", "x-frame-options", "permissions-policy", "cache-control"]
    let response: HTTPURLResponse
    let data: Data

    init?(payload: [String: Any], pageURL: URL, path: String) {
        guard let rawURL = payload["url"] as? String, rawURL.utf8.count <= 4096,
              let url = URL(string: rawURL), url.scheme == "https", url.host == pageURL.host,
              (url.port ?? 443) == (pageURL.port ?? 443), url.user == nil, url.password == nil,
              url.fragment == nil, url.path == path, BrowserWindowController.isAllowedDataVerificationPath(path),
              payload["status"] as? Int == 403,
              let headers = payload["headers"] as? [String: String], headers.count <= Self.headerNames.count,
              headers.allSatisfy({ Self.headerNames.contains($0.key) && !$0.value.contains("\r") && !$0.value.contains("\n") }),
              headers.reduce(0, { $0 + $1.value.utf8.count }) <= 16_384,
              headers["cf-mitigated"]?.lowercased() == "challenge",
              headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "text/html",
              let html = payload["html"] as? String, !html.isEmpty, html.utf8.count <= Self.maximumBytes,
              let response = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: headers) else { return nil }
        self.response = response
        data = Data(html.utf8)
    }
}

extension BrowserWindowController {
    func handleDataLoadMessage(_ message: WKScriptMessage) {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              message.webView === webView, message.frameInfo.isMainFrame,
              Self.isTrustedChatGPTBridgeOrigin(message.frameInfo.securityOrigin),
              Self.canInjectPromptContent(into: webView.url),
              let payload = message.body as? [String: Any],
              payload["path"] as? String == webView.url?.path,
              let failures = payload["failures"] as? [String: Bool],
              let challenged = payload["challenged"] as? Bool else { return }
        if let path = payload["verificationPath"] as? String {
            guard Self.isAllowedDataVerificationPath(path) else { return }
            dataLoadState.verificationPath = path
        }
        if let statuses = payload["statuses"] as? [String: Int], statuses.count <= 16 {
            dataLoadState.responseStatus = statuses.filter { Self.isAllowedDataVerificationPath($0.key) && (100...599).contains($0.value) }
        }
        let paths = payload["challengedPaths"] as? [String] ?? [dataLoadState.verificationPath]
        guard paths.count <= 16, paths.allSatisfy(Self.isAllowedDataVerificationPath) else { return }
        if challenged, dataVerificationURL == nil {
            dataVerificationRecoveryPaths.formUnion(paths)
        }
        if dataVerificationURL == nil, let pageURL = webView.url {
            let documents = payload["challengeDocuments"] as? [String: [String: Any]] ?? [:]
            guard documents.count <= 8,
                  documents.keys.allSatisfy({ paths.contains($0) }),
                  Set(documents.keys.map(Self.dataVerificationEndpointKey)).count == documents.count else { return }
            let preferred = dataLoadState.verificationPath
            let orderedPaths = [preferred] + paths.filter { $0 != preferred }
            let candidates = orderedPaths.compactMap { path -> (String, BrowserDataChallengeDocument)? in
                guard let payload = documents[path],
                      let document = BrowserDataChallengeDocument(payload: payload, pageURL: pageURL, path: path) else { return nil }
                return (path, document)
            }
            // Select in native code so an already attempted priority endpoint cannot
            // hide a fresh challenge for another endpoint after real progress.
            let selected = dataVerificationWindow == nil
                ? candidates.first(where: { canAttemptDataVerification(path: $0.0) }) ?? candidates.first
                : candidates.first(where: { $0.0 == preferred })
            dataVerificationChallengeDocument = selected?.1
            if let selected {
                dataLoadState.verificationPath = selected.0
            }
        }
        updateDataLoadState(failures: failures, challenged: challenged)
    }

    func updateDataLoadState(failures: [String: Bool], challenged: Bool? = nil) {
        dataLoadState.failures = [("account", "账户"), ("models", "模型"), ("history", "历史记录"), ("projects", "项目")]
            .compactMap { failures[$0.0] == true ? $0.1 : nil }
        if let challenged { dataLoadState.requiresVerification = challenged }
        if failures["models"] == true, !modelLoadFailureActive {
            modelLoadFailureCount += 1
            modelLoadFailureLastAt = Date()
        }
        modelLoadFailureActive = failures["models"] == true
        // Different protected endpoints can remain challenged after one endpoint clears.
        // Continue only after real authenticated progress, once for each of the eight
        // monitored endpoint kinds. Account API versions share the same attempt.
        if challenged == true, dataVerificationWindow == nil,
           let completed = dataVerificationCompletedPath,
           (200..<300).contains(dataLoadState.responseStatus[completed] ?? 0),
           dataVerificationChallengeDocument != nil,
           canAttemptDataVerification(path: dataLoadState.verificationPath) {
            dataVerificationAutomaticAttempted = false
        }
        // Ending a challenge only permits an authenticated retry. Reset the whole
        // recovery cycle only when every challenged API actually recovers.
        if challenged == false, !dataLoadState.hasFailure, dataVerificationWindow == nil,
           !dataVerificationRecoveryPaths.isEmpty,
           dataVerificationRecoveryPaths.allSatisfy({ (200..<300).contains(dataLoadState.responseStatus[$0] ?? 0) }) {
            dataVerificationAutomaticAttempted = false
            dataVerificationRecoveryPaths.removeAll()
            dataVerificationAttemptedPaths.removeAll()
            dataVerificationCompletedPath = nil
        }
        if dataLoadState.requiresVerification, dataVerificationURL == nil {
            scheduleAutomaticDataVerification()
        }
        completeDataVerificationIfReady()
        if dataLoadState.hasFailure { refreshFeedback.dataLoadFailed() }
        updateDataLoadOverlay()
        updateNativeChromeStatus()
    }

    /// Keep verification in this window, with the original document and unsent input alive
    /// behind it. Repeated response reports share one verification document.
    func scheduleAutomaticDataVerification() {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              !dataVerificationAutomaticAttempted,
              !isAssistantResponseInProgress,
              !dataRecoveryCapturePending,
              dataVerificationURL == nil, dataVerificationWindow == nil,
              dataVerificationAutoOpenWorkItem == nil, dataVerificationReloadURL == nil,
              Self.canInjectPromptContent(into: webView.url) else { return }
        dataVerificationAutoOpenGeneration &+= 1
        let generation = dataVerificationAutoOpenGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDisposing,
                  self.dataVerificationAutoOpenGeneration == generation else { return }
            self.dataVerificationAutoOpenWorkItem = nil
            guard ProfileStore.pendingDataMutation == nil, !self.isAssistantResponseInProgress,
                  !self.dataRecoveryCapturePending, self.dataVerificationReloadURL == nil,
                  self.dataVerificationURL == nil, Self.canInjectPromptContent(into: self.webView.url),
                  self.dataLoadState.requiresVerification,
                  self.dataVerificationWindow == nil else { return }
            self.openDataVerificationWindow()
        }
        dataVerificationAutoOpenWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    func updateDataLoadOverlay() {
        if dataVerificationWindow != nil { hideDataLoadOverlay(); return }
        guard !isDisposing, !webView.isLoading, !hasFailedNavigation,
              !isCloudflareChallengeActive, Self.canInjectPromptContent(into: webView.url) else { return }
        if dataVerificationReloadURL != nil || (dataLoadState.requiresVerification && isAssistantResponseInProgress) {
            showDataLoadOverlay(.verifying("回答结束后将自动继续，当前输入会保留。"))
            return
        }
        if dataLoadState.requiresVerification && dataVerificationAutoOpenWorkItem != nil {
            showDataLoadOverlay(.verifying("正在打开安全验证，完成后自动继续。"))
            return
        }
        if dataLoadState.hasFailure {
            let detail = dataLoadState.requiresVerification
                ? (dataVerificationAutomaticAttempted
                    ? "验证后数据请求仍被拦截，已停止重复打开验证页。当前输入已保留，可稍后重试。"
                    : "安全验证拦截了数据请求。完成验证后会自动重新加载，保留当前输入。")
                : "\(dataLoadState.summary)未能加载。重新加载会保留当前输入。"
            showDataLoadOverlay(.dataLoadFailed(detail, verification: dataLoadState.requiresVerification))
        } else {
            hideDataLoadOverlay()
        }
    }

    func recoverDataLoad() {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              Self.canInjectPromptContent(into: webView.url) else { return }
        guard !isAssistantResponseInProgress else {
            if !dataLoadState.requiresVerification { dataVerificationReloadURL = webView.url }
            updateDataLoadOverlay()
            showToast("回答结束后会自动继续加载，当前输入会保留")
            return
        }
        if dataLoadState.requiresVerification {
            dataVerificationAutomaticAttempted = false
            dataVerificationAttemptedPaths.removeAll()
            dataVerificationCompletedPath = nil
            openDataVerificationWindow()
        } else { reloadDataPagePreservingDraft() }
    }

    func openDataVerificationWindow() {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil, dataVerificationURL == nil,
              !dataVerificationAutomaticAttempted,
              canAttemptDataVerification(path: dataLoadState.verificationPath),
              Self.canInjectPromptContent(into: webView.url) else { return }
        if dataVerificationWindow != nil { return }
        guard let original = webView.url,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false),
              Self.isAllowedDataVerificationPath(dataLoadState.verificationPath) else { return }
        // A top-level navigation can render the challenged endpoint's HTML. Verifying the
        // homepage alone does not establish clearance for a more restricted API endpoint.
        components.path = dataLoadState.verificationPath
        components.query = nil
        components.fragment = nil
        let document = dataVerificationChallengeDocument
        guard let verificationURL = document?.response.url ?? components.url else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        configuration.applicationNameForUserAgent = webView.configuration.applicationNameForUserAgent
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Keep the account's fingerprint/privacy shims. Only response metadata is bridged
        // from the verification document; drafts and downloads stay on the original page.
        let shims = webView.configuration.userContentController.userScripts.filter { !$0.isForMainFrameOnly }.map {
            WKUserScript(source: $0.source, injectionTime: $0.injectionTime, forMainFrameOnly: false)
        }
        shims.forEach { configuration.userContentController.addUserScript($0) }
        let child = BrowserWindowController(initialURL: nil, title: "完成 ChatGPT 安全验证", isPopup: true,
                                            persistent: persistent, profileID: profileID, configuration: configuration)
        child.webView.customUserAgent = webView.customUserAgent
        child.dataVerificationURL = verificationURL
        child.dataVerificationTargetPath = dataLoadState.verificationPath
        // A new unauthenticated navigation can return 401 without ever running the
        // original fetch challenge. Only an observed challenge counts as evidence.
        child.dataVerificationCompleted = { [weak self, weak child] in
            guard let self, let child, self.dataVerificationWindow === child else { return }
            self.dataVerificationLastResponseStatus = child.dataLoadState.responseStatus
            self.dataVerificationChallengeSeen = child.dataVerificationChallengeSeen
            self.dataVerificationCompletedPath = child.dataVerificationTargetPath
            self.dismissDataVerification()
            guard !self.isDisposing, self.webView.url == original,
                  ProfileStore.pendingDataMutation == nil else { return }
            self.dataLoadState.requiresVerification = false
            self.dataVerificationReloadURL = original
            self.resumeDataRecoveryWhenIdle()
        }
        dataVerificationWindow = child
        dataVerificationSource = document == nil ? "navigation-fallback" : "original-response"
        dataVerificationLastResponseStatus = [:]
        dataVerificationChallengeDocument = nil
        dataVerificationAutomaticAttempted = true
        dataVerificationAttemptedPaths.insert(dataLoadState.verificationPath)
        dataVerificationCompletedPath = nil
        dataVerificationRecoveryPaths.insert(dataLoadState.verificationPath)
        dataVerificationAutoOpenWorkItem = nil
        child.webView.configuration.userContentController.add(child, name: "dataLoad")
        child.ownsDataVerificationMessageHandler = true
        child.webView.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.dataLoadMonitorScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        presentDataVerification(child)
        let request = URLRequest(url: verificationURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        if let document {
            // Render the response already received by the authenticated page. This public
            // WebKit API retains its HTTPS origin and headers without issuing another GET.
            child.noteDataVerificationResponse(document.response)
            child.recordCloudflareChallengeResponse(document.response)
            child.beginCloudflareChallenge(reason: "原始数据请求的挑战页面")
            child.webView.loadSimulatedRequest(request, response: document.response, responseData: document.data)
        } else {
            child.webView.load(request)
        }
    }

    func resumeDataRecoveryWhenIdle() {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil else { return }
        if let pendingURL = dataVerificationReloadURL {
            guard webView.url == pendingURL else { dataVerificationReloadURL = nil; return }
            guard !isAssistantResponseInProgress else { updateDataLoadOverlay(); return }
            reloadDataPagePreservingDraft()
        } else if dataLoadState.requiresVerification {
            scheduleAutomaticDataVerification()
        }
    }

    func completeDataVerificationIfReady() {
        guard dataVerificationURL != nil,
              !isDisposing,
              !isCloudflareChallengeActive,
              !webView.isLoading,
              !dataLoadState.requiresVerification,
              let path = dataVerificationTargetPath,
              let status = dataLoadState.responseStatus[path],
              (200..<300).contains(status),
              let complete = dataVerificationCompleted else { return }
        dataVerificationCompleted = nil
        complete()
    }

    /// Inspect only metadata. A protected endpoint can return 401 after its challenge completes
    /// because this navigation carries cookies, without replaying the page's bearer headers.
    func noteDataVerificationResponse(_ response: HTTPURLResponse) {
        guard let target = dataVerificationURL, let url = response.url else { dataVerificationResponseReady = false; return }
        // Cloudflare can retain its short-lived query after the challenge. Match the
        // requested origin/path, while never forwarding or exposing that query.
        let matchesTarget = url.scheme == target.scheme && url.host == target.host
            && (url.port ?? 443) == (target.port ?? 443) && url.path == target.path
            && url.user == nil && url.password == nil
        if matchesTarget { dataLoadState.responseStatus[target.path] = response.statusCode }
        if matchesTarget, Self.isCloudflareChallengeResponse(response) {
            dataVerificationChallengeSeen = true
        }
        let isSuccessfulJSON = (200..<300).contains(response.statusCode)
            && response.mimeType?.lowercased() == "application/json"
        let isExpectedUnauthorized = response.statusCode == 401
            && (cloudflareChallengeCount > 0 || dataVerificationChallengeSeen)
        dataVerificationResponseReady = matchesTarget
            && (isSuccessfulJSON || isExpectedUnauthorized)
            && !Self.isCloudflareChallengeResponse(response)
    }

    func dataVerificationResponsePolicy(_ response: HTTPURLResponse) -> WKNavigationResponsePolicy? {
        noteDataVerificationResponse(response)
        guard dataVerificationResponseReady else {
            guard response.mimeType?.lowercased() == "application/json" else { return nil }
            if response.statusCode == 401 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let parent = self.dataVerificationParent,
                          parent.dataVerificationWindow === self else { return }
                    parent.dataVerificationLastResponseStatus = self.dataLoadState.responseStatus
                    parent.dataVerificationChallengeSeen = self.dataVerificationChallengeSeen
                    parent.dismissDataVerification()
                }
            }
            return .cancel
        }
        // Authentication JSON can contain session material. Finish from headers and cancel
        // this navigation before WebKit can render or download any response body.
        DispatchQueue.main.async { [weak self] in _ = self?.finishDataVerificationIfReady() }
        return .cancel
    }

    func finishDataVerificationIfReady() -> Bool {
        guard !isDisposing, dataVerificationResponseReady, let complete = dataVerificationCompleted else { return false }
        dataVerificationCompleted = nil
        complete()
        return true
    }

    static let dataVerificationPathPattern = #"^/(?:api/auth/session|backend-api/(?:models|me|conversations|accounts/check/v[0-9A-Za-z_-]+|gizmos/snorlax/sidebar|projects|flat_projects))$"#

    static func isAllowedDataVerificationPath(_ path: String) -> Bool {
        path.count <= 160 && path.range(of: dataVerificationPathPattern, options: .regularExpression) != nil
    }

    static func dataVerificationEndpointKey(_ path: String) -> String {
        path.hasPrefix("/backend-api/accounts/check/") ? "/backend-api/accounts/check" : path
    }

    func canAttemptDataVerification(path: String) -> Bool {
        Self.isAllowedDataVerificationPath(path) && !dataVerificationAttemptedPaths.contains {
            Self.dataVerificationEndpointKey($0) == Self.dataVerificationEndpointKey(path)
        }
    }

    func reloadDataPagePreservingDraft() {
        guard !isDisposing, !dataRecoveryCapturePending, !isAssistantResponseInProgress,
              let original = webView.url else { return }
        dataRecoveryCapturePending = true
        dataRecoveryCaptureGeneration += 1
        let generation = dataRecoveryCaptureGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            guard self.dataRecoveryCapturePending, self.dataRecoveryCaptureGeneration == generation else { return }
            self.dataRecoveryCapturePending = false
            self.dataRecoveryCaptureGeneration += 1
            self.showToast("暂时无法保存输入，当前页面已保留；稍后可再次重试")
        }
        capturePageState { [weak self] in
            guard let self, self.dataRecoveryCaptureGeneration == generation else { return }
            self.webView.evaluateJavaScript("""
            (() => {
              const saved=window.__chatgptSwiftDraftUI?.snapshot(); if(saved) return saved;
              const composer=document.querySelector('#prompt-textarea,textarea[data-testid="prompt-textarea"],[contenteditable="true"][data-testid="prompt-textarea"]');
              return {path:location.pathname,text:composer?.value ?? composer?.innerText ?? ''};
            })()
            """) { [weak self] value, error in
                guard let self, self.dataRecoveryCaptureGeneration == generation else { return }
                self.dataRecoveryCapturePending = false
                guard !self.isDisposing, self.webView.url == original,
                      ProfileStore.pendingDataMutation == nil else { return }
                guard !self.isAssistantResponseInProgress else {
                    self.dataVerificationReloadURL = original
                    self.updateDataLoadOverlay()
                    return
                }
                guard error == nil else {
                    self.showToast("暂时无法保存输入，当前页面已保留；稍后可再次重试")
                    return
                }
                guard let snapshot = value as? [String: Any], let text = snapshot["text"] as? String,
                      snapshot["path"] as? String == original.path, text.count <= 200_000 else {
                    self.showToast("无法完整保存输入，当前页面已保留")
                    return
                }
                guard self.refreshFeedback.beginRefresh() else { return }
                if !text.isEmpty { self.dataRecoveryDraft = (original, text) }
                self.refreshFeedback.trackRequestedNavigation(self.hardReload(ignoringCache: true))
            }
        }
    }

    func restoreDataRecoveryDraft(attempt: Int = 0) {
        guard let draft = dataRecoveryDraft, !isDisposing else { return }
        guard webView.url == draft.url else { dataRecoveryDraft = nil; return }
        webView.evaluateJavaScript(Self.restorePromptDraftScript(text: draft.text)) { [weak self] value, _ in
            guard let self, !self.isDisposing, self.webView.url == draft.url,
                  self.dataRecoveryDraft?.url == draft.url, self.dataRecoveryDraft?.text == draft.text else { return }
            let report = value as? [String: Any]
            if report?["restored"] as? Bool == true || report?["reason"] as? String == "composer not empty" {
                self.dataRecoveryDraft = nil
            } else if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restoreDataRecoveryDraft(attempt: attempt + 1) }
            } else {
                // Keep this input in memory and offer an explicit retry if the composer is still absent.
                self.showToast("输入已保留，输入框就绪后可恢复", actionTitle: "恢复输入", action: { [weak self] in self?.restoreDataRecoveryDraft() }, duration: 20)
            }
        }
    }

    /// Only visible UI errors count. Chat messages, scripts, hidden menu items and editable
    /// content cannot masquerade as a failed service merely by quoting an error string.
    static let dataLoadFailureProbeScript = #"""
    (() => {
      const failures = {models:false,history:false,account:false,projects:false};
      const phrases = {
        models:['无法加载 chatgpt 模型','无法加载模型','failed to load model','unable to load model','unable to load chatgpt model'],
        history:['无法加载历史记录','unable to load history','failed to load history','unable to load chat history'],
        account:['无法加载你的账户','无法加载您的账户','unable to load your account','failed to load your account'],
        projects:['无法加载项目','unable to load projects','failed to load projects']
      };
      if (!document.body) return failures;
      const excluded = 'script,style,textarea,input,[contenteditable="true"],article,[data-message-author-role],[data-testid^="conversation-turn"],[hidden],[inert],[aria-hidden="true"]';
      const walker = document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,{
        acceptNode:node => node instanceof Element ? (node.matches(excluded)?NodeFilter.FILTER_REJECT:NodeFilter.FILTER_SKIP) : NodeFilter.FILTER_ACCEPT
      });
      for(let node=walker.nextNode();node;node=walker.nextNode()) {
        const text=String(node.nodeValue || '').replace(/\s+/g,' ').trim().toLowerCase().slice(0,180);
        if(!text) continue;
        const matched=Object.keys(phrases).filter(key=>phrases[key].some(phrase=>text.includes(phrase)));
        if(!matched.length) continue;
        const element=node.parentElement,rect=element.getBoundingClientRect();
        if(rect.width<1 || rect.height<1 || getComputedStyle(element).visibility==='hidden') continue;
        matched.forEach(key=>{failures[key]=true;});
      }
      return failures;
    })()
    """#

    static let dataLoadMonitorScript = """
    (() => {
      const host=location.hostname.toLowerCase();
      if(window!==window.top || location.protocol!=='https:' || (location.port && location.port!=='443') ||
         !['chatgpt.com','chat.openai.com'].includes(host) || window.__chatgptSwiftDataLoadMonitor) return;
      const readFailures=()=>\(dataLoadFailureProbeScript);
      const allowedPath=new RegExp('\(dataVerificationPathPattern)');
      // Verification API documents must run the site's original browser code untouched.
      if(allowedPath.test(location.pathname)) return;
      const blocked=()=>location.pathname.startsWith('/cdn-cgi/') || !!document.querySelector('iframe[src*="challenges.cloudflare.com"],.cf-turnstile,#cf-challenge-running,#challenge-stage,[data-cf-challenge]');
      const challenges=new Set(),statuses={},documents=new Map(),pending=new Map(),revisions=new Map();let timer=0,last='',disposed=false,observer;
      const endpointKey=path=>path.startsWith('/backend-api/accounts/check/')?'/backend-api/accounts/check':path;
      const maximumBytes=\(BrowserDataChallengeDocument.maximumBytes);
      const headerNames=['\(BrowserDataChallengeDocument.headerNames.joined(separator: "','"))'];
      const report=()=>{
        timer=0;if(disposed || blocked() || pending.size) return;
        const paths=[...challenges];
        const verificationPath=paths.find(path=>path==='/api/auth/session') || paths.find(path=>path.startsWith('/backend-api/accounts/check/')) || paths[0] || '/backend-api/models';
        const challengeDocuments={},families=new Set();
        for(const path of [verificationPath,...paths]){
          const key=endpointKey(path);if(!families.has(key) && documents.has(path) && families.size<8){families.add(key);challengeDocuments[path]=documents.get(path);}
        }
        const payload={path:location.pathname,failures:readFailures(),challenged:challenges.size>0,challengedPaths:paths,verificationPath,statuses,challengeDocuments};
        const key=JSON.stringify(payload);if(key===last) return;last=key;
        try{window.webkit.messageHandlers.dataLoad.postMessage(payload);}catch(_){}
      };
      const schedule=()=>{if(!timer && !disposed) timer=setTimeout(report,200);};
      const responsePath=(raw,method)=>{
        try{const url=new URL(raw,location.href);return String(method||'GET').toUpperCase()==='GET' &&
          url.origin===location.origin && allowedPath.test(url.pathname) ? url.pathname : null;}catch(_){return null;}
      };
      const beginRequest=path=>{
        if(!path || disposed)return;
        const revision=(revisions.get(path)||0)+1;revisions.set(path,revision);
        return revision;
      };
      const observeResponse=(path,revision,status,header)=>{
        if(!path || disposed || revisions.get(path)!==revision) return false;
        documents.delete(path);pending.delete(path);
        if(Object.keys(statuses).length<16 || path in statuses) statuses[path]=status;
        if(String(header||'').toLowerCase()==='challenge') challenges.add(path);
        else if(status>=200 && status<300) challenges.delete(path);
        schedule();
        return true;
      };
      const challengeDocument=(url,status,getHeader,html)=>({url,status,html,headers:Object.fromEntries(headerNames.map(name=>[name,getHeader(name)]).filter(([,value])=>value))});
      const readChallengeHTML=async response=>{
        if(!response.body || Number(response.headers.get('content-length'))>maximumBytes) return;
        const reader=response.body.getReader(),decoder=new TextDecoder();let timer,bytes=0,text='';
        const read=async()=>{
          for(;;){const {done,value}=await reader.read();if(done)return text+decoder.decode();
            bytes+=value.byteLength;if(bytes>maximumBytes)return;text+=decoder.decode(value,{stream:true});}
        };
        try{return await Promise.race([read(),new Promise(resolve=>{timer=setTimeout(()=>resolve(undefined),2000);})]);}
        finally{clearTimeout(timer);reader.cancel().catch(()=>{});}
      };
      const originalFetch=window.fetch;
      const monitoredFetch=function(...args){
        const promise=Reflect.apply(originalFetch,this,args);
        try{
          const request=args[0],raw=typeof request==='string' || request instanceof URL?String(request):request.url,path=responsePath(raw,args[1]?.method || request?.method),revision=beginRequest(path);
          if(path) promise.then(async response=>{
            const header=response.headers.get('cf-mitigated');
            if(!observeResponse(path,revision,response.status,header))return;
            if(disposed || response.status!==403 || String(header).toLowerCase()!=='challenge' || !/^text\\/html(?:;|$)/i.test(response.headers.get('content-type')||''))return;
            pending.set(path,revision);
            try{const html=await readChallengeHTML(response.clone());
              if(!disposed && revisions.get(path)===revision && html)documents.set(path,challengeDocument(response.url||new URL(raw,location.href).href,response.status,name=>response.headers.get(name),html));}
            finally{if(pending.get(path)===revision)pending.delete(path);schedule();}
          }).catch(()=>{});
        }catch(_){}
        return promise;
      };
      window.fetch=monitoredFetch;
      const originalOpen=XMLHttpRequest.prototype.open;
      const originalSend=XMLHttpRequest.prototype.send;
      const xhrPaths=new WeakMap();
      const monitoredOpen=function(method,url,...rest){
        const result=Reflect.apply(originalOpen,this,[method,url,...rest]);
        const path=responsePath(url,method);
        if(!xhrPaths.has(this)) this.addEventListener('load',()=>{
          const entry=xhrPaths.get(this);if(!entry)return;
          const header=this.getResponseHeader('cf-mitigated');
          if(!observeResponse(entry.path,entry.revision,this.status,header))return;
          if(!disposed && this.status===403 && String(header).toLowerCase()==='challenge' && /^text\\/html(?:;|$)/i.test(this.getResponseHeader('content-type')||'') && ['', 'text'].includes(this.responseType||'')){
            const html=this.responseText;
            if(html && new TextEncoder().encode(html).byteLength<=maximumBytes)documents.set(entry.path,challengeDocument(this.responseURL||entry.url,this.status,name=>this.getResponseHeader(name),html));
          }
        });
        xhrPaths.set(this,path?{path,url:new URL(url,location.href).href}:null);
        return result;
      };
      const monitoredSend=function(...args){
        const entry=xhrPaths.get(this);if(entry)entry.revision=beginRequest(entry.path);
        return Reflect.apply(originalSend,this,args);
      };
      XMLHttpRequest.prototype.open=monitoredOpen;
      XMLHttpRequest.prototype.send=monitoredSend;
      const boot=()=>{
        if(disposed || blocked()) return;
        observer=new MutationObserver(mutations=>{
          for(const mutation of mutations){
            const element=mutation.target instanceof Element?mutation.target:mutation.target.parentElement;
            if(!element?.closest('article,[data-message-author-role],[data-testid^="conversation-turn"],#prompt-textarea,script,style')){schedule();return;}
          }
        });
        observer.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['hidden','aria-hidden','style','class']});
        schedule();
      };
      const dispose=()=>{disposed=true;clearTimeout(timer);observer?.disconnect();if(window.fetch===monitoredFetch)window.fetch=originalFetch;if(XMLHttpRequest.prototype.open===monitoredOpen)XMLHttpRequest.prototype.open=originalOpen;if(XMLHttpRequest.prototype.send===monitoredSend)XMLHttpRequest.prototype.send=originalSend;};
      window.__chatgptSwiftDataLoadMonitor={probe:readFailures,dispose};
      window.addEventListener('pagehide',dispose,{once:true});
      if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
    })()
    """
}
