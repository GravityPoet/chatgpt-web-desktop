use rand::Rng;
use serde::{Deserialize, Serialize};

/// Fingerprint profile schema — compatible with Swift's FingerprintProfile.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FingerprintProfile {
    #[serde(rename = "presetID")]
    pub preset_id: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    #[serde(default)]
    pub engine: String,
    #[serde(rename = "userAgent")]
    pub user_agent: String,
    #[serde(rename = "acceptLanguages")]
    pub accept_languages: Vec<String>,
    pub platform: String,
    #[serde(rename = "hardwareConcurrency")]
    pub hardware_concurrency: u32,
    #[serde(rename = "deviceMemory")]
    pub device_memory: u32,
    #[serde(rename = "screenWidth")]
    pub screen_width: u32,
    #[serde(rename = "screenHeight")]
    pub screen_height: u32,
    #[serde(rename = "colorDepth")]
    pub color_depth: u32,
    #[serde(rename = "devicePixelRatio")]
    pub device_pixel_ratio: f64,
    #[serde(rename = "maxTouchPoints")]
    pub max_touch_points: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timezone: Option<String>,
}

pub const OFF_PRESET_ID: &str = "off";
pub const DEFAULT_ACCEPT_LANGUAGES: &[&str] = &["zh-CN", "en-US"];

// --- macOS Safari/WebKit presets ---

const MAC_SAFARI17_UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Safari/605.1.15";
// iOS/iPadOS 26 freezes the UA OS token at 18_6 (like macOS freezes 10_15_7); the real OS major lives only in Version/ (26.0). Real devices report OS 18_6 — do NOT "correct" it to 26_0, that would be a detectable fake.
const IPAD_SAFARI17_UA: &str = "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";
const IPHONE_SAFARI17_UA: &str = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1";

// --- Windows Chromium/WebView2 presets ---

const WIN_CHROME_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

// --- Linux WebKitGTK presets ---

const LINUX_WEBKITGTK_UA: &str = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

/// Platform engine family for preset selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlatformEngine {
    /// macOS Safari/WebKit (WKWebView)
    SafariWebKit,
    /// Windows Chromium (WebView2)
    Chromium,
    /// Linux WebKitGTK
    WebKitGtk,
}

impl PlatformEngine {
    /// Detect the current platform's engine.
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::SafariWebKit
        } else if cfg!(target_os = "windows") {
            Self::Chromium
        } else {
            Self::WebKitGtk
        }
    }
}

/// Get all presets appropriate for the current platform.
pub fn platform_presets() -> Vec<FingerprintProfile> {
    match PlatformEngine::current() {
        PlatformEngine::SafariWebKit => mac_presets(),
        PlatformEngine::Chromium => windows_presets(),
        PlatformEngine::WebKitGtk => linux_presets(),
    }
}

/// The complete, engine-consistent default user agent for the current platform, used when no
/// fingerprint preset overrides it. WKWebView (macOS) and WebKitGTK (Linux) report a truncated
/// native UA — it stops at "(KHTML, like Gecko)" with no "Version/.. Safari/.." token — which
/// Cloudflare reads as a non-standard client and challenges repeatedly. WebView2 (Windows) already
/// reports a complete Edge UA, so it keeps its native UA (returns `None`).
pub fn platform_default_user_agent() -> Option<String> {
    match PlatformEngine::current() {
        PlatformEngine::SafariWebKit => Some(MAC_SAFARI17_UA.to_string()),
        PlatformEngine::WebKitGtk => Some(LINUX_WEBKITGTK_UA.to_string()),
        PlatformEngine::Chromium => None,
    }
}

/// Get a specific preset by ID.
pub fn preset_by_id(id: &str) -> Option<FingerprintProfile> {
    platform_presets().into_iter().find(|p| p.preset_id == id)
}

/// Generate a random stable fingerprint for the current platform.
pub fn random_fingerprint() -> FingerprintProfile {
    match PlatformEngine::current() {
        PlatformEngine::SafariWebKit => random_mac_fingerprint(),
        PlatformEngine::Chromium => random_windows_fingerprint(),
        PlatformEngine::WebKitGtk => random_linux_fingerprint(),
    }
}

