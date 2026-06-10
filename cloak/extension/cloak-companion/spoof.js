// MAIN world. Defines window.__cloakSpoof(tz); does NOT run by itself.
// Re-entrant: the page-visible Intl/Date are wrapped exactly once; a later call
// with a different zone just retargets the shared holder (st.tz), so switching
// zones never stacks Proxies. Used by both apply.js (content script) and the
// service worker's executeScript fallback — single source of truth.
window.__cloakSpoof = function (tz, fpSeed) {
  try {
    if (!tz && !fpSeed) return;
    if (window.__cloakState) {
      if (tz) { window.__cloakState.tz = tz; window.__cloakTZ = tz; }
      if (fpSeed) { window.__cloakState.fpSeed = String(fpSeed); installFingerprintSpoof(window.__cloakState); }
      return;
    }

    var st = (window.__cloakState = { tz: tz || null, fpSeed: fpSeed ? String(fpSeed) : "" });
    if (tz) window.__cloakTZ = tz;
    installBrowserIdentitySpoof();
    installHeadlessSurfaceSpoof();

    var RealDTF = Intl.DateTimeFormat;
    var WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    var MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    var pad = function (n) { return String(n).padStart(2, "0"); };

    function partsIn(date) {
      var dtf = new RealDTF("en-US", {
        timeZone: st.tz, hourCycle: "h23",
        year: "numeric", month: "2-digit", day: "2-digit",
        hour: "2-digit", minute: "2-digit", second: "2-digit",
      });
      var o = {};
      var ps = dtf.formatToParts(date);
      for (var i = 0; i < ps.length; i++) o[ps[i].type] = ps[i].value;
      return o;
    }
    // Minutes east of UTC for `date` in the target zone (DST-correct via real ICU).
    function eastMinutes(date) {
      var p = partsIn(date);
      var asUTC = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
      return Math.round((asUTC - date.getTime()) / 60000);
    }
    function abbr(date) {
      var x = new RealDTF("en-US", { timeZone: st.tz, timeZoneName: "short" })
        .formatToParts(date).find(function (p) { return p.type === "timeZoneName"; });
      return x ? x.value : "";
    }
    function gmt(date) {
      var e = eastMinutes(date), s = e >= 0 ? "+" : "-", a = Math.abs(e);
      return "GMT" + s + pad(Math.floor(a / 60)) + pad(a % 60);
    }

    if (tz) {
      // getTimezoneOffset returns minutes BEHIND UTC (positive when west).
      Date.prototype.getTimezoneOffset = function () {
        return isNaN(this) ? NaN : -eastMinutes(this);
      };

      // Default Intl.DateTimeFormat to the target zone when the caller omits timeZone.
      var handler = {
        construct: function (T, a) { var o = a[1] ? Object.assign({}, a[1]) : {}; if (!o.timeZone) o.timeZone = st.tz; return new T(a[0], o); },
        apply: function (T, _t, a) { var o = a[1] ? Object.assign({}, a[1]) : {}; if (!o.timeZone) o.timeZone = st.tz; return T(a[0], o); },
      };
      Intl.DateTimeFormat = new Proxy(RealDTF, handler);

      // toLocale* default to the target zone too.
      ["toLocaleString", "toLocaleDateString", "toLocaleTimeString"].forEach(function (name) {
        var orig = Date.prototype[name];
        Date.prototype[name] = function (l, o) {
          o = o ? Object.assign({}, o) : {}; if (!o.timeZone) o.timeZone = st.tz;
          return orig.call(this, l, o);
        };
      });

      // String forms reflect the target zone and offset.
      Date.prototype.toString = function () {
        if (isNaN(this)) return "Invalid Date";
        var p = partsIn(this);
        var dow = new Date(Date.UTC(+p.year, +p.month - 1, +p.day)).getUTCDay();
        return WD[dow] + " " + MO[+p.month - 1] + " " + p.day + " " + p.year + " " + p.hour + ":" + p.minute + ":" + p.second + " " + gmt(this) + " (" + abbr(this) + ")";
      };
      Date.prototype.toTimeString = function () {
        if (isNaN(this)) return "Invalid Date";
        var p = partsIn(this);
        return p.hour + ":" + p.minute + ":" + p.second + " " + gmt(this) + " (" + abbr(this) + ")";
      };
      Date.prototype.toDateString = function () {
        if (isNaN(this)) return "Invalid Date";
        var p = partsIn(this);
        var dow = new Date(Date.UTC(+p.year, +p.month - 1, +p.day)).getUTCDay();
        return WD[dow] + " " + MO[+p.month - 1] + " " + p.day + " " + p.year;
      };
    }
    installFingerprintSpoof(st);
  } catch (_) { /* fail open: never break the page */ }
};

