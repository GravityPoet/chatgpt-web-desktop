/// WebRTC blocker script — disables RTCPeerConnection and related constructors.
pub const WEBRTC_BLOCKER_SCRIPT: &str = r#"
(() => {
  if (window.__wkRTCGuard) return;
  try {
    Object.defineProperty(window, '__wkRTCGuard', { value: true, configurable: false, writable: false });
  } catch (_) {}
  try {
    const markFake = window.__wkMarkNative || ((fn) => fn);
    const names = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection', 'RTCIceCandidate', 'RTCSessionDescription', 'RTCDataChannel'];
    for (const name of names) {
      try {
        Object.defineProperty(window, name, { value: undefined, configurable: false, writable: false });
      } catch (_) {}
    }
    if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
      const original = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
      const enumerateDevices = function enumerateDevices() { return original().then(() => []); };
      markFake(enumerateDevices, 'enumerateDevices');
      navigator.mediaDevices.enumerateDevices = enumerateDevices;
    }
  } catch (_) {}
})();
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passkey_notice_avoids_layout_heavy_scan() {
        assert!(PASSKEY_NOTICE_SCRIPT.contains("textContent"));
        assert!(PASSKEY_NOTICE_SCRIPT.contains("5000"));
        assert!(!PASSKEY_NOTICE_SCRIPT.contains("innerText"));
    }
}