/// Generate the fingerprint override JavaScript for a given profile.
pub fn fingerprint_script(fingerprint: &FingerprintProfile) -> String {
    let langs_json = serde_json::to_string(&fingerprint.accept_languages).unwrap_or_else(|_| "[]".to_string());
    let primary_lang = fingerprint
        .accept_languages
        .first()
        .map(|s| s.as_str())
        .unwrap_or("en-US");
    let ua = json_literal(&fingerprint.user_agent);
    let platform = json_literal(&fingerprint.platform);

    let timezone_block = if let Some(ref tz) = fingerprint.timezone {
        let tz_json = json_literal(tz);
        format!(
            r#"
            try {{
              const OrigDTF = Intl.DateTimeFormat;
              const TZ = {tz_json};
              function DateTimeFormat(locales, options) {{
                const o = Object.assign({{}}, options || {{}});
                if (!o.timeZone) o.timeZone = TZ;
                return new OrigDTF(locales, o);
              }}
              DateTimeFormat.prototype = OrigDTF.prototype;
              for (const k of ['supportedLocalesOf']) {{
                if (typeof OrigDTF[k] === 'function') {{
                  DateTimeFormat[k] = OrigDTF[k].bind(OrigDTF);
                  markFake(DateTimeFormat[k], k);
                }}
              }}
              markFake(DateTimeFormat, 'DateTimeFormat');
              Intl.DateTimeFormat = DateTimeFormat;
              const origResolved = Object.getOwnPropertyDescriptor(OrigDTF.prototype, 'resolvedOptions');
              if (origResolved && typeof origResolved.value === 'function') {{
                const origFn = origResolved.value;
                function resolvedOptions() {{
                  const r = origFn.call(this);
                  r.timeZone = TZ;
                  return r;
                }}
                markFake(resolvedOptions, 'resolvedOptions');
                Object.defineProperty(OrigDTF.prototype, 'resolvedOptions', {{ value: resolvedOptions, writable: true, configurable: true }});
              }}
              const origGetTZO = Date.prototype.getTimezoneOffset;
              function getTimezoneOffset() {{
                try {{
                  const parts = new OrigDTF('en-US', {{ timeZone: TZ, timeZoneName: 'shortOffset' }}).formatToParts(this);
                  const tzPart = parts.find(p => p.type === 'timeZoneName');
                  if (tzPart && tzPart.value) {{
                    const m = tzPart.value.match(/GMT([+-])(\\d+)(?::(\\d+))?/);
                    if (m) {{
                      const sign = m[1] === '+' ? -1 : 1;
                      const h = parseInt(m[2], 10) || 0;
                      const mi = parseInt(m[3] || '0', 10) || 0;
                      return sign * (h * 60 + mi);
                    }}
                  }}
                }} catch (_) {{}}
                return origGetTZO.call(this);
              }}
              markFake(getTimezoneOffset, 'getTimezoneOffset');
              Date.prototype.getTimezoneOffset = getTimezoneOffset;
            }} catch (_) {{}}
            "#
        )
    } else {
        String::new()
    };

    format!(
        r#"
        (() => {{
          if (window.__wkFingerprint) return;
          try {{
            Object.defineProperty(window, '__wkFingerprint', {{ value: true, configurable: false, writable: false }});
          }} catch (_) {{}}

          const markFake = window.__wkMarkNative || ((fn) => fn);

          const defGetter = (obj, key, val, getterName) => {{
            try {{
              const fn = {{ [getterName]: function () {{ return val; }} }}[getterName];
              markFake(fn, getterName);
              Object.defineProperty(obj, key, {{ get: fn, configurable: true }});
            }} catch (_) {{}}
          }};

          const langs = Object.freeze({langs_json}.slice ? {langs_json}.slice() : {langs_json});

          defGetter(Navigator.prototype, 'userAgent', {ua}, 'get userAgent');
          defGetter(Navigator.prototype, 'vendor', 'Apple Computer, Inc.', 'get vendor');
          defGetter(Navigator.prototype, 'platform', {platform}, 'get platform');
          defGetter(Navigator.prototype, 'language', {primary_lang:?}, 'get language');
          defGetter(Navigator.prototype, 'languages', langs, 'get languages');
          defGetter(Navigator.prototype, 'hardwareConcurrency', {hw_conc}, 'get hardwareConcurrency');
          defGetter(Navigator.prototype, 'maxTouchPoints', {touch}, 'get maxTouchPoints');
          try {{
            if ('webdriver' in navigator || 'webdriver' in Navigator.prototype) {{
              defGetter(Navigator.prototype, 'webdriver', undefined, 'get webdriver');
            }}
          }} catch (_) {{}}
          try {{
            if ('deviceMemory' in navigator || 'deviceMemory' in Navigator.prototype) {{
              defGetter(Navigator.prototype, 'deviceMemory', undefined, 'get deviceMemory');
            }}
          }} catch (_) {{}}

          defGetter(Screen.prototype, 'width', {sw}, 'get width');
          defGetter(Screen.prototype, 'height', {sh}, 'get height');
          defGetter(Screen.prototype, 'availWidth', {sw}, 'get availWidth');
          defGetter(Screen.prototype, 'availHeight', {sh}, 'get availHeight');
          defGetter(Screen.prototype, 'colorDepth', {cd}, 'get colorDepth');
          defGetter(Screen.prototype, 'pixelDepth', {cd}, 'get pixelDepth');

          try {{
            const dprFn = {{ 'get devicePixelRatio': function () {{ return {dpr}; }} }}['get devicePixelRatio'];
            markFake(dprFn, 'get devicePixelRatio');
            Object.defineProperty(window, 'devicePixelRatio', {{ get: dprFn, configurable: true }});
          }} catch (_) {{}}

          {timezone_block}
        }})();
        "#,
        ua = ua,
        platform = platform,
        primary_lang = primary_lang,
        langs_json = langs_json,
        hw_conc = fingerprint.hardware_concurrency,
        touch = fingerprint.max_touch_points,
        sw = fingerprint.screen_width,
        sh = fingerprint.screen_height,
        cd = fingerprint.color_depth,
        dpr = fingerprint.device_pixel_ratio,
        timezone_block = timezone_block,
    )
}