/// Synthesize a full browser identity from navigator.userAgent.
/// Used when __cloakBrowserIdentity is not injected (PWA main profile path).
/// Reads the native UA which already reflects the real engine version,
/// so it auto-follows CloakBrowser engine upgrades — zero Rust dependency.
function synthesizeIdentityFromUA() {
  try {
    var ua = navigator.userAgent;
    if (!ua) return null;
    var match = ua.match(/Chrome\/(\d+)/);
    if (!match) return null;
    var major = match[1];
    // Full version from UA: Chrome reports "Chrome/145.0.0.0" (rounded), use that.
    var fullMatch = ua.match(/Chrome\/([\d.]+)/);
    var full = fullMatch ? fullMatch[1] : major + ".0.0.0";
    return {
      userAgent: ua,
      platform: "MacIntel",
      uaData: {
        brands: [
          { brand: "Google Chrome", version: major },
          { brand: "Chromium", version: major },
          { brand: "Not)A;Brand", version: "24" },
        ],
        mobile: false,
        platform: "macOS",
        fullVersionList: [
          { brand: "Google Chrome", version: full },
          { brand: "Chromium", version: full },
          { brand: "Not)A;Brand", version: "24.0.0.0" },
        ],
        uaFullVersion: full,
        platformVersion: "15.5.0",
        architecture: "arm",
        bitness: "64",
        model: "",
      },
    };
  } catch (_) {
    return null;
  }
}

function installBrowserIdentitySpoof() {
  try {
    if (window.__cloakBrowserIdentityInstalled) return;
    var identity = window.__cloakBrowserIdentity || synthesizeIdentityFromUA();
    if (!identity || !identity.userAgent) return;
    window.__cloakBrowserIdentityInstalled = true;

    function clone(value) {
      return value == null ? value : JSON.parse(JSON.stringify(value));
    }
    function defineGetter(obj, name, getter) {
      try { Object.defineProperty(obj, name, { get: getter, configurable: true }); } catch (_) {}
    }

    var navProto = window.Navigator && Navigator.prototype;
    if (navProto) {
      defineGetter(navProto, "userAgent", function () { return identity.userAgent; });
      if (identity.platform) {
        defineGetter(navProto, "platform", function () { return identity.platform; });
      }
    }

    if (identity.uaData && navProto) {
      var uaData = {
        get brands() { return clone(identity.uaData.brands || []); },
        get mobile() { return !!identity.uaData.mobile; },
        get platform() { return identity.uaData.platform || "macOS"; },
        getHighEntropyValues: function (hints) {
          var result = {
            brands: clone(identity.uaData.brands || []),
            mobile: !!identity.uaData.mobile,
            platform: identity.uaData.platform || "macOS",
          };
          var keys = Array.isArray(hints) ? hints : [];
          for (var i = 0; i < keys.length; i++) {
            var key = keys[i];
            if (Object.prototype.hasOwnProperty.call(identity.uaData, key)) {
              result[key] = clone(identity.uaData[key]);
            }
          }
          return Promise.resolve(result);
        },
        toJSON: function () {
          return {
            brands: clone(identity.uaData.brands || []),
            mobile: !!identity.uaData.mobile,
            platform: identity.uaData.platform || "macOS",
          };
        },
      };
      try { Object.defineProperty(uaData.getHighEntropyValues, "name", { value: "getHighEntropyValues" }); } catch (_) {}
      defineGetter(navProto, "userAgentData", function () { return uaData; });
    }
  } catch (_) {}
}

