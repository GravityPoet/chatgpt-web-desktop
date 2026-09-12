import Foundation

extension BrowserWindowController {
    static let completionStateObserverScript = """
    (() => {
      const host = location.hostname.toLowerCase();
      if (location.protocol !== 'https:' || !(host === 'chatgpt.com' || host.endsWith('.chatgpt.com') || host === 'chat.openai.com' || host.endsWith('.chat.openai.com'))) return;
      const challenge = () => location.pathname.startsWith('/cdn-cgi/challenge-platform/') || !!document.querySelector('iframe[src*="challenges.cloudflare.com"],.cf-turnstile,#cf-challenge-running,#challenge-stage,[data-cf-challenge]');
      if (challenge() || window.__chatgptSwiftCompletionObserverInstalled) return;
      window.__chatgptSwiftCompletionObserverInstalled = true;

      const selector = '[aria-busy="true"],[data-testid*="stop" i],button[aria-label*="stop" i],button[aria-label*="停止"],[role="button"][aria-label*="stop" i],[role="button"][aria-label*="停止"]';
      const controls = new Set(document.querySelectorAll(selector));
      let timer = 0, lastBusy = null;
      const include = node => {
        if (!(node instanceof Element)) return false;
        let changed = false;
        if (node.matches(selector)) { controls.add(node); changed = true; }
        // Examine only new subtrees. Text-token mutations never rescan the conversation.
        if (node.childElementCount) {
          for (const child of node.querySelectorAll(selector)) { controls.add(child); changed = true; }
        }
        return changed;
      };
      const scan = () => {
        timer = 0;
        if (challenge()) return;
        let reason = '';
        for (const control of controls) {
          if (!control.isConnected || !control.matches(selector)) { controls.delete(control); continue; }
          const rect = control.getBoundingClientRect();
          if (rect.width <= 0 || rect.height <= 0) continue;
          const style = getComputedStyle(control);
          if (style.visibility === 'hidden' || style.display === 'none') continue;
          reason = control.getAttribute('aria-busy') === 'true' ? 'aria-busy' : 'busy-control';
          break;
        }
        const busy = !!reason;
        if (busy === lastBusy) return;
        lastBusy = busy;
        try { window.webkit.messageHandlers.completionState.postMessage({ busy, reason }); } catch (_) {}
        window.dispatchEvent(new CustomEvent('chatgpt-swift-generation-state', { detail: { busy } }));
      };
      const schedule = () => {
        if (timer) return;
        timer = setTimeout(() => {
          if (window.requestIdleCallback) requestIdleCallback(scan, { timeout: 200 }); else scan();
        }, 100);
      };
      new MutationObserver(mutations => {
        let changed = false;
        for (const mutation of mutations) {
          if (mutation.type === 'attributes') {
            const target = mutation.target;
            if (target.matches(selector) || controls.has(target)) { controls.add(target); changed = true; }
            else if (['style','class','hidden'].includes(mutation.attributeName)) {
              for (const control of controls) if (target.contains(control)) { changed = true; break; }
            }
          } else {
            for (const node of mutation.addedNodes) if (include(node)) changed = true;
            if (mutation.removedNodes.length && controls.size) {
              for (const control of controls) if (!control.isConnected) { controls.delete(control); changed = true; }
            }
          }
        }
        if (changed) schedule();
      }).observe(document.documentElement, { subtree: true, childList: true, attributes: true,
          attributeFilter: ['aria-label','aria-busy','data-testid','disabled','style','class','hidden'] });
      document.addEventListener('visibilitychange', schedule);
      schedule();
    })()
    """
}
