import AppKit
import ChatGPTSwiftWebCore
import Darwin
import Foundation
import OSLog
import Sparkle
import UniformTypeIdentifiers
import UserNotifications
import WebKit

struct CookieIdentity: Hashable {
    let name: String
    let domain: String
    let path: String

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        domain = Self.normalizedDomain(cookie.domain)
        path = cookie.path
    }

    private static func normalizedDomain(_ domain: String) -> String {
        var normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        return normalized
    }
}

struct ExportedBrowserCookie: Codable {
    let domain: String
    let expirationDate: Double?
    let hostOnly: Bool?
    let httpOnly: Bool?
    let name: String
    let path: String
    let sameSite: String?
    let secure: Bool?
    let session: Bool?
    let value: String

    init(
        domain: String,
        expirationDate: Double?,
        hostOnly: Bool?,
        httpOnly: Bool?,
        name: String,
        path: String,
        sameSite: String?,
        secure: Bool?,
        session: Bool?,
        value: String
    ) {
        self.domain = domain
        self.expirationDate = expirationDate
        self.hostOnly = hostOnly
        self.httpOnly = httpOnly
        self.name = name
        self.path = path
        self.sameSite = sameSite
        self.secure = secure
        self.session = session
        self.value = value
    }

    init(cookie: HTTPCookie) {
        self.domain = cookie.domain
        self.name = cookie.name
        self.value = cookie.value
        self.path = cookie.path.isEmpty ? "/" : cookie.path
        self.secure = cookie.isSecure
        self.httpOnly = cookie.isHTTPOnly
        self.session = cookie.isSessionOnly
        self.hostOnly = !cookie.domain.hasPrefix(".")
        if cookie.isSessionOnly {
            self.expirationDate = nil
        } else {
            self.expirationDate = cookie.expiresDate?.timeIntervalSince1970
        }
        self.sameSite = Self.sameSiteString(from: cookie)
    }

    static func sameSiteString(from cookie: HTTPCookie) -> String? {
        if let raw = cookie.properties?[HTTPCookiePropertyKey("SameSite")] as? String {
            switch raw.lowercased() {
            case "lax":
                return "lax"
            case "strict":
                return "strict"
            case "none", "no_restriction":
                return "no_restriction"
            default:
                break
            }
        }
        if #available(macOS 10.15, *) {
            switch cookie.sameSitePolicy {
            case HTTPCookieStringPolicy.sameSiteLax:
                return "lax"
            case HTTPCookieStringPolicy.sameSiteStrict:
                return "strict"
            default:
                return nil
            }
        }
        return nil
    }

}

struct WebProfile: Codable {
    let id: String
    var name: String
    var createdAt: Date
}

enum WebsiteDataCleaner {
    static func removeAllData(from dataStore: WKWebsiteDataStore, completion: @escaping () -> Void) {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let group = DispatchGroup()

        group.enter()
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date(timeIntervalSince1970: 0)) {
            group.leave()
        }

        group.enter()
        dataStore.httpCookieStore.getAllCookies { cookies in
            guard !cookies.isEmpty else {
                group.leave()
                return
            }

            let cookieGroup = DispatchGroup()
            for cookie in cookies {
                cookieGroup.enter()
                dataStore.httpCookieStore.delete(cookie) {
                    cookieGroup.leave()
                }
            }

            cookieGroup.notify(queue: .main) {
                group.leave()
            }
        }

        group.notify(queue: .main, execute: completion)
    }
}

struct ProfileExportDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let sourceProfileID: String
    let name: String
    let homepage: String?
    let fingerprint: FingerprintProfile?
    let fingerprintDisabled: Bool?
    let enhancedPrivacyEnabled: Bool
}

struct FingerprintProfile: Codable {
    let presetID: String
    let displayName: String
    let userAgent: String
    let acceptLanguages: [String]
    let platform: String
    let hardwareConcurrency: Int
    let deviceMemory: Int
    let screenWidth: Int
    let screenHeight: Int
    let colorDepth: Int
    let devicePixelRatio: Double
    let maxTouchPoints: Int
    let timezone: String?
}

/// Resolves the timezone of the current network egress for an explicitly selected fingerprint
/// preset. The native/default profile never consumes this cache, keeping its WebKit characteristics
/// unchanged. Every failure path degrades to nil, and refreshes only affect the next WebView.
enum GeoIPResolver {
    private static let cacheKey = "geoip.exit.timezone"

    private static var endpoints: [(url: URL, timezone: (Any) -> String?)] {
        var list: [(URL, (Any) -> String?)] = []
        if let u = URL(string: "https://ipwho.is/") {
            // ipwho.is: { "timezone": { "id": "America/New_York", ... } }
            list.append((u, { json in
                ((json as? [String: Any])?["timezone"] as? [String: Any])?["id"] as? String
            }))
        }
        if let u = URL(string: "https://ipinfo.io/json") {
            // ipinfo.io: { "timezone": "America/New_York", ... }
            list.append((u, { json in
                (json as? [String: Any])?["timezone"] as? String
            }))
        }
        return list
    }

    static func cachedTimezone() -> String? {
        guard let tz = UserDefaults.standard.string(forKey: cacheKey), isValidTimezone(tz) else {
            return nil
        }
        return tz
    }

    /// Resolve the exit timezone in the background; the completion runs on the main queue with the
    /// resolved timezone (nil on total failure) and whether it differs from the previously cached
    /// value, so a caller can refresh injection only when the exit actually changed.
    static func refresh(completion: ((String?, Bool) -> Void)? = nil) {
        let previous = cachedTimezone()
        DispatchQueue.global(qos: .utility).async {
            resolve(endpointIndex: 0) { resolved in
                if let resolved {
                    UserDefaults.standard.set(resolved, forKey: cacheKey)
                }
                guard let completion else { return }
                let changed = resolved != nil && resolved != previous
                DispatchQueue.main.async { completion(resolved, changed) }
            }
        }
    }