/// Generate the enhanced privacy script for a profile.
pub fn enhanced_privacy_script(
    profile_id: &str,
    fingerprint: Option<&FingerprintProfile>,
) -> String {
    let seed = stable_seed(&format!(
        "{}:{}:enhanced-privacy",
        profile_id,
        fingerprint.map(|f| f.preset_id.as_str()).unwrap_or("safari")
    ));
    let max_touch = fingerprint.map(|f| f.max_touch_points).unwrap_or(0);
    let (orientation_type, orientation_angle) = if let Some(f) = fingerprint {
        if f.screen_height >= f.screen_width {
            ("portrait-primary", 0)
        } else {
            ("landscape-primary", 90)
        }
    } else {
        ("portrait-primary", 0)
    };
    // Safari on Apple Silicon always reports "Apple GPU" regardless of touch
    let webgl_renderer = "Apple GPU";
    let orientation_type_json = json_literal(orientation_type);

    format!(
        r#"
        (() => {{
          if (window.__wkEnhancedPrivacy) return;
          try {{
            Object.defineProperty(window, '__wkEnhancedPrivacy', {{ value: true, configurable: false, writable: false }});
          }} catch (_) {{}}

          const seed = {seed};
          const maxTouchPoints = {max_touch};
          const markFake = window.__wkMarkNative || ((fn) => fn);

          const defGetter = (obj, key, val, getterName) => {{
            try {{
              const fn = {{ [getterName]: function () {{ return val; }} }}[getterName];
              markFake(fn, getterName);
              Object.defineProperty(obj, key, {{ get: fn, configurable: true }});
            }} catch (_) {{}}
          }};
          const defValue = (obj, key, val) => {{
            try {{ Object.defineProperty(obj, key, {{ value: val, configurable: true, writable: false }}); }} catch (_) {{}}
          }};
          const wrap = (target, key, factory, fakeName) => {{
            try {{
              const original = target[key];
              if (typeof original !== 'function') return null;
              const replacement = factory(original);
              if (typeof replacement !== 'function') return null;
              markFake(replacement, fakeName || key);
              target[key] = replacement;
              return original;
            }} catch (_) {{ return null; }}
          }};
          const noise = (i) => {{
            let x = (seed + Math.imul(i + 1, 374761393)) | 0;
            x = Math.imul(x ^ (x >>> 13), 1274126177);
            return ((x ^ (x >>> 16)) & 1) ? 1 : -1;
          }};

          try {{
            if ('userAgentData' in navigator || 'userAgentData' in Navigator.prototype) {{
              defGetter(Navigator.prototype, 'userAgentData', undefined, 'get userAgentData');
            }}
          }} catch (_) {{}}
          try {{
            if ('connection' in navigator || 'connection' in Navigator.prototype) {{
              defGetter(Navigator.prototype, 'connection', undefined, 'get connection');
            }}
          }} catch (_) {{}}

          if (maxTouchPoints > 0) {{
            try {{
              if (!('ontouchstart' in window)) defGetter(window, 'ontouchstart', null, 'get ontouchstart');
              if (!window.TouchEvent && window.UIEvent) defValue(window, 'TouchEvent', window.UIEvent);
            }} catch (_) {{}}
            try {{
              const origMatchMedia = window.matchMedia;
              if (typeof origMatchMedia === 'function') {{
                const touchOverrides = [
                  {{ re: /\\(\\s*hover\\s*:\\s*hover\\s*\\)/i, value: false }},
                  {{ re: /\\(\\s*hover\\s*:\\s*none\\s*\\)/i, value: true }},
                  {{ re: /\\(\\s*any-hover\\s*:\\s*hover\\s*\\)/i, value: false }},
                  {{ re: /\\(\\s*any-hover\\s*:\\s*none\\s*\\)/i, value: true }},
                  {{ re: /\\(\\s*pointer\\s*:\\s*fine\\s*\\)/i, value: false }},
                  {{ re: /\\(\\s*pointer\\s*:\\s*coarse\\s*\\)/i, value: true }},
                  {{ re: /\\(\\s*pointer\\s*:\\s*none\\s*\\)/i, value: false }},
                  {{ re: /\\(\\s*any-pointer\\s*:\\s*fine\\s*\\)/i, value: false }},
                  {{ re: /\\(\\s*any-pointer\\s*:\\s*coarse\\s*\\)/i, value: true }}
                ];
                const mediaOverrideCache = new Map();
                function matchMedia(query) {{
                  const result = origMatchMedia.call(this, query);
                  try {{
                    const q = String(query || '');
                    if (!/(hover|pointer)/i.test(q)) return result;
                    let override = mediaOverrideCache.get(q);
                    if (override === undefined) {{
                      override = null;
                      for (const rule of touchOverrides) {{
                        if (rule.re.test(q)) {{
                          override = rule.value;
                          break;
                        }}
                      }}
                      mediaOverrideCache.set(q, override);
                    }}
                    if (override === null) return result;
                    return Object.assign({{}}, result, {{
                      matches: override,
                      media: q,
                      onchange: null,
                      addEventListener: result.addEventListener ? result.addEventListener.bind(result) : function () {{}},
                      removeEventListener: result.removeEventListener ? result.removeEventListener.bind(result) : function () {{}},
                      addListener: result.addListener ? result.addListener.bind(result) : function () {{}},
                      removeListener: result.removeListener ? result.removeListener.bind(result) : function () {{}},
                      dispatchEvent: result.dispatchEvent ? result.dispatchEvent.bind(result) : function () {{ return true; }}
                    }});
                  }} catch (_) {{}}
                  return result;
                }}
                markFake(matchMedia, 'matchMedia');
                window.matchMedia = matchMedia;
              }}
            }} catch (_) {{}}
          }}

          const orientation = Object.freeze({{
            type: {orientation_type_json},
            angle: {orientation_angle},
            onchange: null,
            addEventListener: function () {{}},
            removeEventListener: function () {{}},
            dispatchEvent: function () {{ return true; }}
          }});
          markFake(orientation.addEventListener, 'addEventListener');
          markFake(orientation.removeEventListener, 'removeEventListener');
          markFake(orientation.dispatchEvent, 'dispatchEvent');
          defGetter(Screen.prototype, 'orientation', orientation, 'get orientation');

          try {{
            if (navigator.permissions && navigator.permissions.query) {{
              const originalQuery = navigator.permissions.query.bind(navigator.permissions);
              function query(descriptor) {{
                try {{
                  return originalQuery(descriptor).catch(function () {{ return Promise.resolve({{ state: 'prompt', onchange: null }}); }});
                }} catch (_) {{
                  return Promise.resolve({{ state: 'prompt', onchange: null }});
                }}
              }}
              markFake(query, 'query');
              navigator.permissions.query = query;
            }}
          }} catch (_) {{}}

          try {{
            if (!navigator.mediaDevices) {{
              const emptyEnumerate = function enumerateDevices() {{ return Promise.resolve([]); }};
              markFake(emptyEnumerate, 'enumerateDevices');
              defGetter(Navigator.prototype, 'mediaDevices', {{ enumerateDevices: emptyEnumerate }}, 'get mediaDevices');
            }} else if (navigator.mediaDevices.enumerateDevices) {{
              const originalEnumerateDevices = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
              const wrappedEnumerate = function enumerateDevices() {{
                return originalEnumerateDevices().catch(function () {{ return []; }});
              }};
              markFake(wrappedEnumerate, 'enumerateDevices');
              navigator.mediaDevices.enumerateDevices = wrappedEnumerate;
            }}
          }} catch (_) {{}}

          const maxNoiseWrites = 4096;
          const boundedNoiseStep = (length, minimum) => Math.max(minimum, Math.ceil((length || 0) / maxNoiseWrites));
          const applyCanvasNoise = (imageData, offset) => {{
            try {{
              const data = imageData && imageData.data;
              if (!data) return imageData;
              const step = boundedNoiseStep(data.length, 251);
              for (let i = offset || 0; i < data.length; i += step) {{
                data[i] = Math.max(0, Math.min(255, data[i] + noise(i)));
              }}
            }} catch (_) {{}}
            return imageData;
          }};
          const perturbCanvas = (canvas) => {{
            try {{
              if (!canvas || !canvas.width || !canvas.height) return;
              const ctx = canvas.getContext('2d', {{ willReadFrequently: true }});
              if (!ctx) return;
              const width = Math.min(4, canvas.width);
              const height = Math.min(4, canvas.height);
              const imageData = ctx.getImageData(0, 0, width, height);
              applyCanvasNoise(imageData, 3);
              ctx.putImageData(imageData, 0, 0);
            }} catch (_) {{}}
          }};
          try {{
            const canvas2D = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
            if (canvas2D) {{
              wrap(canvas2D, 'getImageData', function (original) {{
                return function getImageData() {{
                  return applyCanvasNoise(original.apply(this, arguments), 7);
                }};
              }}, 'getImageData');
            }}
            if (window.HTMLCanvasElement) {{
              wrap(HTMLCanvasElement.prototype, 'toDataURL', function (original) {{
                return function toDataURL() {{
                  perturbCanvas(this);
                  return original.apply(this, arguments);
                }};
              }}, 'toDataURL');
              wrap(HTMLCanvasElement.prototype, 'toBlob', function (original) {{
                return function toBlob() {{
                  perturbCanvas(this);
                  return original.apply(this, arguments);
                }};
              }}, 'toBlob');
            }}
          }} catch (_) {{}}

          const patchWebGL = (proto) => {{
            if (!proto) return;
            wrap(proto, 'getParameter', function (original) {{
              return function getParameter(parameter) {{
                if (parameter === 37445) return 'Apple Inc.';
                if (parameter === 37446) return {webgl_renderer:?};
                return original.apply(this, arguments);
              }};
            }}, 'getParameter');
            wrap(proto, 'readPixels', function (original) {{
              return function readPixels() {{
                const result = original.apply(this, arguments);
                try {{
                  const pixels = arguments[6];
                  if (pixels && typeof pixels.length === 'number') {{
                    const step = boundedNoiseStep(pixels.length, 257);
                    for (let i = 0; i < pixels.length; i += step) {{
                      pixels[i] = Math.max(0, Math.min(255, pixels[i] + noise(i + 11)));
                    }}
                  }}
                }} catch (_) {{}}
                return result;
              }};
            }}, 'readPixels');
          }};
          patchWebGL(window.WebGLRenderingContext && WebGLRenderingContext.prototype);
          patchWebGL(window.WebGL2RenderingContext && WebGL2RenderingContext.prototype);

          try {{
            if (window.AudioBuffer && AudioBuffer.prototype.getChannelData) {{
              wrap(AudioBuffer.prototype, 'getChannelData', function (original) {{
                return function getChannelData() {{
                  const data = original.apply(this, arguments);
                  try {{
                    const step = boundedNoiseStep(data.length, 293);
                    for (let i = 0; i < data.length; i += step) {{
                      data[i] += noise(i + 23) * 0.0000001;
                    }}
                  }} catch (_) {{}}
                  return data;
                }};
              }}, 'getChannelData');
            }}
            if (window.AnalyserNode && AnalyserNode.prototype.getFloatFrequencyData) {{
              wrap(AnalyserNode.prototype, 'getFloatFrequencyData', function (original) {{
                return function getFloatFrequencyData(array) {{
                  const result = original.apply(this, arguments);
                  try {{
                    const step = boundedNoiseStep(array.length, 307);
                    for (let i = 0; i < array.length; i += step) {{
                      array[i] += noise(i + 31) * 0.0001;
                    }}
                  }} catch (_) {{}}
                  return result;
                }};
              }}, 'getFloatFrequencyData');
            }}
          }} catch (_) {{}}
        }})();
        "#,
        seed = seed,
        max_touch = max_touch,
        orientation_type_json = orientation_type_json,
        orientation_angle = orientation_angle,
        webgl_renderer = webgl_renderer,
    )
}

