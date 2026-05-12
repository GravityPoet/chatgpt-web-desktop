(function () {
  const marker = "__CHATGPT_TAURI_WEB_PATCHED__";
  if (window[marker]) return;
  window[marker] = true;

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

  async function saveBytes(filename, buffer) {
    const invoke = getInvoke();
    if (!invoke) return false;

    if (!buffer || buffer.byteLength === 0) return false;
    if (buffer.byteLength > maxBlobDownloadBytes) {
      console.error("ChatGPT Rust download is too large for IPC bridge");
      return false;
    }

    const bytes = Array.from(new Uint8Array(buffer));
    await invoke("save_blob_download", {
      filename: cleanFilename(filename),
      bytes,
    });
    return true;
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
      return await saveBytes(filename, buffer);
    } catch (error) {
      console.error("ChatGPT Rust special download failed", error);
      return false;
    }
  }

  if (window.URL && window.URL.createObjectURL) {
    const originalCreateObjectUrl = window.URL.createObjectURL.bind(window.URL);
    window.URL.createObjectURL = function (blob) {
      const url = originalCreateObjectUrl(blob);
      objectUrlCache.set(url, blob);
      return url;
    };
  }

  function installDownloadInterceptor() {
    document.addEventListener(
      "click",
      function (event) {
        const anchor =
          event.target && typeof event.target.closest === "function"
            ? event.target.closest("a[href]")
            : null;

        if (!anchor) return;

        const href = anchor.href || "";
        if (!href.startsWith("blob:") && !href.startsWith("data:")) return;

        const filename = cleanFilename(anchor.download || filenameFromUrl(href));
        event.preventDefault();
        event.stopImmediatePropagation();
        handleSpecialDownload(href, filename);
      },
      true,
    );
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
      console.error("ChatGPT Rust native zoom failed", error);
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
    document.addEventListener(
      "keydown",
      function (event) {
        if (event.key === "Process") {
          event.stopPropagation();
        }
      },
      true,
    );
  }

  function install() {
    resetInjectedZoom();
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
