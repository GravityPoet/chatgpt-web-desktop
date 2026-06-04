// MAIN world. Defines window.__cloakSpoof(tz); does NOT run by itself.
// Re-entrant: the page-visible Intl/Date are wrapped exactly once; a later call
// with a different zone just retargets the shared holder (st.tz), so switching
// zones never stacks Proxies. Used by both apply.js (content script) and the
// service worker's executeScript fallback — single source of truth.
window.__cloakSpoof = function (tz) {
  try {
    if (!tz) return;
    if (window.__cloakState) { window.__cloakState.tz = tz; window.__cloakTZ = tz; return; }

    var st = (window.__cloakState = { tz: tz });
    window.__cloakTZ = tz;

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
  } catch (_) { /* fail open: never break the page */ }
};