// --- Preset catalogs ---

fn mac_presets() -> Vec<FingerprintProfile> {
    let langs: Vec<String> = DEFAULT_ACCEPT_LANGUAGES.iter().map(|s| s.to_string()).collect();
    vec![
        FingerprintProfile {
            preset_id: "mba13".into(),
            display_name: "MacBook Air 13\" M2".into(),
            engine: "safari-webkit".into(),
            user_agent: MAC_SAFARI17_UA.into(),
            accept_languages: langs.clone(),
            platform: "MacIntel".into(),
            hardware_concurrency: 8,
            device_memory: 8,
            screen_width: 1470,
            screen_height: 956,
            color_depth: 24,
            device_pixel_ratio: 2.0,
            max_touch_points: 0,
            timezone: None,
        },
        FingerprintProfile {
            preset_id: "mbp14".into(),
            display_name: "MacBook Pro 14\" M3".into(),
            engine: "safari-webkit".into(),
            user_agent: MAC_SAFARI17_UA.into(),
            accept_languages: langs.clone(),
            platform: "MacIntel".into(),
            hardware_concurrency: 10,
            device_memory: 16,
            screen_width: 1512,
            screen_height: 982,
            color_depth: 24,
            device_pixel_ratio: 2.0,
            max_touch_points: 0,
            timezone: None,
        },
        FingerprintProfile {
            preset_id: "imac5k".into(),
            display_name: "iMac 27\" 5K".into(),
            engine: "safari-webkit".into(),
            user_agent: MAC_SAFARI17_UA.into(),
            accept_languages: langs.clone(),
            platform: "MacIntel".into(),
            hardware_concurrency: 10,
            device_memory: 32,
            screen_width: 2560,
            screen_height: 1440,
            color_depth: 30,
            device_pixel_ratio: 2.0,
            max_touch_points: 0,
            timezone: None,
        },
        FingerprintProfile {
            preset_id: "ipad13".into(),
            display_name: "iPad Pro 12.9\"".into(),
            engine: "safari-webkit".into(),
            user_agent: IPAD_SAFARI17_UA.into(),
            accept_languages: langs.clone(),
            platform: "iPad".into(),
            hardware_concurrency: 8,
            device_memory: 8,
            screen_width: 1024,
            screen_height: 1366,
            color_depth: 24,
            device_pixel_ratio: 2.0,
            max_touch_points: 10,
            timezone: None,
        },
        FingerprintProfile {
            preset_id: "iphone15pro".into(),
            display_name: "iPhone 15 Pro".into(),
            engine: "safari-webkit".into(),
            user_agent: IPHONE_SAFARI17_UA.into(),
            accept_languages: langs.clone(),
            platform: "iPhone".into(),
            hardware_concurrency: 6,
            device_memory: 6,
            screen_width: 393,
            screen_height: 852,
            color_depth: 24,
            device_pixel_ratio: 3.0,
            max_touch_points: 5,
            timezone: None,
        },
    ]
}