    private static func resolve(endpointIndex: Int, completion: @escaping (String?) -> Void) {
        let endpoints = self.endpoints
        guard endpointIndex < endpoints.count else {
            completion(nil)
            return
        }
        let endpoint = endpoints[endpointIndex]
        var request = URLRequest(url: endpoint.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data),
               let tz = endpoint.timezone(json), isValidTimezone(tz) {
                completion(tz)
            } else {
                resolve(endpointIndex: endpointIndex + 1, completion: completion)
            }
        }.resume()
    }

    private static func isValidTimezone(_ tz: String) -> Bool {
        !tz.isEmpty && tz.count <= 64 && TimeZone(identifier: tz) != nil
    }
}

enum FingerprintCatalog {
    static let offPresetID = "off"
    static let defaultAcceptLanguages = ["zh-CN", "en-US"]

    private static let macSafari17UserAgent = defaultSafariUserAgent
    // iOS/iPadOS 26 freezes the UA OS token at 18_6 (like macOS freezes 10_15_7); the real OS major lives only in Version/ (26.0). Real devices report OS 18_6 — do NOT "correct" it to 26_0, that would be a detectable fake.
    private static let iPadSafari17UserAgent = "Mozilla/5.0 (iPad; CPU OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    private static let iPhoneSafari17UserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    static let presets: [FingerprintProfile] = [
        FingerprintProfile(
            presetID: "mba13",
            displayName: "MacBook Air 13\" M2",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
            platform: "MacIntel",
            hardwareConcurrency: 8,
            deviceMemory: 8,
            screenWidth: 1470,
            screenHeight: 956,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 0,
            timezone: nil
        ),
        FingerprintProfile(
            presetID: "mbp14",
            displayName: "MacBook Pro 14\" M3",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
            platform: "MacIntel",
            hardwareConcurrency: 10,
            deviceMemory: 16,
            screenWidth: 1512,
            screenHeight: 982,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 0,
            timezone: nil
        ),
        FingerprintProfile(
            presetID: "imac5k",
            displayName: "iMac 27\" 5K",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
            platform: "MacIntel",
            hardwareConcurrency: 10,
            deviceMemory: 32,
            screenWidth: 2560,
            screenHeight: 1440,
            colorDepth: 30,
            devicePixelRatio: 2.0,
            maxTouchPoints: 0,
            timezone: nil
        ),
        FingerprintProfile(
            presetID: "ipad13",
            displayName: "iPad Pro 12.9\"",
            userAgent: iPadSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
            platform: "iPad",
            hardwareConcurrency: 8,
            deviceMemory: 8,
            screenWidth: 1024,
            screenHeight: 1366,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 10,
            timezone: nil
        ),
        FingerprintProfile(
            presetID: "iphone15pro",
            displayName: "iPhone 15 Pro",
            userAgent: iPhoneSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
            platform: "iPhone",
            hardwareConcurrency: 6,
            deviceMemory: 6,
            screenWidth: 393,
            screenHeight: 852,
            colorDepth: 24,
            devicePixelRatio: 3.0,
            maxTouchPoints: 5,
            timezone: nil
        ),
    ]

    static func preset(for id: String) -> FingerprintProfile? {
        presets.first { $0.presetID == id }
    }

    static func randomProfile() -> FingerprintProfile {
        randomMacProfile()
    }

    static func privacyAssessment(
        fingerprint: FingerprintProfile?,
        enhancedPrivacyEnabled: Bool,
        webRTCProtectionEnabled: Bool
    ) -> String {
        var lines: [String] = []
        if let fingerprint {
            lines.append("推荐基线：开启，当前空间固定为 \(fingerprint.displayName)")
            let issues = consistencyIssues(for: fingerprint)
            if issues.isEmpty {
                lines.append("Safari 一致性：通过基础检查")
            } else {
                lines.append("Safari 一致性：需注意 " + issues.joined(separator: "；"))
            }
        } else {
            lines.append("推荐基线：关闭，当前空间使用真实默认 Safari/WebKit 指纹")
        }
        lines.append("增强隐私：\(enhancedPrivacyEnabled ? "开启，Canvas/WebGL/Audio 等使用稳定扰动" : "关闭，JS 层高熵指纹暴露更多")")
        lines.append("WebRTC：\(webRTCProtectionEnabled ? "已屏蔽构造器和设备枚举" : "关闭，可能暴露本机网络和设备枚举")")
        lines.append("不可控残余：TLS/HTTP2/Worker/字体/GPU/IP/行为模式仍不能保证伪装成另一台真实设备")
        return lines.joined(separator: "\n")
    }

    private static func consistencyIssues(for fingerprint: FingerprintProfile) -> [String] {
        var issues: [String] = []
        let ua = fingerprint.userAgent
        let isSafariFamily = ua.contains("AppleWebKit")
            && ua.contains("Safari")
            && !ua.contains("Chrome")
            && !ua.contains("Firefox")
            && !ua.contains("Edg")
        if !isSafariFamily {
            issues.append("UA 不是 Safari/WebKit 家族")
        }
        if ua.contains("Macintosh") && fingerprint.platform != "MacIntel" {
            issues.append("Mac UA 与 platform 不一致")
        }
        if ua.contains("iPhone") && (fingerprint.platform != "iPhone" || fingerprint.maxTouchPoints == 0) {
            issues.append("iPhone UA 与触控/platform 不一致")
        }
        if ua.contains("iPad") && fingerprint.maxTouchPoints == 0 {
            issues.append("iPad UA 缺少触控能力")
        }
        if fingerprint.maxTouchPoints == 0 && (fingerprint.platform == "iPhone" || fingerprint.platform == "iPad") {
            issues.append("移动 platform 缺少触控能力")
        }
        if fingerprint.devicePixelRatio < 1.0 || fingerprint.devicePixelRatio > 3.0 {
            issues.append("DPR 超出常见 Safari 设备范围")
        }
        if fingerprint.screenWidth < 320 || fingerprint.screenHeight < 480 {
            issues.append("屏幕尺寸过小")
        }
        return issues
    }

    /// 指纹脚本使用的时区对齐片段。默认 Profile 不调用它，以保持原生 WebKit 特征稳定。
    private static func timezoneAlignmentBlock(timezone: String) -> String {
        return """
          try {
            const OrigDTF = Intl.DateTimeFormat;
            const TZ = \(jsonLiteral(timezone));
            function DateTimeFormat(locales, options) {
              const o = Object.assign({}, options || {});
              if (!o.timeZone) o.timeZone = TZ;
              return new OrigDTF(locales, o);
            }
            DateTimeFormat.prototype = OrigDTF.prototype;
            for (const k of ['supportedLocalesOf']) {
              if (typeof OrigDTF[k] === 'function') {
                DateTimeFormat[k] = OrigDTF[k].bind(OrigDTF);
                markFake(DateTimeFormat[k], k);
              }
            }
            markFake(DateTimeFormat, 'DateTimeFormat');
            Intl.DateTimeFormat = DateTimeFormat;
            const origResolved = Object.getOwnPropertyDescriptor(OrigDTF.prototype, 'resolvedOptions');
            if (origResolved && typeof origResolved.value === 'function') {
              const origFn = origResolved.value;
              function resolvedOptions() {
                const r = origFn.call(this);
                r.timeZone = TZ;
                return r;
              }
              markFake(resolvedOptions, 'resolvedOptions');
              Object.defineProperty(OrigDTF.prototype, 'resolvedOptions', { value: resolvedOptions, writable: true, configurable: true });
            }
            const origGetTZO = Date.prototype.getTimezoneOffset;
            function getTimezoneOffset() {
              try {
                const parts = new OrigDTF('en-US', { timeZone: TZ, timeZoneName: 'shortOffset' }).formatToParts(this);
                const tzPart = parts.find(p => p.type === 'timeZoneName');
                if (tzPart && tzPart.value) {
                  const m = tzPart.value.match(/GMT([+-])(\\d+)(?::(\\d+))?/);
                  if (m) {
                    const sign = m[1] === '+' ? -1 : 1;
                    const h = parseInt(m[2], 10) || 0;
                    const mi = parseInt(m[3] || '0', 10) || 0;
                    return sign * (h * 60 + mi);
                  }
                }
              } catch (_) {}
              return origGetTZO.call(this);
            }
            markFake(getTimezoneOffset, 'getTimezoneOffset');
            Date.prototype.getTimezoneOffset = getTimezoneOffset;
          } catch (_) {}
        """
    }

    static func script(for fingerprint: FingerprintProfile) -> String {
        let languagesJSON = jsonLiteral(fingerprint.acceptLanguages)
        let primaryLanguage = fingerprint.acceptLanguages.first ?? "en-US"
        // A selected preset's own timezone wins; otherwise fall back to the GeoIP-resolved exit
        // timezone so a VPN user's page timezone matches their exit IP's country (Cloudflare flags
        // IP/timezone mismatch). Nil on both -> no override -> system timezone, unchanged behavior.
        let resolvedTimezone = fingerprint.timezone ?? GeoIPResolver.cachedTimezone()
        let timezoneBlock = resolvedTimezone.map { timezoneAlignmentBlock(timezone: $0) } ?? ""

        return """
        (() => {
          if (window.__wkFingerprint) return;
          try {
            Object.defineProperty(window, '__wkFingerprint', { value: true, configurable: false, writable: false });
          } catch (_) {}

          const markFake = window.__wkMarkNative || ((fn) => fn);

          const defGetter = (obj, key, val, getterName) => {
            try {
              const fn = { [getterName]: function () { return val; } }[getterName];
              markFake(fn, getterName);
              Object.defineProperty(obj, key, { get: fn, configurable: true });
            } catch (_) {}
          };

          const langs = Object.freeze(\(languagesJSON).slice ? \(languagesJSON).slice() : \(languagesJSON));

          defGetter(Navigator.prototype, 'userAgent', \(jsonLiteral(fingerprint.userAgent)), 'get userAgent');
          defGetter(Navigator.prototype, 'vendor', 'Apple Computer, Inc.', 'get vendor');
          defGetter(Navigator.prototype, 'platform', \(jsonLiteral(fingerprint.platform)), 'get platform');
          defGetter(Navigator.prototype, 'language', \(jsonLiteral(primaryLanguage)), 'get language');
          defGetter(Navigator.prototype, 'languages', langs, 'get languages');
          defGetter(Navigator.prototype, 'hardwareConcurrency', \(fingerprint.hardwareConcurrency), 'get hardwareConcurrency');
          defGetter(Navigator.prototype, 'maxTouchPoints', \(fingerprint.maxTouchPoints), 'get maxTouchPoints');
          try {
            if ('webdriver' in navigator || 'webdriver' in Navigator.prototype) {
              defGetter(Navigator.prototype, 'webdriver', undefined, 'get webdriver');
            }
          } catch (_) {}
          try {
            if ('deviceMemory' in navigator || 'deviceMemory' in Navigator.prototype) {
              defGetter(Navigator.prototype, 'deviceMemory', undefined, 'get deviceMemory');
            }
          } catch (_) {}

          defGetter(Screen.prototype, 'width', \(fingerprint.screenWidth), 'get width');
          defGetter(Screen.prototype, 'height', \(fingerprint.screenHeight), 'get height');
          defGetter(Screen.prototype, 'availWidth', \(fingerprint.screenWidth), 'get availWidth');
          defGetter(Screen.prototype, 'availHeight', \(fingerprint.screenHeight), 'get availHeight');
          defGetter(Screen.prototype, 'colorDepth', \(fingerprint.colorDepth), 'get colorDepth');
          defGetter(Screen.prototype, 'pixelDepth', \(fingerprint.colorDepth), 'get pixelDepth');

          try {
            const dprFn = { 'get devicePixelRatio': function () { return \(fingerprint.devicePixelRatio); } }['get devicePixelRatio'];
            markFake(dprFn, 'get devicePixelRatio');
            Object.defineProperty(window, 'devicePixelRatio', { get: dprFn, configurable: true });
          } catch (_) {}

        \(timezoneBlock)
        })();
        """
    }

    static func enhancedPrivacyScript(profileID: String?, fingerprint: FingerprintProfile?) -> String {
        let seed = stableSeed(from: [profileID ?? "incognito", fingerprint?.presetID ?? "safari", "enhanced-privacy"].joined(separator: ":"))
        let maxTouchPoints = fingerprint?.maxTouchPoints ?? 0
        let orientationType: String
        if let fingerprint, fingerprint.screenHeight >= fingerprint.screenWidth {
            orientationType = "portrait-primary"
        } else {
            orientationType = "landscape-primary"
        }
        let orientationAngle = orientationType.hasPrefix("portrait") ? 0 : 90
        // Safari on Apple Silicon always reports "Apple GPU" regardless of touch
        let webGLRenderer = "Apple GPU"

        return """
        (() => {
          if (window.__wkEnhancedPrivacy) return;
          try {
            Object.defineProperty(window, '__wkEnhancedPrivacy', { value: true, configurable: false, writable: false });
          } catch (_) {}

          const seed = \(seed);
          const maxTouchPoints = \(maxTouchPoints);
          const markFake = window.__wkMarkNative || ((fn) => fn);

          const defGetter = (obj, key, val, getterName) => {
            try {
              const fn = { [getterName]: function () { return val; } }[getterName];
              markFake(fn, getterName);
              Object.defineProperty(obj, key, { get: fn, configurable: true });
            } catch (_) {}
          };
          const defValue = (obj, key, val) => {
            try { Object.defineProperty(obj, key, { value: val, configurable: true, writable: false }); } catch (_) {}
          };
          const wrap = (target, key, factory, fakeName) => {
            try {
              const original = target[key];
              if (typeof original !== 'function') return null;
              const replacement = factory(original);
              if (typeof replacement !== 'function') return null;
              markFake(replacement, fakeName || key);
              target[key] = replacement;
              return original;
            } catch (_) { return null; }
          };
          const noise = (i) => {
            let x = (seed + Math.imul(i + 1, 374761393)) | 0;
            x = Math.imul(x ^ (x >>> 13), 1274126177);
            return ((x ^ (x >>> 16)) & 1) ? 1 : -1;
          };

          try {
            if ('userAgentData' in navigator || 'userAgentData' in Navigator.prototype) {
              defGetter(Navigator.prototype, 'userAgentData', undefined, 'get userAgentData');
            }
          } catch (_) {}
          try {
            if ('connection' in navigator || 'connection' in Navigator.prototype) {
              defGetter(Navigator.prototype, 'connection', undefined, 'get connection');
            }
          } catch (_) {}

          if (maxTouchPoints > 0) {
            try {
              if (!('ontouchstart' in window)) defGetter(window, 'ontouchstart', null, 'get ontouchstart');
              if (!window.TouchEvent && window.UIEvent) defValue(window, 'TouchEvent', window.UIEvent);
            } catch (_) {}
            try {
              const origMatchMedia = window.matchMedia;
              if (typeof origMatchMedia === 'function') {
                const touchOverrides = [
                  { re: /\\(\\s*hover\\s*:\\s*hover\\s*\\)/i, value: false },
                  { re: /\\(\\s*hover\\s*:\\s*none\\s*\\)/i, value: true },
                  { re: /\\(\\s*any-hover\\s*:\\s*hover\\s*\\)/i, value: false },
                  { re: /\\(\\s*any-hover\\s*:\\s*none\\s*\\)/i, value: true },
                  { re: /\\(\\s*pointer\\s*:\\s*fine\\s*\\)/i, value: false },
                  { re: /\\(\\s*pointer\\s*:\\s*coarse\\s*\\)/i, value: true },
                  { re: /\\(\\s*pointer\\s*:\\s*none\\s*\\)/i, value: false },
                  { re: /\\(\\s*any-pointer\\s*:\\s*fine\\s*\\)/i, value: false },
                  { re: /\\(\\s*any-pointer\\s*:\\s*coarse\\s*\\)/i, value: true }
                ];
                const mediaOverrideCache = new Map();
                function matchMedia(query) {
                  const result = origMatchMedia.call(this, query);
                  try {
                    const q = String(query || '');
                    if (!/(hover|pointer)/i.test(q)) return result;
                    let override = mediaOverrideCache.get(q);
                    if (override === undefined) {
                      override = null;
                      for (const rule of touchOverrides) {
                        if (rule.re.test(q)) {
                          override = rule.value;
                          break;
                        }
                      }
                      mediaOverrideCache.set(q, override);
                    }
                    if (override === null) return result;
                    return Object.assign({}, result, {
                      matches: override,
                      media: q,
                      onchange: null,
                      addEventListener: result.addEventListener ? result.addEventListener.bind(result) : function () {},
                      removeEventListener: result.removeEventListener ? result.removeEventListener.bind(result) : function () {},
                      addListener: result.addListener ? result.addListener.bind(result) : function () {},
                      removeListener: result.removeListener ? result.removeListener.bind(result) : function () {},
                      dispatchEvent: result.dispatchEvent ? result.dispatchEvent.bind(result) : function () { return true; }
                    });
                  } catch (_) {}
                  return result;
                }
                markFake(matchMedia, 'matchMedia');
                window.matchMedia = matchMedia;
              }
            } catch (_) {}
          }

          const orientation = Object.freeze({
            type: \(jsonLiteral(orientationType)),
            angle: \(orientationAngle),
            onchange: null,
            addEventListener: function () {},
            removeEventListener: function () {},
            dispatchEvent: function () { return true; }
          });
          markFake(orientation.addEventListener, 'addEventListener');
          markFake(orientation.removeEventListener, 'removeEventListener');
          markFake(orientation.dispatchEvent, 'dispatchEvent');
          defGetter(Screen.prototype, 'orientation', orientation, 'get orientation');

          try {
            if (navigator.permissions && navigator.permissions.query) {
              const originalQuery = navigator.permissions.query.bind(navigator.permissions);
              function query(descriptor) {
                try {
                  return originalQuery(descriptor).catch(function () { return Promise.resolve({ state: 'prompt', onchange: null }); });
                } catch (_) {
                  return Promise.resolve({ state: 'prompt', onchange: null });
                }
              }
              markFake(query, 'query');
              navigator.permissions.query = query;
            }
          } catch (_) {}

          try {
            if (!navigator.mediaDevices) {
              const emptyEnumerate = function enumerateDevices() { return Promise.resolve([]); };
              markFake(emptyEnumerate, 'enumerateDevices');
              defGetter(Navigator.prototype, 'mediaDevices', { enumerateDevices: emptyEnumerate }, 'get mediaDevices');
            } else if (navigator.mediaDevices.enumerateDevices) {
              const originalEnumerateDevices = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
              const wrappedEnumerate = function enumerateDevices() {
                return originalEnumerateDevices().catch(function () { return []; });
              };
              markFake(wrappedEnumerate, 'enumerateDevices');
              navigator.mediaDevices.enumerateDevices = wrappedEnumerate;
            }
          } catch (_) {}

          const maxNoiseWrites = 4096;
          const boundedNoiseStep = (length, minimum) => Math.max(minimum, Math.ceil((length || 0) / maxNoiseWrites));
          const applyCanvasNoise = (imageData, offset) => {
            try {
              const data = imageData && imageData.data;
              if (!data) return imageData;
              const step = boundedNoiseStep(data.length, 251);
              for (let i = offset || 0; i < data.length; i += step) {
                data[i] = Math.max(0, Math.min(255, data[i] + noise(i)));
              }
            } catch (_) {}
            return imageData;
          };
          const perturbCanvas = (canvas) => {
            try {
              if (!canvas || !canvas.width || !canvas.height) return;
              const ctx = canvas.getContext('2d', { willReadFrequently: true });
              if (!ctx) return;
              const width = Math.min(4, canvas.width);
              const height = Math.min(4, canvas.height);
              const imageData = ctx.getImageData(0, 0, width, height);
              applyCanvasNoise(imageData, 3);
              ctx.putImageData(imageData, 0, 0);
            } catch (_) {}
          };
          try {
            const canvas2D = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
            if (canvas2D) {
              wrap(canvas2D, 'getImageData', function (original) {
                return function getImageData() {
                  return applyCanvasNoise(original.apply(this, arguments), 7);
                };
              }, 'getImageData');
            }
            if (window.HTMLCanvasElement) {
              wrap(HTMLCanvasElement.prototype, 'toDataURL', function (original) {
                return function toDataURL() {
                  perturbCanvas(this);
                  return original.apply(this, arguments);
                };
              }, 'toDataURL');
              wrap(HTMLCanvasElement.prototype, 'toBlob', function (original) {
                return function toBlob() {
                  perturbCanvas(this);
                  return original.apply(this, arguments);
                };
              }, 'toBlob');
            }
          } catch (_) {}

          const patchWebGL = (proto) => {
            if (!proto) return;
            wrap(proto, 'getParameter', function (original) {
              return function getParameter(parameter) {
                if (parameter === 37445) return 'Apple Inc.';
                if (parameter === 37446) return \(jsonLiteral(webGLRenderer));
                return original.apply(this, arguments);
              };
            }, 'getParameter');
            wrap(proto, 'readPixels', function (original) {
              return function readPixels() {
                const result = original.apply(this, arguments);
                try {
                  const pixels = arguments[6];
                  if (pixels && typeof pixels.length === 'number') {
                    const step = boundedNoiseStep(pixels.length, 257);
                    for (let i = 0; i < pixels.length; i += step) {
                      pixels[i] = Math.max(0, Math.min(255, pixels[i] + noise(i + 11)));
                    }
                  }
                } catch (_) {}
                return result;
              };
            }, 'readPixels');
          };
          patchWebGL(window.WebGLRenderingContext && WebGLRenderingContext.prototype);
          patchWebGL(window.WebGL2RenderingContext && WebGL2RenderingContext.prototype);

          try {
            if (window.AudioBuffer && AudioBuffer.prototype.getChannelData) {
              wrap(AudioBuffer.prototype, 'getChannelData', function (original) {
                return function getChannelData() {
                  const data = original.apply(this, arguments);
                  try {
                    const step = boundedNoiseStep(data.length, 293);
                    for (let i = 0; i < data.length; i += step) {
                      data[i] += noise(i + 23) * 0.0000001;
                    }
                  } catch (_) {}
                  return data;
                };
              }, 'getChannelData');
            }
            if (window.AnalyserNode && AnalyserNode.prototype.getFloatFrequencyData) {
              wrap(AnalyserNode.prototype, 'getFloatFrequencyData', function (original) {
                return function getFloatFrequencyData(array) {
                  const result = original.apply(this, arguments);
                  try {
                    const step = boundedNoiseStep(array.length, 307);
                    for (let i = 0; i < array.length; i += step) {
                      array[i] += noise(i + 31) * 0.0001;
                    }
                  } catch (_) {}
                  return result;
                };
              }, 'getFloatFrequencyData');
            }
          } catch (_) {}
        })();
        """
    }

    private static func randomMacProfile() -> FingerprintProfile {
        let cores = [4, 6, 8, 10, 12].randomElement() ?? 8
        let memory = [8, 16, 32].randomElement() ?? 16
        let screen = [
            (1470, 956),
            (1512, 982),
            (1920, 1080),
            (2560, 1440),
            (3024, 1964),
        ].randomElement() ?? (1470, 956)

        return FingerprintProfile(
            presetID: "random-\(UUID().uuidString)",
            displayName: "随机：Mac Safari 稳定指纹",
            userAgent: macSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
            platform: "MacIntel",
            hardwareConcurrency: cores,
            deviceMemory: memory,
            screenWidth: screen.0,
            screenHeight: screen.1,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 0,
            timezone: nil
        )
    }

    private static func randomIpadProfile() -> FingerprintProfile {
        let cores = [6, 8].randomElement() ?? 8
        let memory = [6, 8].randomElement() ?? 8
        let screen = [
            (820, 1180),
            (834, 1194),
            (1024, 1366),
        ].randomElement() ?? (1024, 1366)

        return FingerprintProfile(
            presetID: "random-\(UUID().uuidString)",
            displayName: "随机：iPad-ish",
            userAgent: iPadSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
            platform: "iPad",
            hardwareConcurrency: cores,
            deviceMemory: memory,
            screenWidth: screen.0,
            screenHeight: screen.1,
            colorDepth: 24,
            devicePixelRatio: 2.0,
            maxTouchPoints: 10,
            timezone: nil
        )
    }

    private static func randomIphoneProfile() -> FingerprintProfile {
        let cores = [4, 6].randomElement() ?? 6
        let memory = [4, 6, 8].randomElement() ?? 6
        let screen = [
            (390, 844),
            (393, 852),
            (430, 932),
        ].randomElement() ?? (393, 852)

        return FingerprintProfile(
            presetID: "random-\(UUID().uuidString)",
            displayName: "随机：iPhone-ish",
            userAgent: iPhoneSafari17UserAgent,
            acceptLanguages: defaultAcceptLanguages,
            platform: "iPhone",
            hardwareConcurrency: cores,
            deviceMemory: memory,
            screenWidth: screen.0,
            screenHeight: screen.1,
            colorDepth: 24,
            devicePixelRatio: 3.0,
            maxTouchPoints: 5,
            timezone: nil
        )
    }

    private static func jsonLiteral<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    private static func stableSeed(from value: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash == 0 ? 1 : hash
    }
}