function installHeadlessSurfaceSpoof() {
  try {
    if (window.__cloakHeadlessSurfaceInstalled) return;
    window.__cloakHeadlessSurfaceInstalled = true;

    function defineGetter(obj, name, getter) {
      try { Object.defineProperty(obj, name, { get: getter, configurable: true }); } catch (_) {}
    }
    function defineValue(obj, name, value) {
      try { Object.defineProperty(obj, name, { value: value, configurable: true, writable: false }); } catch (_) {}
    }

    if (typeof window.ContentIndex === "undefined") {
      defineValue(window, "ContentIndex", function ContentIndex() {});
    }

    var navProto = window.Navigator && Navigator.prototype;
    if (typeof window.ContactsManager === "undefined") {
      defineValue(window, "ContactsManager", function ContactsManager() {});
      try {
        Object.defineProperty(window.ContactsManager.prototype, Symbol.toStringTag, {
          value: "ContactsManager",
          configurable: true,
        });
      } catch (_) {}
    }

    if (navProto && !("contacts" in navigator)) {
      var contacts = Object.create(window.ContactsManager ? window.ContactsManager.prototype : null);
      try {
        Object.defineProperties(contacts, {
          getProperties: {
            value: function getProperties() {
              return Promise.resolve(["name", "email", "tel", "address", "icon"]);
            },
            configurable: true,
          },
          select: {
            value: function select() {
              var ErrorCtor = window.DOMException || Error;
              return Promise.reject(new ErrorCtor("Permission denied", "NotAllowedError"));
            },
            configurable: true,
          },
        });
      } catch (_) {
        contacts = {
        getProperties: function () {
          return Promise.resolve(["name", "email", "tel", "address", "icon"]);
        },
        select: function () {
          var ErrorCtor = window.DOMException || Error;
          return Promise.reject(new ErrorCtor("Permission denied", "NotAllowedError"));
        },
        };
      }
      defineGetter(navProto, "contacts", function () { return contacts; });
    }

    var connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    if (connection && typeof connection.downlinkMax === "undefined") {
      defineGetter(connection, "downlinkMax", function () { return 10; });
      var connectionProto = Object.getPrototypeOf(connection);
      if (connectionProto) {
        defineGetter(connectionProto, "downlinkMax", function () { return 10; });
      }
    }
  } catch (_) {}
}