fn windows_presets() -> Vec<FingerprintProfile> {
    let langs: Vec<String> = DEFAULT_ACCEPT_LANGUAGES.iter().map(|s| s.to_string()).collect();
    vec![
        FingerprintProfile {
            preset_id: "win-laptop".into(),
            display_name: "Windows 笔记本".into(),
            engine: "chromium".into(),
            user_agent: WIN_CHROME_UA.into(),
            accept_languages: langs.clone(),
            platform: "Win32".into(),
            hardware_concurrency: 8,
            device_memory: 8,
            screen_width: 1920,
            screen_height: 1080,
            color_depth: 24,
            device_pixel_ratio: 1.0,
            max_touch_points: 0,
            timezone: None,
        },
        FingerprintProfile {
            preset_id: "win-desktop".into(),
            display_name: "Windows 台式机".into(),
            engine: "chromium".into(),
            user_agent: WIN_CHROME_UA.into(),
            accept_languages: langs.clone(),
            platform: "Win32".into(),
            hardware_concurrency: 12,
            device_memory: 16,
            screen_width: 2560,
            screen_height: 1440,
            color_depth: 24,
            device_pixel_ratio: 1.0,
            max_touch_points: 0,
            timezone: None,
        },
        FingerprintProfile {
            preset_id: "win-surface".into(),
            display_name: "Surface Pro".into(),
            engine: "chromium".into(),
            user_agent: WIN_CHROME_UA.into(),
            accept_languages: langs.clone(),
            platform: "Win32".into(),
            hardware_concurrency: 8,
            device_memory: 16,
            screen_width: 2880,
            screen_height: 1920,
            color_depth: 24,
            device_pixel_ratio: 2.0,
            max_touch_points: 10,
            timezone: None,
        },
    ]
}