enum ProfileStore {
    static func ensurePrivacyBaseline() {
        let profiles = loadProfiles()
        for profile in profiles {
            ensureFingerprintBaseline(for: profile.id)
            let enhancedKey = profileEnhancedPrivacyDefaultsPrefix + profile.id
            if UserDefaults.standard.object(forKey: enhancedKey) == nil {
                UserDefaults.standard.set(false, forKey: enhancedKey)
            }
        }
    }

    private static func ensureFingerprintBaseline(for profileID: String) {
        let fingerprintKey = profileFingerprintDefaultsPrefix + profileID
        let disabledKey = profileFingerprintDisabledDefaultsPrefix + profileID
        guard UserDefaults.standard.data(forKey: fingerprintKey) == nil,
              UserDefaults.standard.object(forKey: disabledKey) == nil else {
            return
        }
        disableFingerprint(for: profileID)
    }

    static func loadProfiles() -> [WebProfile] {
        var profiles: [WebProfile] = []
        if let data = UserDefaults.standard.data(forKey: profilesDefaultsKey),
           let decoded = try? JSONDecoder().decode([WebProfile].self, from: data) {
            profiles = decoded
        }
        if !profiles.contains(where: { $0.id == defaultProfileID }) {
            profiles.insert(WebProfile(id: defaultProfileID, name: "默认", createdAt: Date()), at: 0)
            save(profiles)
        }
        return profiles
    }

