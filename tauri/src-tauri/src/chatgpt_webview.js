(function () {
  const marker = "__WK_TAURI_WEB_PATCHED__";
  if (window[marker]) return;
  try {
    Object.defineProperty(window, marker, {
      value: true,
      configurable: false,
      writable: false,
    });
  } catch (_) {
    window[marker] = true;
  }

  function isTrustedPage() {
    try {
      const host = window.location.hostname.toLowerCase();
      return (
        window.location.protocol === "https:" &&
        (host === "chatgpt.com" ||
          host.endsWith(".chatgpt.com") ||
          host === "chat.openai.com" ||
          host.endsWith(".chat.openai.com"))
      );
    } catch (_) {
      return false;
    }
  }

  if (!isTrustedPage()) return;

  function looksLikeCloudflareChallenge() {
    try {
      const href = String(window.location.href || "").toLowerCase();
      if (href.includes("/cdn-cgi/challenge-platform/")) return true;
      if (
        document.querySelector(
          [
            'iframe[src*="challenges.cloudflare.com"]',
            ".cf-turnstile",
            "#cf-challenge-running",
            "#challenge-stage",
            "[data-cf-challenge]",
          ].join(","),
        )
      ) {
        return true;
      }
      const text = String(document.body ? document.body.textContent || "" : "").toLowerCase();
      return (
        text.includes("cloudflare") &&
        (text.includes("verifying") ||
          text.includes("checking") ||
          text.includes("正在验证") ||
          text.includes("验证"))
      );
    } catch (_) {
      return false;
    }
  }

  const maxBlobDownloadBytes = 200 * 1024 * 1024;
  const zoomStorageKey = "chatgptWebviewZoom";
  const minZoom = 0.85;
  const maxZoom = 1.4;
  const zoomStep = 0.05;
  const objectUrlCache = new Map();

  function getInvoke() {
    return window.__TAURI__ && window.__TAURI__.core
      ? window.__TAURI__.core.invoke
      : null;
  }

  function cleanFilename(filename) {
    const fallback = "chatgpt-download";
    const value = String(filename || fallback)
      .replace(/[\\/:]/g, "_")
      .replace(/[\u0000-\u001f\u007f]/g, "_")
      .trim();
    return value || fallback;
  }

  function filenameFromUrl(url) {
    try {
      const pathname = new URL(url, window.location.href).pathname;
      const last = pathname.split("/").filter(Boolean).pop();
      return cleanFilename(last || "chatgpt-download");
    } catch (_) {
      return "chatgpt-download";
    }
  }

  function showDownloadNotice(message) {
    try {
      const existing = document.getElementById("chatgpt-rust-download-notice");
      if (existing) existing.remove();

      const notice = document.createElement("div");
      notice.id = "chatgpt-rust-download-notice";
      notice.setAttribute("role", "status");
      notice.style.cssText = [
        "position:fixed",
        "right:18px",
        "bottom:18px",
        "z-index:2147483647",
        "max-width:min(420px,calc(100vw - 36px))",
        "box-sizing:border-box",
        "padding:12px 14px",
        "border-radius:10px",
        "background:rgba(17,17,17,.94)",
        "color:#fff",
        "box-shadow:0 12px 32px rgba(0,0,0,.22)",
        "font:14px/1.45 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif",
      ].join(";");
      notice.textContent = message;
      document.body.appendChild(notice);
      window.setTimeout(() => notice.remove(), 5200);
    } catch (_) {
      // Console fallback keeps the page behavior intact if DOM insertion is blocked.
      console.error(message);
    }
  }

  async function saveBytes(filename, buffer) {
    const invoke = getInvoke();
    if (!invoke) return false;

    if (!buffer || buffer.byteLength === 0) return false;
    if (buffer.byteLength > maxBlobDownloadBytes) {
      console.error("WebView download is too large for IPC bridge");
      return false;
    }

    const sessionId = await invoke("start_blob_download", {
      filename: cleanFilename(filename),
      expectedSize: buffer.byteLength,
    });
    const bytes = new Uint8Array(buffer);
    const chunkSize = 1024 * 1024;

    try {
      for (let offset = 0; offset < bytes.length; offset += chunkSize) {
        const chunk = bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length));
        await invoke("append_blob_download", {
          sessionId,
          bytes: Array.from(chunk),
        });
      }

      await invoke("finish_blob_download", { sessionId });
      return true;
    } catch (error) {
      try {
        await invoke("cancel_blob_download", { sessionId });
      } catch (_) {
        // Best-effort cleanup; the original write error is more useful.
      }
      throw error;
    }
  }

  async function specialUrlToBuffer(url) {
    if (url.startsWith("blob:") && objectUrlCache.has(url)) {
      return objectUrlCache.get(url).arrayBuffer();
    }

    const response = await fetch(url);
    return response.arrayBuffer();
  }

  async function handleSpecialDownload(url, filename) {
    try {
      const buffer = await specialUrlToBuffer(url);
      const saved = await saveBytes(filename, buffer);
      if (!saved) {
        showDownloadNotice("下载没有保存。请重试，或在浏览器中打开后另存。");
      }
      return saved;
    } catch (error) {
      console.error("WebView special download failed", error);
      showDownloadNotice("下载失败，未写入文件。请重试，或在浏览器中打开后另存。");
      return false;
    }
  }

  function installObjectUrlCache() {
    if (!window.URL || !window.URL.createObjectURL) return;

    const originalCreateObjectUrl = window.URL.createObjectURL.bind(window.URL);
    window.URL.createObjectURL = function (blob) {
      const url = originalCreateObjectUrl(blob);
      objectUrlCache.set(url, blob);
      return url;
    };
    if (window.URL.revokeObjectURL) {
      const originalRevokeObjectUrl = window.URL.revokeObjectURL.bind(window.URL);
      window.URL.revokeObjectURL = function (url) {
        objectUrlCache.delete(url);
        return originalRevokeObjectUrl(url);
      };
    }
  }

  function installDownloadInterceptor() {
    document.addEventListener(
      "click",
      function (event) {
        const anchor =
          event.target && typeof event.target.closest === "function"
            ? event.target.closest('a[href^="blob:"],a[href^="data:"]')
            : null;

        if (!anchor) return;

        const href = anchor.href || "";

        const filename = cleanFilename(anchor.download || filenameFromUrl(href));
        event.preventDefault();
        event.stopImmediatePropagation();
        handleSpecialDownload(href, filename);
      },
      true,
    );
  }

  function installStopTooltipGuard() {
    const stopTooltipLabels = [
      "停止回答",
      "Stop generating",
      "Stop response",
      "Stop answering",
    ];
    const tooltipSelector = '[role="tooltip"], [data-radix-popper-content-wrapper]';
    let guardTimer = 0;

    function hideStopTooltips() {
      guardTimer = 0;
      for (const tooltip of document.querySelectorAll(tooltipSelector)) {
        const text = (tooltip.textContent || "").trim();
        if (!stopTooltipLabels.some((label) => text.includes(label))) continue;
        tooltip.style.setProperty("display", "none", "important");
        tooltip.style.setProperty("visibility", "hidden", "important");
        tooltip.setAttribute("data-wk-hidden-stop-tooltip", "true");
      }
    }

    function scheduleGuard() {
      if (guardTimer) return;
      guardTimer = window.setTimeout(hideStopTooltips, 80);
    }

    const root = document.documentElement || document.body;
    if (!root) {
      document.addEventListener("DOMContentLoaded", installStopTooltipGuard, { once: true });
      return;
    }

    scheduleGuard();
    document.addEventListener("pointermove", scheduleGuard, true);
    document.addEventListener("focusin", scheduleGuard, true);
    new MutationObserver(scheduleGuard).observe(root, {
      childList: true,
      subtree: true,
    });
  }

  function resetInjectedZoom() {
    window.localStorage.removeItem("chatgptWebZoom");
    window.localStorage.removeItem("htmlZoom");
    document.documentElement.style.zoom = "";
    document.body.style.zoom = "";
    window.dispatchEvent(new Event("resize"));
  }

  function clampZoom(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return 1;
    return Math.min(maxZoom, Math.max(minZoom, number));
  }

  function readZoom() {
    return clampZoom(window.localStorage.getItem(zoomStorageKey) || "1");
  }

  async function applyNativeZoom(value) {
    const invoke = getInvoke();
    const scale = clampZoom(value);
    window.localStorage.setItem(zoomStorageKey, String(scale));

    if (!invoke) return scale;

    try {
      const applied = await invoke("set_native_webview_zoom", { scale });
      const clamped = clampZoom(applied);
      window.localStorage.setItem(zoomStorageKey, String(clamped));
      return clamped;
    } catch (error) {
      console.error("WebView native zoom failed", error);
      return scale;
    }
  }

  function isZoomShortcut(event) {
    if (event.defaultPrevented) return false;
    const commandLike = event.metaKey || event.ctrlKey;
    return commandLike && !event.altKey;
  }

  function installNativeZoomShortcuts() {
    applyNativeZoom(readZoom());

    document.addEventListener(
      "keydown",
      function (event) {
        if (!isZoomShortcut(event)) return;

        let nextZoom = null;
        if (event.key === "+" || event.key === "=") {
          nextZoom = readZoom() + zoomStep;
        } else if (event.key === "-") {
          nextZoom = readZoom() - zoomStep;
        } else if (event.key === "0") {
          nextZoom = 1;
        }

        if (nextZoom === null) return;

        event.preventDefault();
        event.stopImmediatePropagation();
        applyNativeZoom(nextZoom);
      },
      true,
    );
  }

  function installCompositionGuard() {
    // Do not intercept IME "Process" key events; ChatGPT handles composition better natively.
  }

  function install() {
    if (looksLikeCloudflareChallenge()) return;
    installObjectUrlCache();
    resetInjectedZoom();
    installStopTooltipGuard();
    installNativeZoomShortcuts();
    installDownloadInterceptor();
    installCompositionGuard();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", install, { once: true });
  } else {
    install();
  }
})();
