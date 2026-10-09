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
        if dataLoadState.requiresVerification {
            scheduleAutomaticDataVerification()
        }
        if dataLoadState.hasFailure { refreshFeedback.dataLoadFailed() }
        updateDataLoadOverlay()
        updateNativeChromeStatus()
    }

    /// Cloudflare challenge responses are already a browser-verification event. Open the
    /// same-account WebKit window immediately; the toolbar/button remains only as a fallback
    /// after the automatic window is closed or if the first open is interrupted.
    func scheduleAutomaticDataVerification() {
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              !isAssistantResponseInProgress,
              Self.canInjectPromptContent(into: webView.url), dataVerificationWindow == nil else { return }
        dataVerificationAutoOpenGeneration &+= 1
        let generation = dataVerificationAutoOpenGeneration
        dataVerificationAutoOpenWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDisposing,
                  self.dataVerificationAutoOpenGeneration == generation,
                  self.dataLoadState.requiresVerification,
                  self.dataVerificationWindow == nil else { return }
            self.dataVerificationAutoOpenWorkItem = nil
            self.openDataVerificationWindow()
        }
        dataVerificationAutoOpenWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    func updateDataLoadOverlay() {
        guard !isDisposing, !webView.isLoading, !hasFailedNavigation,
              !isCloudflareChallengeActive, Self.canInjectPromptContent(into: webView.url) else { return }
        if dataLoadState.hasFailure {
            let detail = dataLoadState.requiresVerification
                ? "安全验证拦截了数据请求。完成验证后会自动重新加载，保留当前输入。"
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
            showToast("回答完成后可重试加载；当前回答会继续")
            return
        }
        if dataLoadState.requiresVerification { openDataVerificationWindow() }
        else { reloadDataPagePreservingDraft() }
    }

    func openDataVerificationWindow() {
        if let existing = dataVerificationWindow, !existing.isDisposing { existing.show(); return }
        guard let original = webView.url,
              var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return }
        guard Self.isAllowedDataVerificationPath(dataLoadState.verificationPath) else { return }
        components.path = dataLoadState.verificationPath
        components.query = nil
        components.fragment = nil
        guard let verificationURL = components.url else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        configuration.applicationNameForUserAgent = webView.configuration.applicationNameForUserAgent
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Keep the account's fingerprint/privacy shims, without granting this verification
        // window any of the original page's native data bridges.
        let shims = webView.configuration.userContentController.userScripts.filter { !$0.isForMainFrameOnly }.map {
            WKUserScript(source: $0.source, injectionTime: $0.injectionTime, forMainFrameOnly: false)
        }
        shims.forEach { configuration.userContentController.addUserScript($0) }
        let child = BrowserWindowController(initialURL: nil, title: "完成 ChatGPT 安全验证", isPopup: true,
                                            persistent: persistent, profileID: profileID, configuration: configuration,
                                            closeHandler: { [weak self] in self?.dataVerificationWindow = nil })
        child.webView.customUserAgent = webView.customUserAgent
        child.dataVerificationURL = verificationURL
        child.dataVerificationCompleted = { [weak self, weak child] in
            child?.dispose()
            self?.dataVerificationWindow = nil
            guard let self, !self.isDisposing, self.webView.url == original,
                  ProfileStore.pendingDataMutation == nil else { return }
            guard !self.isAssistantResponseInProgress else {
                self.showToast("安全验证已完成；回答结束后可点击重新加载")
                self.dataLoadState.requiresVerification = false
                self.updateDataLoadOverlay()
                return
            }
            self.dataLoadState.requiresVerification = false
            self.reloadDataPagePreservingDraft()
        }
        dataVerificationWindow = child
        dataVerificationAutoOpenWorkItem = nil
        child.webView.load(URLRequest(url: verificationURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        child.show()
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
        dataVerificationResponseReady = matchesTarget
            && (response.statusCode == 200 || (response.statusCode == 401 && cloudflareChallengeCount > 0))
            && response.mimeType?.lowercased() == "application/json"
            && !Self.isCloudflareChallengeResponse(response)
    }

    func dataVerificationResponsePolicy(_ response: HTTPURLResponse) -> WKNavigationResponsePolicy? {
        noteDataVerificationResponse(response)
        guard dataVerificationResponseReady else { return nil }
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
                      !self.isAssistantResponseInProgress, ProfileStore.pendingDataMutation == nil else { return }
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
      const blocked=()=>location.pathname.startsWith('/cdn-cgi/') || !!document.querySelector('iframe[src*="challenges.cloudflare.com"],.cf-turnstile,#cf-challenge-running,#challenge-stage,[data-cf-challenge]');
      const challenges=new Set(),statuses={};let timer=0,last='',disposed=false,observer;
      const report=()=>{
        timer=0;if(disposed || blocked()) return;
        const paths=[...challenges];
        const verificationPath=paths.find(path=>path==='/api/auth/session') || paths.find(path=>path.startsWith('/backend-api/accounts/check/')) || paths[0] || '/backend-api/models';
        const payload={path:location.pathname,failures:readFailures(),challenged:challenges.size>0,verificationPath,statuses};
        const key=JSON.stringify(payload);if(key===last) return;last=key;
        try{window.webkit.messageHandlers.dataLoad.postMessage(payload);}catch(_){}
      };
      const schedule=()=>{if(!timer && !disposed) timer=setTimeout(report,200);};
      const responsePath=(raw,method)=>{
        try{const url=new URL(raw,location.href);return String(method||'GET').toUpperCase()==='GET' &&
          url.origin===location.origin && allowedPath.test(url.pathname) ? url.pathname : null;}catch(_){return null;}
      };
      const observeResponse=(path,status,header)=>{
        if(!path || disposed) return;
        if(Object.keys(statuses).length<16 || path in statuses) statuses[path]=status;
        if(String(header||'').toLowerCase()==='challenge') challenges.add(path);
        else if(status>=200 && status<300) challenges.delete(path);
        schedule();
      };
      const originalFetch=window.fetch;
      const monitoredFetch=function(...args){
        const promise=Reflect.apply(originalFetch,this,args);
        try{
          const request=args[0],path=responsePath(typeof request==='string' || request instanceof URL?String(request):request.url,args[1]?.method || request?.method);
          if(path) promise.then(response=>observeResponse(path,response.status,response.headers.get('cf-mitigated'))).catch(()=>{});
        }catch(_){}
        return promise;
      };
      window.fetch=monitoredFetch;
      const originalOpen=XMLHttpRequest.prototype.open;
      const xhrPaths=new WeakMap();
      const monitoredOpen=function(method,url,...rest){
        const result=Reflect.apply(originalOpen,this,[method,url,...rest]);
        const path=responsePath(url,method);
        if(!xhrPaths.has(this)) this.addEventListener('load',()=>observeResponse(xhrPaths.get(this),this.status,this.getResponseHeader('cf-mitigated')));
        xhrPaths.set(this,path);
        return result;
      };
      XMLHttpRequest.prototype.open=monitoredOpen;
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
      const dispose=()=>{disposed=true;clearTimeout(timer);observer?.disconnect();if(window.fetch===monitoredFetch)window.fetch=originalFetch;if(XMLHttpRequest.prototype.open===monitoredOpen)XMLHttpRequest.prototype.open=originalOpen;};
      window.__chatgptSwiftDataLoadMonitor={probe:readFailures,dispose};
      window.addEventListener('pagehide',dispose,{once:true});
      if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot,{once:true});else boot();
    })()
    """
}