function installFingerprintSpoof(st) {
  try {
    if (!st || !st.fpSeed || window.__cloakFingerprintInstalled) return;
    window.__cloakFingerprintInstalled = true;

    var seed = hashString(st.fpSeed);
    var originals = [];

    function hashString(s) {
      var h = 2166136261 >>> 0;
      for (var i = 0; i < String(s).length; i++) {
        h ^= String(s).charCodeAt(i);
        h = Math.imul(h, 16777619) >>> 0;
      }
      return h >>> 0;
    }
    function noiseFor(label, modulo) {
      if (modulo <= 0) return 0;
      var h = seed ^ hashString(label);
      h = Math.imul(h ^ (h >>> 16), 2246822519) >>> 0;
      h = Math.imul(h ^ (h >>> 13), 3266489917) >>> 0;
      return ((h ^ (h >>> 16)) >>> 0) % modulo;
    }
    function wrap(obj, name, fn) {
      if (!obj || !obj[name] || obj[name].__cloakWrapped) return;
      var orig = obj[name];
      var wrapped = fn(orig);
      try { Object.defineProperty(wrapped, "name", { value: orig.name || name }); } catch (_) {}
      try { Object.defineProperty(wrapped, "__cloakWrapped", { value: true }); } catch (_) {}
      originals.push([wrapped, orig]);
      obj[name] = wrapped;
    }
    var nativeGetImageData = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype.getImageData;
    var nativePutImageData = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype.putImageData;
    function restoreCanvasNoise(ctx, originals) {
      for (var i = originals.length - 1; i >= 0; i--) {
        try { nativePutImageData.call(ctx, originals[i][2], originals[i][0], originals[i][1]); } catch (_) {}
      }
    }
    function applyCanvasNoise(canvas, label) {
      var ctx, originals;
      try {
        if (!canvas || !canvas.width || !canvas.height) return null;
        ctx = canvas.getContext && canvas.getContext("2d");
        if (!ctx || !nativeGetImageData || !nativePutImageData) return null;
        originals = [];
        for (var i = 0; i < 8; i++) {
          var base = label + ":" + i;
          var x = noiseFor(base + ":x:" + canvas.width, canvas.width);
          var y = noiseFor(base + ":y:" + canvas.height, canvas.height);
          var original = nativeGetImageData.call(ctx, x, y, 1, 1);
          var changed = nativeGetImageData.call(ctx, x, y, 1, 1);
          var data = changed.data;
          data[0] = (data[0] + 1 + noiseFor(base + ":r", 7)) & 255;
          data[1] = (data[1] + 1 + noiseFor(base + ":g", 7)) & 255;
          data[2] = (data[2] + 1 + noiseFor(base + ":b", 7)) & 255;
          data[3] = 255;
          originals.push([x, y, original]);
          nativePutImageData.call(ctx, changed, x, y);
        }
        return function () { restoreCanvasNoise(ctx, originals); };
      } catch (_) {
        if (ctx && originals) restoreCanvasNoise(ctx, originals);
        return null;
      }
    }
    function perturbCanvas(canvas, label, cb) {
      var restore = applyCanvasNoise(canvas, label);
      try {
        return cb();
      } finally {
        if (restore) restore();
      }
    }

    wrap(HTMLCanvasElement.prototype, "toDataURL", function (orig) {
      return function () {
        var self = this, args = arguments;
        return perturbCanvas(self, "toDataURL", function () { return orig.apply(self, args); });
      };
    });
    wrap(HTMLCanvasElement.prototype, "toBlob", function (orig) {
      return function () {
        var self = this, args = arguments;
        var restore = applyCanvasNoise(self, "toBlob");
        if (!restore) return orig.apply(self, args);
        if (typeof args[0] === "function") {
          var cb = args[0];
          var next = Array.prototype.slice.call(args);
          next[0] = function () {
            restore();
            return cb.apply(this, arguments);
          };
          try {
            return orig.apply(self, next);
          } catch (e) {
            restore();
            throw e;
          }
        }
        try {
          var result = orig.apply(self, args);
          setTimeout(function () { restore(); }, 0);
          return result;
        } catch (e2) {
          restore();
          throw e2;
        }
      };
    });
    if (window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype) {
      wrap(CanvasRenderingContext2D.prototype, "getImageData", function (orig) {
        return function () {
          var image = orig.apply(this, arguments);
          try {
            var w = Math.max(1, image.width || arguments[2] || 1);
            var h = Math.max(1, image.height || arguments[3] || 1);
            for (var i = 0; i < 8; i++) {
              var base = "getImageData:" + i;
              var px = noiseFor(base + ":x:" + w, w);
              var py = noiseFor(base + ":y:" + h, h);
              var idx = (py * w + px) * 4;
              if (idx + 3 < image.data.length) {
                image.data[idx] = (image.data[idx] + 1 + noiseFor(base + ":r", 7)) & 255;
                image.data[idx + 1] = (image.data[idx + 1] + 1 + noiseFor(base + ":g", 7)) & 255;
                image.data[idx + 2] = (image.data[idx + 2] + 1 + noiseFor(base + ":b", 7)) & 255;
                image.data[idx + 3] = 255;
              }
            }
            for (var j = 0; j < 8 && image.data.length; j++) {
              var sample = (j * 113) % image.data.length;
              image.data[sample] = (image.data[sample] + 1 + noiseFor("getImageData:sample:" + j, 251)) & 255;
            }
          } catch (_) {}
          return image;
        };
      });
    }
    if (window.OffscreenCanvas && OffscreenCanvas.prototype) {
      wrap(OffscreenCanvas.prototype, "convertToBlob", function (orig) {
        return function () {
          return orig.apply(this, arguments);
        };
      });
    }

    var AC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
    if (AC && AC.prototype) {
      wrap(AC.prototype, "startRendering", function (orig) {
        return function () {
          var result = orig.apply(this, arguments);
          return Promise.resolve(result).then(function (buffer) {
            try {
              for (var ch = 0; ch < buffer.numberOfChannels; ch++) {
                var data = buffer.getChannelData(ch);
                var step = 97 + noiseFor("audio:step:" + ch, 29);
                var delta = (noiseFor("audio:delta:" + ch, 2001) - 1000) / 10000000;
                if (data.length) data[0] = data[0] + delta;
                for (var i = noiseFor("audio:start:" + ch, step); i < data.length; i += step) {
                  data[i] = data[i] + delta;
                }
              }
            } catch (_) {}
            return buffer;
          });
        };
      });
    }
  } catch (_) {}
}