fn linux_presets() -> Vec<FingerprintProfile> {
    let langs: Vec<String> = DEFAULT_ACCEPT_LANGUAGES.iter().map(|s| s.to_string()).collect();
    vec![
        FingerprintProfile {
            preset_id: "linux-laptop".into(),
            display_name: "Linux 笔记本".into(),
            engine: "webkitgtk".into(),
            user_agent: LINUX_WEBKITGTK_UA.into(),
            accept_languages: langs.clone(),
            platform: "Linux x86_64".into(),
            hardware_concurrency: 8,
            device_memory: 8,
            screen_width: 1920,
            screen_height: 1080,
            color_depth: 24,
            device_pixel_ratio: 1.0,
            max_touch_points: 0,
            timezone: None,
        },
        FingerprintProfile {
            preset_id: "linux-desktop".into(),
            display_name: "Linux 台式机".into(),
            engine: "webkitgtk".into(),
            user_agent: LINUX_WEBKITGTK_UA.into(),
            accept_languages: langs.clone(),
            platform: "Linux x86_64".into(),
            hardware_concurrency: 12,
            device_memory: 16,
            screen_width: 2560,
            screen_height: 1440,
            color_depth: 24,
            device_pixel_ratio: 1.0,
            max_touch_points: 0,
            timezone: None,
        },
    ]
}