    static func startupProfileID() -> String {
        let profiles = loadProfiles()
        if let stored = UserDefaults.standard.string(forKey: startupProfileDefaultsKey),
           profiles.contains(where: { $0.id == stored }) {
            return stored
        }
        return defaultProfileID
    }

    @discardableResult
    static func setStartupProfileID(_ id: String) -> Bool {
        var profiles = loadProfiles()
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let profile = profiles.remove(at: idx)
        profiles.insert(profile, at: 0)
        save(profiles)
        UserDefaults.standard.set(id, forKey: startupProfileDefaultsKey)
        return true
    }

    static func clearStartupProfileIfNeeded(_ id: String) {
        guard UserDefaults.standard.string(forKey: startupProfileDefaultsKey) == id else {
            return
        }
        UserDefaults.standard.removeObject(forKey: startupProfileDefaultsKey)
    }

    static func applyStartupProfileIfAvailable() {
        guard let stored = UserDefaults.standard.string(forKey: startupProfileDefaultsKey) else {
            return
        }
        let profiles = loadProfiles()
        guard profiles.contains(where: { $0.id == stored }) else {
            UserDefaults.standard.removeObject(forKey: startupProfileDefaultsKey)
            return
        }
        if stored != defaultProfileID {
            guard #available(macOS 14.0, *) else {
                return
            }
        }
        setCurrentProfileID(stored)
    }

    static func save(_ profiles: [WebProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        UserDefaults.standard.set(data, forKey: profilesDefaultsKey)
    }

    static func resetDefaultProfile() {
        var profiles = loadProfiles()
        profiles.removeAll { $0.id == defaultProfileID }
        profiles.insert(WebProfile(id: defaultProfileID, name: "默认", createdAt: Date()), at: 0)
        save(profiles)
        removeHomepage(for: defaultProfileID)
        disableFingerprint(for: defaultProfileID)
        setEnhancedPrivacyEnabled(false, for: defaultProfileID)
        clearStartupProfileIfNeeded(defaultProfileID)
    }

    static func currentProfileID() -> String {
        UserDefaults.standard.string(forKey: currentProfileDefaultsKey) ?? defaultProfileID
    }

    static func setCurrentProfileID(_ id: String) {
        UserDefaults.standard.set(id, forKey: currentProfileDefaultsKey)
    }

    static func currentProfile() -> WebProfile {
        let profiles = loadProfiles()
        let id = currentProfileID()
        return profiles.first(where: { $0.id == id }) ?? profiles[0]
    }

    static func homepageURL(for profileID: String) -> URL {
        let key = profileHomepageDefaultsPrefix + profileID
        if let raw = UserDefaults.standard.string(forKey: key),
           let url = URL(string: raw),
           url.scheme?.lowercased() == "https" {
            return url
        }
        return chatGPTURL
    }

    static func homepageString(for profileID: String) -> String? {
        UserDefaults.standard.string(forKey: profileHomepageDefaultsPrefix + profileID)
    }

    static func setHomepage(_ url: URL?, for profileID: String) {
        let key = profileHomepageDefaultsPrefix + profileID
        if let url, url.scheme?.lowercased() == "https" {
            UserDefaults.standard.set(url.absoluteString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func removeHomepage(for profileID: String) {
        UserDefaults.standard.removeObject(forKey: profileHomepageDefaultsPrefix + profileID)
    }

    static func isEnhancedPrivacyEnabled(for profileID: String?) -> Bool {
        guard let profileID else {
            return false
        }
        return UserDefaults.standard.bool(forKey: profileEnhancedPrivacyDefaultsPrefix + profileID)
    }

    static func setEnhancedPrivacyEnabled(_ enabled: Bool, for profileID: String) {
        let key = profileEnhancedPrivacyDefaultsPrefix + profileID
        UserDefaults.standard.set(enabled, forKey: key)
    }

    static func fingerprint(for profileID: String?) -> FingerprintProfile? {
        guard let profileID else {
            return nil
        }
        guard !isFingerprintDisabled(for: profileID) else {
            return nil
        }
        let key = profileFingerprintDefaultsPrefix + profileID
        guard let data = UserDefaults.standard.data(forKey: key),
              let fingerprint = try? JSONDecoder().decode(FingerprintProfile.self, from: data) else {
            return nil
        }
        return fingerprint
    }

    static func isFingerprintDisabled(for profileID: String) -> Bool {
        UserDefaults.standard.bool(forKey: profileFingerprintDisabledDefaultsPrefix + profileID)
    }

    static func setFingerprint(_ fingerprint: FingerprintProfile?, for profileID: String) {
        let key = profileFingerprintDefaultsPrefix + profileID
        let disabledKey = profileFingerprintDisabledDefaultsPrefix + profileID
        guard let fingerprint else {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: disabledKey)
            return
        }
        guard let data = try? JSONEncoder().encode(fingerprint) else {
            return
        }
        UserDefaults.standard.set(data, forKey: key)
        UserDefaults.standard.removeObject(forKey: disabledKey)
    }

    static func disableFingerprint(for profileID: String) {
        UserDefaults.standard.removeObject(forKey: profileFingerprintDefaultsPrefix + profileID)
        UserDefaults.standard.set(true, forKey: profileFingerprintDisabledDefaultsPrefix + profileID)
    }
}

enum PrivacySettings {
    static func isWebRTCProtectionRequested() -> Bool {
        if UserDefaults.standard.object(forKey: webRTCProtectionDefaultsKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: webRTCProtectionDefaultsKey)
    }

    static func isWebRTCProtectionEnabled() -> Bool {
        isWebRTCProtectionRequested()
    }

    static func setWebRTCProtectionEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: webRTCProtectionDefaultsKey)
    }

    static func keepThirdPartyLinksInApp() -> Bool {
        if UserDefaults.standard.object(forKey: keepThirdPartyLinksInAppDefaultsKey) == nil {
            return NavigationRules.defaultKeepThirdPartyLinksInApp
        }
        return UserDefaults.standard.bool(forKey: keepThirdPartyLinksInAppDefaultsKey)
    }

    static func setKeepThirdPartyLinksInApp(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keepThirdPartyLinksInAppDefaultsKey)
    }
}

