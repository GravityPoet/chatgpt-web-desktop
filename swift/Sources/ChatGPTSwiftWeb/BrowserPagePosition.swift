import Foundation
import WebKit

extension BrowserWindowController {
    func handlePageStateMessage(_ message: WKScriptMessage) {
        guard persistent, !isQuickWindow, !isDisposing, ProfileStore.pendingDataMutation == nil,
              message.frameInfo.isMainFrame, Self.isTrustedChatGPTBridgeOrigin(message.frameInfo.securityOrigin),
              let payload = message.body as? [String: Any], let path = payload["path"] as? String,
              path == (webView.url?.path.isEmpty == false ? webView.url?.path : "/"),
              let top = payload["scrollTop"] as? Double, let trail = payload["trail"] as? [Int] else { return }
        ProfileSessionStore.save(ProfilePageState(path: path, scrollTop: top, trail: trail), profileID: profileID ?? defaultProfileID)
    }

    func capturePageState(completion: @escaping () -> Void) {
        persistMainWindowFrame()
        guard persistent, !isDisposing, Self.canInjectPromptContent(into: webView.url),
              ProfileStore.pendingDataMutation == nil else { completion(); return }
        let path = webView.url?.path.isEmpty == false ? webView.url!.path : "/"
        let id = profileID ?? defaultProfileID
        if !isQuickWindow, ProfileSessionStore.load(profileID: id)?.path != path {
            ProfileSessionStore.save(ProfilePageState(path: path), profileID: id)
        }
        // A stalled page must not hold an account switch indefinitely. The normal path flushes
        // unsaved keystrokes and scroll state before the old WebView is disposed.
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            completion()
        }
        webView.evaluateJavaScript("(() => { const ui = window.__chatgptSwiftDraftUI; ui?.flush(); ui?.pageState(); return ui?.snapshot() || null; })()") { [weak self] result, _ in
            guard !finished, let self, !self.isDisposing else { finish(); return }
            if PromptDraftStore.isRestoreEnabled(), let snapshot = result as? [String: Any],
               let capturedPath = snapshot["path"] as? String, capturedPath == path,
               snapshot["pending"] as? Bool != true, let text = snapshot["text"] as? String,
               !text.isEmpty, text.count <= 200_000 {
                PromptDraftStore.saveDraft(text, profileID: id, conversationID: self.draftKey(for: path))
            }
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: finish)
    }

    func restorePagePosition() {
        guard persistent, !isQuickWindow, !isDisposing, Self.canInjectPromptContent(into: webView.url),
              let state = ProfileSessionStore.load(profileID: profileID ?? defaultProfileID),
              state.path == (webView.url?.path.isEmpty == false ? webView.url?.path : "/"), state.scrollTop > 0,
              let data = try? JSONEncoder().encode(state), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(Self.restorePagePositionScript(json: json), completionHandler: nil)
    }

    static func restorePagePositionScript(json: String) -> String {
        """
        (() => {
          const state = \(json);
          let canceled = false, attempts = 0;
          const cancel = () => { canceled = true; cleanup(); };
          const cleanup = () => { window.removeEventListener('wheel', cancel, true); window.removeEventListener('keydown', cancel, true); window.removeEventListener('pointerdown', cancel, true); };
          window.addEventListener('wheel', cancel, { capture:true, passive:true });
          window.addEventListener('keydown', cancel, true);
          window.addEventListener('pointerdown', cancel, true);
          const restore = () => {
            if (canceled || location.pathname !== state.path || ++attempts > 8) { cleanup(); return; }
            let target = state.trail.length ? document.body : document.scrollingElement;
            for (const index of state.trail) target = target?.children[index];
            const main = document.querySelector('main');
            const relevant = target && (!main || main.contains(target) || target.contains(main));
            if (relevant && target.scrollHeight - target.clientHeight >= state.scrollTop - 2) {
              target.scrollTop = state.scrollTop;
              cleanup();
              return;
            }
            setTimeout(restore, 300);
          };
          setTimeout(restore, 200);
        })()
        """
    }
}