fn random_mac_fingerprint() -> FingerprintProfile {
    let mut rng = rand::thread_rng();
    let cores = *[4u32, 6, 8, 10, 12].choose(&mut rng).unwrap_or(&8);
    let memory = *[8u32, 16, 32].choose(&mut rng).unwrap_or(&16);
    let (sw, sh) = *[
        (1470u32, 956u32),
        (1512, 982),
        (1920, 1080),
        (2560, 1440),
        (3024, 1964),
    ]
    .choose(&mut rng)
    .unwrap_or(&(1470, 956));
    let langs: Vec<String> = DEFAULT_ACCEPT_LANGUAGES.iter().map(|s| s.to_string()).collect();

    FingerprintProfile {
        preset_id: format!("random-{}", Uuid::new_v4()),
        display_name: "随机：Mac Safari 稳定指纹".into(),
        engine: "safari-webkit".into(),
        user_agent: MAC_SAFARI17_UA.into(),
        accept_languages: langs,
        platform: "MacIntel".into(),
        hardware_concurrency: cores,
        device_memory: memory,
        screen_width: sw,
        screen_height: sh,
        color_depth: 24,
        device_pixel_ratio: 2.0,
        max_touch_points: 0,
        timezone: None,
    }
}

fn random_windows_fingerprint() -> FingerprintProfile {
    let mut rng = rand::thread_rng();
    let cores = *[8u32, 12, 16].choose(&mut rng).unwrap_or(&8);
    let memory = *[8u32, 16, 32].choose(&mut rng).unwrap_or(&16);
    let (sw, sh) = *[
        (1920u32, 1080u32),
        (2560, 1440),
        (1366, 768),
        (3840, 2160),
    ]
    .choose(&mut rng)
    .unwrap_or(&(1920, 1080));
    let langs: Vec<String> = DEFAULT_ACCEPT_LANGUAGES.iter().map(|s| s.to_string()).collect();

    FingerprintProfile {
        preset_id: format!("random-{}", Uuid::new_v4()),
        display_name: "随机：Windows Chromium 稳定指纹".into(),
        engine: "chromium".into(),
        user_agent: WIN_CHROME_UA.into(),
        accept_languages: langs,
        platform: "Win32".into(),
        hardware_concurrency: cores,
        device_memory: memory,
        screen_width: sw,
        screen_height: sh,
        color_depth: 24,
        device_pixel_ratio: rng.gen_range(1.0..=2.0),
        max_touch_points: 0,
        timezone: None,
    }
}