let webRTCBlockerScript = """
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
"""

let privacySignalsScript = """
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
"""

let openAIPasskeyFallbackScript = """
(() => {
  if (window.__wkOpenAIPasskeyFallbackInstalled) return;

  const trustedHost = (host) => {
    const normalized = String(host || '').toLowerCase();
    return normalized === 'chatgpt.com'
      || normalized.endsWith('.chatgpt.com')
      || normalized === 'chat.openai.com'
      || normalized.endsWith('.chat.openai.com')
      || normalized === 'openai.com'
      || normalized.endsWith('.openai.com');
  };

  const authLikePage = () => {
    const host = String(location.hostname || '').toLowerCase();
    const path = String(location.pathname || '').toLowerCase();
    return host === 'auth.openai.com'
      || host === 'auth0.openai.com'
      || host.startsWith('auth.')
      || path.includes('/auth')
      || path.includes('/login')
      || path.includes('/signin')
      || path.includes('/sign-in')
      || path.includes('/credential')
      || path.includes('/passkey')
      || path.includes('/webauthn');
  };

  if (!trustedHost(location.hostname) || !authLikePage() || location.pathname.startsWith('/cdn-cgi/')) return;

  try {
    Object.defineProperty(window, '__wkOpenAIPasskeyFallbackInstalled', { value: true, configurable: false, writable: false });
    Object.defineProperty(window, '__wkOpenAIPasskeyFallbackActive', { value: true, configurable: false, writable: false });
  } catch (_) {}

  const signalFallback = (reason) => {
    try {
      if (!window.__wkOpenAIPasskeyFallbackUsed) {
        Object.defineProperty(window, '__wkOpenAIPasskeyFallbackUsed', { value: true, configurable: true, writable: false });
      }
      window.__wkOpenAIPasskeyFallbackReason = String(reason || 'passkey');
      window.dispatchEvent(new CustomEvent('chatgpt-swift-passkey-fallback', { detail: { reason: window.__wkOpenAIPasskeyFallbackReason } }));
    } catch (_) {}
  };

  const unsupportedError = () => {
    try {
      return new DOMException('Passkey is unavailable in this local WKWebView wrapper. Use another sign-in method.', 'NotAllowedError');
    } catch (_) {
      const error = new Error('Passkey is unavailable in this local WKWebView wrapper. Use another sign-in method.');
      error.name = 'NotAllowedError';
      return error;
    }
  };

  try {
    Reflect.deleteProperty(window, 'PublicKeyCredential');
  } catch (_) {}

  try {
    if ('PublicKeyCredential' in window) {
      Object.defineProperty(window, 'PublicKeyCredential', {
        get: function () {
          signalFallback('PublicKeyCredential');
          return undefined;
        },
        configurable: true
      });
    }
  } catch (_) {}

  try {
    const credentials = navigator.credentials;
    if (!credentials) return;

    const originalGet = typeof credentials.get === 'function' ? credentials.get.bind(credentials) : null;
    const originalCreate = typeof credentials.create === 'function' ? credentials.create.bind(credentials) : null;

    const hasPublicKeyRequest = (options) => {
      try {
        return !!options && typeof options === 'object' && 'publicKey' in options;
      } catch (_) {
        return false;
      }
    };

    const get = function get(options) {
      if (hasPublicKeyRequest(options)) {
        signalFallback('navigator.credentials.get(publicKey)');
        return Promise.reject(unsupportedError());
      }
      return originalGet ? originalGet(options) : Promise.reject(unsupportedError());
    };

    const create = function create(options) {
      if (hasPublicKeyRequest(options)) {
        signalFallback('navigator.credentials.create(publicKey)');
        return Promise.reject(unsupportedError());
      }
      return originalCreate ? originalCreate(options) : Promise.reject(unsupportedError());
    };

    try {
      Object.defineProperty(credentials, 'get', { value: get, configurable: true, writable: true });
    } catch (_) {
      try { credentials.get = get; } catch (_) {}
    }
    try {
      Object.defineProperty(credentials, 'create', { value: create, configurable: true, writable: true });
    } catch (_) {
      try { credentials.create = create; } catch (_) {}
    }
  } catch (_) {}
})();
"""