/// Privacy signals script — sets `navigator.globalPrivacyControl = true`.
pub const PRIVACY_SIGNALS_SCRIPT: &str = r#"
(() => {
  if (window.__wkPrivacySignals) return;
  try {
    Object.defineProperty(window, '__wkPrivacySignals', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const markFake = window.__wkMarkNative || ((fn) => fn);
  const defineBooleanGetter = (target, key, value) => {
    try {
      const getterName = 'get ' + key;
      const fn = { [getterName]: function () { return value; } }[getterName];
      markFake(fn, getterName);
      Object.defineProperty(target, key, { get: fn, configurable: true });
    } catch (_) {}
  };

  defineBooleanGetter(Navigator.prototype, 'globalPrivacyControl', true);
  defineBooleanGetter(navigator, 'globalPrivacyControl', true);
})();
"#;

/// Passkey limitation notice script — shows a banner on passkey pages.
#[allow(dead_code)]
pub const PASSKEY_NOTICE_SCRIPT: &str = r#"
(() => {
  if (window.__wkPasskeyLimitationNoticeInstalled) return;
  try {
    Object.defineProperty(window, '__wkPasskeyLimitationNoticeInstalled', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const trustedHost = (host) => {
    const normalized = String(host || '').toLowerCase();
    return normalized === 'chatgpt.com'
      || normalized.endsWith('.chatgpt.com')
      || normalized === 'chat.openai.com'
      || normalized.endsWith('.chat.openai.com')
      || normalized === 'openai.com'
      || normalized.endsWith('.openai.com');
  };

  if (!trustedHost(location.hostname)) return;

  const hrefLooksLikePasskey = () => {
    const href = String(location.href || '').toLowerCase();
    return href.includes('passkey')
      || href.includes('webauthn')
      || href.includes('security_key')
      || href.includes('publickeycredential')
      || href.includes('credential');
  };

  const bodyLooksLikePasskey = () => {
    const text = String(document.body ? document.body.textContent || '' : '').toLowerCase();
    return text.includes('使用密钥继续')
      || text.includes('通行密钥')
      || text.includes('帐户的密钥')
      || text.includes('账户的密钥')
      || text.includes('passkey to continue')
      || text.includes('continue with passkey')
      || text.includes('use your passkey')
      || text.includes('we found a passkey')
      || text.includes('security key to continue')
      || text.includes('use your security key');
  };

  const pageLooksLikePasskey = () => {
    return hrefLooksLikePasskey() || bodyLooksLikePasskey();
  };

  const showNotice = () => {
    if (!pageLooksLikePasskey()) return;
    if (document.getElementById('chatgpt-rust-passkey-notice')) return;
    if (!document.body || window.__wkPasskeyLimitationNoticeDismissed) return;

    const notice = document.createElement('aside');
    notice.id = 'chatgpt-rust-passkey-notice';
    notice.setAttribute('role', 'status');
    notice.style.cssText = [
      'position:fixed',
      'top:18px',
      'left:50%',
      'transform:translateX(-50%)',
      'z-index:2147483647',
      'box-sizing:border-box',
      'width:min(760px,calc(100vw - 32px))',
      'padding:14px 44px 14px 16px',
      'border:1px solid rgba(255,255,255,.16)',
      'border-radius:10px',
      'background:rgba(17,17,17,.96)',
      'color:#fff',
      'box-shadow:0 14px 40px rgba(0,0,0,.22)',
      'font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
      'text-align:left'
    ].join(';');

    const title = document.createElement('div');
    title.textContent = '这个本地 wrapper 不能使用 chatgpt.com / openai.com 的 Apple 通行密钥。';
    title.style.cssText = 'font-weight:650;margin:0 0 4px';
    notice.appendChild(title);

    const detail = document.createElement('div');
    detail.textContent = '请点"尝试其他方法"，或用 Safari、Chrome、官方 ChatGPT App 完成 passkey 登录。';
    detail.style.cssText = 'color:rgba(255,255,255,.78);margin:0';
    notice.appendChild(detail);

    const close = document.createElement('button');
    close.type = 'button';
    close.setAttribute('aria-label', '关闭提示');
    close.textContent = '×';
    close.style.cssText = [
      'position:absolute',
      'top:8px',
      'right:10px',
      'width:28px',
      'height:28px',
      'border:0',
      'border-radius:999px',
      'background:rgba(255,255,255,.12)',
      'color:#fff',
      'font:20px/26px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif',
      'cursor:pointer'
    ].join(';');
    close.addEventListener('click', () => {
      window.__wkPasskeyLimitationNoticeDismissed = true;
      notice.remove();
    });
    notice.appendChild(close);

    document.body.appendChild(notice);
  };

  let scheduled = false;
  const schedule = () => {
    if (scheduled) return;
    scheduled = true;
    window.requestAnimationFrame(() => {
      scheduled = false;
      showNotice();
    });
  };
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', schedule, { once: true });
  } else {
    schedule();
  }

  try {
    const observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, { childList: true, subtree: true });
    window.setTimeout(() => observer.disconnect(), 5000);
  } catch (_) {}
})();
"#;

/// Native shim script — makes injected functions appear as `[native code]` in toString().
pub const NATIVE_SHIM_SCRIPT: &str = r#"
(() => {
  if (window.__wkNativeShim) return;
  try {
    Object.defineProperty(window, '__wkNativeShim', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const origToString = Function.prototype.toString;
  const fakeMap = new WeakMap();

  const patchedToString = function toString() {
    try {
      if (fakeMap.has(this)) return fakeMap.get(this);
    } catch (_) {}
    return origToString.call(this);
  };

  try {
    fakeMap.set(patchedToString, 'function toString() { [native code] }');
    fakeMap.set(origToString, 'function toString() { [native code] }');
  } catch (_) {}

  try {
    Object.defineProperty(Function.prototype, 'toString', {
      value: patchedToString,
      writable: true,
      configurable: true
    });
  } catch (_) {}

  const markFake = (fn, name) => {
    try {
      if (typeof fn === 'function' && typeof name === 'string') {
        fakeMap.set(fn, 'function ' + name + '() { [native code] }');
      }
    } catch (_) {}
    return fn;
  };
  markFake(markFake, 'markFake');

  try {
    Object.defineProperty(window, '__wkMarkNative', {
      value: markFake,
      writable: false,
      configurable: false
    });
  } catch (_) {}
})();
"#;

/// Generate the full fingerprint test page HTML (self-contained, with embedded JS).
pub fn fingerprint_test_page_html(engine_label: &str) -> String {
    let canvas_label = format!("ChatGPT Rust 指纹检测 123");
    format!(
        r#"<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>指纹检测页</title>
  <style>
    :root {{ color-scheme: light dark; }}
    body {{
      margin: 0;
      padding: 28px;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
      background: #f8fafc;
      color: #111827;
    }}
    main {{ max-width: 1040px; margin: 0 auto; }}
    section {{ margin-top: 22px; }}
    h1 {{ font-size: 24px; margin: 0 0 8px; }}
    h2 {{ font-size: 16px; margin: 0 0 10px; }}
    p {{ margin: 0 0 18px; color: #4b5563; line-height: 1.5; }}
    table {{ width: 100%; border-collapse: collapse; border: 1px solid #d1d5db; background: #ffffff; }}
    th, td {{ border-bottom: 1px solid #e5e7eb; padding: 9px 10px; text-align: left; vertical-align: top; font-size: 13px; }}
    tr:last-child th, tr:last-child td {{ border-bottom: 0; }}
    th {{ width: 260px; font-weight: 650; }}
    code {{ word-break: break-all; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }}
    .ok {{ color: #15803d; }}
    .warn {{ color: #b45309; }}
    .risk-low {{ color: #15803d; }}
    .risk-medium {{ color: #b45309; }}
    .risk-high {{ color: #b91c1c; }}
    .badge {{
      display: inline-block;
      min-width: 54px;
      padding: 2px 7px;
      border-radius: 999px;
      text-align: center;
      font-size: 12px;
      font-weight: 650;
      background: #eef2ff;
    }}
    @media (prefers-color-scheme: dark) {{
      body {{ background: #0f172a; color: #e5e7eb; }}
      p {{ color: #94a3b8; }}
      table {{ border-color: #334155; background: #111827; }}
      th, td {{ border-bottom-color: #1f2937; }}
      .ok {{ color: #86efac; }}
      .warn {{ color: #fbbf24; }}
      .risk-low {{ color: #86efac; }}
      .risk-medium {{ color: #fbbf24; }}
      .risk-high {{ color: #fca5a5; }}
      .badge {{ background: #1e293b; }}
    }}
  </style>
</head>
<body>
  <main>
    <h1>指纹检测页</h1>
    <p>这个页面在当前账号空间内运行，用来检查 UA、navigator、screen、WebRTC、Canvas、WebGL 和 AudioContext 暴露值，并提示 {engine_label} 隐私指纹的一致性风险。</p>
    <section>
      <h2>一致性风险</h2>
      <table><tbody id="risk"></tbody></table>
    </section>
    <section>
      <h2>原始暴露值</h2>
      <table><tbody id="report"></tbody></table>
    </section>
  </main>
  <script>
    const text = (value) => {{
      if (value === undefined) return 'undefined';
      if (value === null) return 'null';
      if (Array.isArray(value)) return JSON.stringify(value);
      if (typeof value === 'object') {{
        try {{ return JSON.stringify(value); }} catch (_) {{ return String(value); }}
      }}
      return String(value);
    }};
    const hashString = (value) => {{
      let hash = 2166136261;
      const raw = String(value);
      for (let i = 0; i < raw.length; i += 1) {{
        hash ^= raw.charCodeAt(i);
        hash = Math.imul(hash, 16777619);
      }}
      return (hash >>> 0).toString(16).padStart(8, '0');
    }};
    const canvasHash = () => {{
      try {{
        const canvas = document.createElement('canvas');
        canvas.width = 240;
        canvas.height = 80;
        const ctx = canvas.getContext('2d');
        ctx.fillStyle = '#f5f5f5';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.fillStyle = '#123456';
        ctx.font = '18px -apple-system, Arial';
        ctx.fillText('{canvas_label}', 12, 32);
        ctx.strokeStyle = '#c2410c';
        ctx.beginPath();
        ctx.arc(180, 42, 22, 0, Math.PI * 2);
        ctx.stroke();
        return hashString(canvas.toDataURL());
      }} catch (error) {{
        return 'error: ' + error.message;
      }}
    }};
    const webglInfo = () => {{
      try {{
        const canvas = document.createElement('canvas');
        const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
        if (!gl) return {{ available: false }};
        const debug = gl.getExtension('WEBGL_debug_renderer_info');
        return {{
          available: true,
          vendor: debug ? gl.getParameter(debug.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
          renderer: debug ? gl.getParameter(debug.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
          version: gl.getParameter(gl.VERSION)
        }};
      }} catch (error) {{
        return {{ error: error.message }};
      }}
    }};
    const audioHash = async () => {{
      try {{
        const Offline = window.OfflineAudioContext || window.webkitOfflineAudioContext;
        if (!Offline) return 'unavailable';
        const ctx = new Offline(1, 4410, 44100);
        const oscillator = ctx.createOscillator();
        const compressor = ctx.createDynamicsCompressor();
        oscillator.type = 'triangle';
        oscillator.frequency.value = 10000;
        compressor.threshold.value = -50;
        compressor.knee.value = 40;
        compressor.ratio.value = 12;
        compressor.attack.value = 0;
        compressor.release.value = 0.25;
        oscillator.connect(compressor);
        compressor.connect(ctx.destination);
        oscillator.start(0);
        const buffer = await ctx.startRendering();
        const data = buffer.getChannelData(0);
        let sum = 0;
        for (let i = 0; i < data.length; i += 37) sum += Math.abs(data[i]);
        return hashString(sum.toFixed(12));
      }} catch (error) {{
        return 'error: ' + error.message;
      }}
    }};
    const rows = [];
    const riskRows = [];
    const add = (key, value) => rows.push([key, text(value)]);
    const addRisk = (level, key, value) => riskRows.push([level, key, text(value)]);
    const escapeHTML = (value) => value.replace(/[&<>]/g, (c) => ({{ '&': '&amp;', '<': '&lt;', '>': '&gt;' }}[c]));
    const render = () => {{
      document.getElementById('risk').innerHTML = riskRows.map(([level, key, value]) => {{
        const cls = level === '高' ? 'risk-high' : (level === '中' ? 'risk-medium' : 'risk-low');
        return `<tr><th><span class="badge ${{cls}}">${{escapeHTML(level)}}</span> ${{escapeHTML(key)}}</th><td class="${{cls}}"><code>${{escapeHTML(value)}}</code></td></tr>`;
      }}).join('');
      document.getElementById('report').innerHTML = rows.map(([key, value]) => {{
        const cls = value === 'undefined' || value === 'absent' ? 'warn' : 'ok';
        return `<tr><th>${{escapeHTML(key)}}</th><td class="${{cls}}"><code>${{escapeHTML(value)}}</code></td></tr>`;
      }}).join('');
    }};
    const buildRiskReport = () => {{
      const ua = navigator.userAgent || '';
      const platform = navigator.platform || '';
      const safariFamily = /AppleWebKit/i.test(ua) && /Safari/i.test(ua) && !/(Chrome|CriOS|Firefox|FxiOS|Edg|OPR)/i.test(ua);
      addRisk(safariFamily ? '低' : '高', 'Safari 家族一致性', safariFamily ? 'UA 属于 Safari/WebKit 家族' : 'UA 不是纯 Safari/WebKit 家族');

      let device = 'mac';
      if (/iPhone/i.test(ua)) device = 'iphone';
      if (/iPad/i.test(ua)) device = 'ipad';
      const touchPoints = Number(navigator.maxTouchPoints || 0);
      const platformOk = (device === 'mac' && platform === 'MacIntel' && touchPoints === 0)
        || (device === 'iphone' && platform === 'iPhone' && touchPoints > 0)
        || (device === 'ipad' && (platform === 'iPad' || platform === 'MacIntel') && touchPoints > 0);
      addRisk(platformOk ? '低' : '高', 'UA / platform / touch', `${{device}}, platform=${{platform}}, maxTouchPoints=${{touchPoints}}`);

      const safariOnlySignals = [];
      if (navigator.userAgentData !== undefined) safariOnlySignals.push('userAgentData present');
      if (navigator.deviceMemory !== undefined) safariOnlySignals.push('deviceMemory present');
      if (navigator.connection !== undefined) safariOnlySignals.push('connection present');
      addRisk(safariOnlySignals.length ? '中' : '低', 'Safari-only API 暴露', safariOnlySignals.length ? safariOnlySignals.join(', ') : '未发现 Chromium-only API');

      const rtcBlocked = typeof RTCPeerConnection === 'undefined' && typeof webkitRTCPeerConnection === 'undefined';
      addRisk(rtcBlocked ? '低' : '中', 'WebRTC 暴露', rtcBlocked ? '构造器不可见' : '构造器仍可见，语音可用性和隐私需要权衡');

      addRisk(navigator.globalPrivacyControl === true ? '低' : '中', 'GPC', navigator.globalPrivacyControl === true ? 'navigator.globalPrivacyControl=true' : '未检测到 GPC JS 信号');

      const screenMismatch = innerWidth > screen.width + 48 || innerHeight > screen.height + 140;
      addRisk(screenMismatch ? '高' : '低', '窗口 / screen 尺寸', `inner=${{innerWidth}}x${{innerHeight}}, screen=${{screen.width}}x${{screen.height}}, dpr=${{devicePixelRatio}}`);

      addRisk('中', '不可控残余', 'TLS/HTTP2 SETTINGS/IP/字体/Worker/行为模式仍由系统、网络和站点侧模型决定');
    }};

    add('URL', location.href);
    add('User-Agent', navigator.userAgent);
    add('navigator.platform', navigator.platform);
    add('navigator.language', navigator.language);
    add('navigator.languages', Array.from(navigator.languages || []));
    add('navigator.hardwareConcurrency', navigator.hardwareConcurrency);
    add('navigator.deviceMemory', navigator.deviceMemory);
    add('navigator.maxTouchPoints', navigator.maxTouchPoints);
    add('navigator.userAgentData', navigator.userAgentData);
    add('plugins.length', navigator.plugins ? navigator.plugins.length : 'undefined');
    add('mimeTypes.length', navigator.mimeTypes ? navigator.mimeTypes.length : 'undefined');
    add('TouchEvent', 'TouchEvent' in window ? 'present' : 'absent');
    add('screen', {{
      width: screen.width,
      height: screen.height,
      availWidth: screen.availWidth,
      availHeight: screen.availHeight,
      colorDepth: screen.colorDepth,
      pixelDepth: screen.pixelDepth,
      orientation: screen.orientation ? {{ type: screen.orientation.type, angle: screen.orientation.angle }} : undefined
    }});
    add('window size', {{
      innerWidth,
      innerHeight,
      outerWidth,
      outerHeight,
      devicePixelRatio
    }});
    add('timezone', Intl.DateTimeFormat().resolvedOptions().timeZone);
    add('WebRTC constructors', {{
      RTCPeerConnection: typeof RTCPeerConnection,
      webkitRTCPeerConnection: typeof webkitRTCPeerConnection,
      RTCIceCandidate: typeof RTCIceCandidate
    }});
    add('mediaDevices.enumerateDevices', navigator.mediaDevices && navigator.mediaDevices.enumerateDevices ? 'present' : 'absent');
    add('Canvas hash', canvasHash());
    add('WebGL', webglInfo());
    add('Audio hash', 'pending');
    buildRiskReport();
    render();

    audioHash().then((audio) => {{
      const target = rows.find((row) => row[0] === 'Audio hash');
      if (target) target[1] = text(audio);
      render();
    }});
  </script>
</body>
</html>"#,
        engine_label = engine_label,
        canvas_label = canvas_label,
    )
}
