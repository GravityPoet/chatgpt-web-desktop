import AppKit
import ChatGPTSwiftWebCore
import WebKit

extension BrowserWindowController {
    func refreshDraftDiagnostics() {
        guard !isDisposing, Self.canInjectPromptContent(into: webView.url) else { return }
        // Inspect capture availability only; never include the draft or other page content.
        webView.evaluateJavaScript(#"""
        (() => ({
          installed: !!window.__chatgptSwiftPromptDraftBridgeInstalled,
          bridge: !!window.webkit?.messageHandlers?.promptDraft,
          knownComposer: !!document.querySelector('#prompt-textarea,textarea[data-testid="prompt-textarea"],[contenteditable="true"][data-testid="prompt-textarea"]'),
          editableTextbox: !!document.querySelector('[role="textbox"][contenteditable="true"]'),
          textarea: !!document.querySelector('textarea'),
          ...window.__chatgptSwiftDraftUI?.diagnostics()
        }))()
        """#) { [weak self] result, error in
            guard let self, !self.isDisposing else { return }
            guard error == nil, let values = result as? [String: Bool] else {
                self.draftCaptureDiagnostics = "页面捕获状态不可用"
                return
            }
            self.draftCaptureDiagnostics = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: ", ")
        }
    }

    func draftKey(for path: String) -> String { (isQuickWindow ? "quick:" : "") + path }

    nonisolated static func validDraftPath(_ path: String) -> Bool {
        path.count <= 512 && path.hasPrefix("/") && !path.hasPrefix("//") &&
        path.range(of: #"^/[A-Za-z0-9_/-]*$"#, options: .regularExpression) != nil
    }

    func configureDraftExperience() {
        guard !isDisposing, Self.canInjectPromptContent(into: webView.url), ProfileStore.pendingDataMutation == nil else { return }
        let path = webView.url?.path.isEmpty == false ? webView.url!.path : "/"
        guard Self.validDraftPath(path) else { return }
        let options: [String: Any] = ["enabled": persistent && PromptDraftStore.isRestoreEnabled(), "path": path,
                                      "pageStateEnabled": persistent, "autofocus": (path == "/" || focusWhenReady) && window.isKeyWindow]
        guard let data = try? JSONSerialization.data(withJSONObject: options), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__chatgptSwiftDraftUI?.configure(\(json));", completionHandler: nil)
    }

    func handlePromptDraftMessage(_ message: WKScriptMessage) {
        draftNativeMessageCount += 1
        guard persistent else { draftNativeDropReason = "临时窗口"; return }
        guard !isDisposing, ProfileStore.pendingDataMutation == nil,
              message.frameInfo.isMainFrame, Self.isTrustedChatGPTBridgeOrigin(message.frameInfo.securityOrigin),
              let payload = message.body as? [String: Any], let path = payload["path"] as? String,
              Self.validDraftPath(path), let action = payload["action"] as? String else { draftNativeDropReason = "来源或载荷"; return }
        if action == "ready" { configureDraftExperience(); draftNativeDropReason = "ready"; return }
        // Page events can save a draft, but cannot delete it. In particular, an empty composer
        // or an arriving reply is never interpreted as a request to clear the local copy.
        guard action == "save" else { draftNativeDropReason = "未知动作"; return }
        guard PromptDraftStore.isRestoreEnabled(),
              let text = payload["text"] as? String, text.count <= 200_000,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { draftNativeDropReason = "空输入或超限"; return }
        PromptDraftStore.saveDraft(text, profileID: profileID, conversationID: draftKey(for: path))
        draftNativeSaveCount += 1
        draftNativeDropReason = "save"
    }

    @objc func restoreSavedDraft(_ sender: Any?) {
        guard persistent, !isDisposing, ProfileStore.pendingDataMutation == nil,
              Self.canInjectPromptContent(into: webView.url) else { return }
        let path = webView.url?.path.isEmpty == false ? webView.url!.path : "/"
        let text = PromptDraftStore.draft(for: profileID, conversationID: draftKey(for: path))
        guard !text.isEmpty else { showToast("本页没有可恢复的本机草稿"); return }
        restoreDraft(text, path: path)
    }

    private func restoreDraft(_ text: String, path: String) {
        guard Self.canInjectPromptContent(into: webView.url), !isDisposing else { return }
        let literal = String(data: (try? JSONEncoder().encode(path)) ?? Data(), encoding: .utf8) ?? "\"\""
        let script = "location.pathname === \(literal) ? \(Self.restorePromptDraftScript(text: text)) : ({restored:false, reason:'page changed'})"
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, !self.isDisposing else { return }
            if let report = result as? [String: Any], report["restored"] as? Bool == true {
                PromptDraftStore.saveDraft(text, profileID: self.profileID, conversationID: self.draftKey(for: path))
                self.configureDraftExperience()
                return
            }
            let reason = (result as? [String: Any])?["reason"] as? String
            let detail = reason == "composer not empty" ? "输入框已有内容，保留现有输入；本机草稿仍在" : "页面或输入框尚未就绪，本机草稿仍在"
            self.showToast("恢复未完成：\(detail)", actionTitle: "重试", action: { [weak self] in self?.restoreDraft(text, path: path) }, duration: 12)
            if error != nil { browserLogger.debug("Draft restore script unavailable") }
        }
    }

    static let promptDraftCaptureScript = #"""
    (() => {
      const host = location.hostname.toLowerCase();
      const trusted = location.protocol === 'https:' && (host === 'chatgpt.com' || host.endsWith('.chatgpt.com') || host === 'chat.openai.com' || host.endsWith('.chat.openai.com'));
      const blocked = () => location.pathname.startsWith('/cdn-cgi/') || !!document.querySelector('iframe[src*="challenges.cloudflare.com"],.cf-turnstile,#cf-challenge-running,#challenge-stage,[data-cf-challenge]');
      if (!trusted || blocked() || window.__chatgptSwiftPromptDraftBridgeInstalled) return;
      window.__chatgptSwiftPromptDraftBridgeInstalled = true;
      const selector = '#prompt-textarea,textarea[data-testid="prompt-textarea"],[contenteditable="true"][data-testid="prompt-textarea"]';
      let composer = null, state = { enabled:window.__chatgptSwiftDraftEnabled !== false, pageStateEnabled:window.__chatgptSwiftPersistent !== false, path:location.pathname };
      let pendingInput = null, timer = 0, composing = false, bootstrap = null;
      const textOf = element => {
        if (!element) return '';
        if (element instanceof HTMLTextAreaElement || element instanceof HTMLInputElement) return element.value || '';
        // Keep newlines without innerText's synchronous layout flush.
        const read = node => {
          if (node.nodeType === Node.TEXT_NODE) return node.nodeValue || '';
          if (!(node instanceof Element)) return '';
          if (node.tagName === 'BR') return '\n';
          let result = Array.from(node.childNodes, read).join('');
          if (/^(P|DIV|LI|PRE)$/.test(node.tagName) && node !== element) result += '\n';
          return result;
        };
        return read(element).replace(/\n$/, '');
      };
      const post = payload => { if (blocked()) return; try { window.webkit.messageHandlers.promptDraft.postMessage(payload); } catch (_) {} };
      const focusIfIdle = () => {
        if (state.autofocus && composer && (!document.activeElement || document.activeElement === document.body)) composer.focus({preventScroll:true});
      };
      const attach = () => {
        const next = document.getElementById('prompt-textarea') || document.querySelector(selector);
        if (!next || next === composer) return;
        composer = next;
        bootstrap?.disconnect();
        focusIfIdle();
        post({action:'ready',path:location.pathname});
      };
      const flush = () => {
        clearTimeout(timer); timer = 0;
        if (!state.enabled || composing || !pendingInput || blocked()) return;
        const input = pendingInput; pendingInput = null;
        const text = textOf(input.element);
        if (!text.trim() || text.length > 200000) return;
        post({action:'save',text,path:input.path});
      };
      const onInput = event => {
        if (!state.enabled || composing) return;
        const target = event.target instanceof Element ? event.target.closest(selector) : null;
        if (!target) return;
        composer = target;
        pendingInput = {element:target,path:location.pathname};
        clearTimeout(timer); timer = setTimeout(flush, 350);
      };
      document.addEventListener('input',onInput,true);
      document.addEventListener('change',onInput,true);
      document.addEventListener('compositionstart',event => {if (event.target instanceof Element && event.target.closest(selector)) composing=true;},true);
      document.addEventListener('compositionend',event => {composing=false;onInput(event);},true);
      document.addEventListener('keydown',event => {
        if (event.isComposing || composing) return;
        if (event.key === 'Enter' && !event.shiftKey || (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'r') flush();
      },true);
      document.addEventListener('submit',flush,true);
      document.addEventListener('click',event => {
        if (event.target instanceof Element && event.target.closest('a[href],[data-testid="send-button"],button[type="submit"]')) flush();
      },true);
      window.addEventListener('pagehide',flush);
      window.addEventListener('popstate',flush);
      document.addEventListener('visibilitychange',() => {if (document.hidden) flush();});
      document.addEventListener('focusin',event => {if (event.target instanceof Element && event.target.closest(selector)) attach();});
      let scrollTarget=document.scrollingElement, scrollTimer=0, main=document.querySelector('main');
      const pageState=() => {
        if (!state.pageStateEnabled || !scrollTarget || blocked()) return;
        const trail=[]; let target=scrollTarget;
        if (target !== document.scrollingElement) {
          while(target && target !== document.body && trail.length<24) {
            const parent=target.parentElement; if(!parent) return;
            trail.unshift(Array.prototype.indexOf.call(parent.children,target)); target=parent;
          }
        }
        const result={path:location.pathname,scrollTop:scrollTarget.scrollTop,trail};
        try {window.webkit.messageHandlers.pageState.postMessage(result);} catch(_) {}
        return result;
      };
      document.addEventListener('scroll',event => {
        const target=event.target===document ? document.scrollingElement : event.target;
        if (!main?.isConnected) main=document.querySelector('main');
        if (!(target instanceof Element) || main && !main.contains(target) && !target.contains(main)) return;
        scrollTarget=target; clearTimeout(scrollTimer); scrollTimer=setTimeout(pageState,350);
      },{capture:true,passive:true});
      window.addEventListener('pagehide',pageState);
      window.__chatgptSwiftDraftUI={
        diagnostics:() => ({enabled:state.enabled,composing,attached:!!composer?.isConnected,blocked:blocked()}),
        configure:options => {
          if(options.path!==location.pathname) return;
          if(state.path!==options.path) {flush();scrollTarget=document.scrollingElement;}
          state=options; attach(); focusIfIdle();
        },
        snapshot:() => ({path:location.pathname,text:textOf(composer)}),
        clear:() => {clearTimeout(timer);pendingInput=null;},
        flush,pageState
      };
      attach();
      if(!composer) {
        let scheduled=false;
        bootstrap=new MutationObserver(() => {
          if(scheduled) return;scheduled=true;
          setTimeout(() => {scheduled=false;attach();},150);
        });
        bootstrap.observe(document.documentElement,{childList:true,subtree:true});
        setTimeout(() => bootstrap?.disconnect(),10000);
      }
    })()
    """#
}