let passkeyLimitationNoticeScript = """
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

  const fallbackActive = () => !!window.__wkOpenAIPasskeyFallbackActive;
  const fallbackUsed = () => !!window.__wkOpenAIPasskeyFallbackUsed;
  const pageLooksLikeCloudflareChallenge = () => {
    if (location.pathname.startsWith('/cdn-cgi/challenge-platform/')) return true;
    return !!document.querySelector([
      'iframe[src*="challenges.cloudflare.com"]',
      '.cf-turnstile',
      '#cf-challenge-running',
      '#challenge-stage',
      '[data-cf-challenge]'
    ].join(','));
  };
  const authLikePage = () => {
    const host = String(location.hostname || '').toLowerCase();
    const path = String(location.pathname || '').toLowerCase();
    return host === 'auth.openai.com'
      || host === 'auth0.openai.com'
      || host.startsWith('auth.')
      || path.includes('/auth')
      || path.includes('/login')
      || path.includes('/signin')
      || path.includes('/sign-in')
      || path.includes('/credential')
      || path.includes('/passkey')
      || path.includes('/webauthn');
  };

  if (!trustedHost(location.hostname) || !authLikePage() || pageLooksLikeCloudflareChallenge()) return;

  const pageLooksLikePasskey = () => {
    const href = String(location.href || '').toLowerCase();
    const text = String(document.body ? document.body.innerText || '' : '').toLowerCase();
    const urlSignal = href.includes('passkey')
      || href.includes('webauthn')
      || href.includes('security_key')
      || href.includes('publickeycredential')
      || href.includes('credential');
    const textSignal = text.includes('使用密钥继续')
      || text.includes('通行密钥')
      || text.includes('帐户的密钥')
      || text.includes('账户的密钥')
      || text.includes('passkey to continue')
      || text.includes('continue with passkey')
      || text.includes('use your passkey')
      || text.includes('we found a passkey')
      || text.includes('security key to continue')
      || text.includes('use your security key');
    return urlSignal || textSignal;
  };

  const pageLooksLikeAuthFallback = () => {
    const href = String(location.href || '').toLowerCase();
    return fallbackActive() && (
      fallbackUsed()
      || href.includes('auth')
      || href.includes('login')
      || href.includes('signin')
      || href.includes('verify')
      || href.includes('verification')
      || href.includes('continue')
      || href.includes('credential')
      || href.includes('passkey')
      || href.includes('webauthn')
    );
  };

  const showNotice = () => {
    if (pageLooksLikeCloudflareChallenge()) return;
    if (!trustedHost(location.hostname) || (!pageLooksLikePasskey() && !pageLooksLikeAuthFallback())) return;
    if (document.getElementById('chatgpt-swift-passkey-notice')) return;
    if (!document.body || window.__wkPasskeyLimitationNoticeDismissed) return;

    const notice = document.createElement('aside');
    notice.id = 'chatgpt-swift-passkey-notice';
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
    title.textContent = fallbackActive()
      ? (fallbackUsed() ? '已阻止这个页面调用 passkey / WebAuthn。' : '已为这个本地 WKWebView 关闭 passkey / WebAuthn。')
      : '这个本地 WKWebView wrapper 不能使用 chatgpt.com / openai.com 的 Apple 通行密钥。';
    title.style.cssText = 'font-weight:650;margin:0 0 4px';
    notice.appendChild(title);

    const detail = document.createElement('div');
    detail.textContent = fallbackActive()
      ? '请继续使用邮箱验证码、密码或“尝试其他方法”。如必须用通行密钥，请改用 Safari、Chrome 或官方 ChatGPT App。'
      : '请点“尝试其他方法”，或用 Safari、Chrome、官方 ChatGPT App 完成 passkey 登录。';
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

  const schedule = () => window.requestAnimationFrame(showNotice);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', schedule, { once: true });
  } else {
    schedule();
  }
  window.addEventListener('chatgpt-swift-passkey-fallback', schedule);
  window.setTimeout(schedule, 1000);
  window.setTimeout(schedule, 3000);

  try {
    const observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, { childList: true, subtree: true });
    window.setTimeout(() => observer.disconnect(), 15000);
  } catch (_) {}
})();
"""

let nativeShimScript = """
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
"""