fn random_linux_fingerprint() -> FingerprintProfile {
    let mut rng = rand::thread_rng();
    let cores = *[4u32, 8, 12, 16].choose(&mut rng).unwrap_or(&8);
    let memory = *[8u32, 16, 32].choose(&mut rng).unwrap_or(&16);
    let (sw, sh) = *[
        (1920u32, 1080u32),
        (2560, 1440),
        (1366, 768),
    ]
    .choose(&mut rng)
    .unwrap_or(&(1920, 1080));
    let langs: Vec<String> = DEFAULT_ACCEPT_LANGUAGES.iter().map(|s| s.to_string()).collect();

    FingerprintProfile {
        preset_id: format!("random-{}", Uuid::new_v4()),
        display_name: "随机：Linux WebKitGTK 稳定指纹".into(),
        engine: "webkitgtk".into(),
        user_agent: LINUX_WEBKITGTK_UA.into(),
        accept_languages: langs,
        platform: "Linux x86_64".into(),
        hardware_concurrency: cores,
        device_memory: memory,
        screen_width: sw,
        screen_height: sh,
        color_depth: 24,
        device_pixel_ratio: 1.0,
        max_touch_points: 0,
        timezone: None,
    }
}

// --- Utility functions ---

fn json_literal(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

fn stable_seed(value: &str) -> u32 {
    let mut hash: u32 = 2166136261;
    for byte in value.bytes() {
        hash ^= byte as u32;
        hash = hash.wrapping_mul(16777619);
    }
    if hash == 0 { 1 } else { hash }
}

use uuid::Uuid;

trait ChooseExt<T> {
    fn choose(&self, rng: &mut impl Rng) -> Option<&T>;
}

impl<T> ChooseExt<T> for [T] {
    fn choose(&self, rng: &mut impl Rng) -> Option<&T> {
        if self.is_empty() {
            None
        } else {
            Some(&self[rng.gen_range(0..self.len())])
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_presets_not_empty() {
        let presets = platform_presets();
        assert!(!presets.is_empty());
    }

    #[test]
    fn random_fingerprint_has_valid_fields() {
        let fp = random_fingerprint();
        assert!(fp.preset_id.starts_with("random-"));
        assert!(!fp.user_agent.is_empty());
        assert!(!fp.accept_languages.is_empty());
        assert!(fp.screen_width > 0);
        assert!(fp.screen_height > 0);
        assert!(fp.device_pixel_ratio > 0.0);
    }

    #[test]
    fn preset_by_id_works() {
        let presets = platform_presets();
        let first = &presets[0];
        let found = preset_by_id(&first.preset_id);
        assert!(found.is_some());
        assert_eq!(found.unwrap().preset_id, first.preset_id);
    }

    #[test]
    fn off_preset_not_in_catalog() {
        assert!(preset_by_id(OFF_PRESET_ID).is_none());
    }

    #[test]
    fn fingerprint_script_produces_js() {
        let fp = random_fingerprint();
        let script = fingerprint_script(&fp);
        assert!(script.contains("__wkFingerprint"));
        assert!(script.contains("userAgent"));
    }

    #[test]
    fn enhanced_privacy_script_produces_js() {
        let script = enhanced_privacy_script("test-profile", None);
        assert!(script.contains("__wkEnhancedPrivacy"));
        assert!(script.contains("applyCanvasNoise"));
        assert!(script.contains("maxNoiseWrites"));
        assert!(script.contains("patchWebGL"));
    }

    #[test]
    fn stable_seed_is_deterministic() {
        let a = stable_seed("test:value");
        let b = stable_seed("test:value");
        assert_eq!(a, b);
    }
}
