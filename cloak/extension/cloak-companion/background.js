// Timezone matching — service worker.
//
// The race-free, cold-start-proof path is the declared content scripts
// (seed.js + spoof.js/apply.js, document_start) driven by a localStorage seed.
// This worker only:
//   - auto-detects the IP timezone on first install (when none is chosen),
//   - re-injects already-open tabs immediately when the zone changes,
//   - provides a first-load fallback before the localStorage seed exists,
//   - answers the popup's "detect my IP zone" request.
// The page-visible spoof itself lives in spoof.js (single source of truth).

try { importScripts("browser-identity-worker.js"); } catch (_) {}

const ZONE_RE = /^[A-Za-z]+(?:\/[A-Za-z0-9_+\-]+){1,2}$/;
const BROWSER_IDENTITY_HEADER_RULE_ID = 91001;

chrome.runtime.onInstalled.addListener(init);
chrome.runtime.onStartup.addListener(init);
installBrowserIdentityHeaderRules();

async function init() {
  await installBrowserIdentityHeaderRules();
  let { tz, auto } = await chrome.storage.local.get(["tz", "auto"]);
  if (!tz && auto !== false) {
    const detected = await detectIPTimezone();
    if (detected) { tz = detected; await chrome.storage.local.set({ tz, autoDetected: detected }); }
  }
  if (tz) injectOpenTabs(tz);
}

// Zone changed (popup writes storage.tz): update every open tab now. seed.js will
// refresh the localStorage seed on the next load of each origin.
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.tz && changes.tz.newValue) injectOpenTabs(changes.tz.newValue);
});

// Fallback for the very first load of an origin, before its localStorage seed
// exists (declared apply.js no-ops then). Harmless duplicate once seeded.
chrome.webNavigation.onCommitted.addListener(async (d) => {
  const { tz } = await chrome.storage.local.get("tz");
  if (tz) injectTab({ tabId: d.tabId, frameIds: [d.frameId] }, tz);
});

chrome.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg && msg.type === "detectTZ") { detectIPTimezone().then(reply); return true; }
});

// Inject spoof.js (defines window.__cloakSpoof) then invoke it with tz. Two
// sequential injections so the invoke never races the definition.
async function injectTab(target, tz) {
  if (!ZONE_RE.test(tz)) return;
  try {
    await chrome.scripting.executeScript({ target, world: "MAIN", injectImmediately: true, files: ["spoof.js"] });
    await chrome.scripting.executeScript({
      target, world: "MAIN", injectImmediately: true,
      func: (t) => { if (window.__cloakSpoof) window.__cloakSpoof(t); }, args: [tz],
    });
  } catch (_) { /* chrome:// and other restricted targets: ignore */ }
}

async function injectOpenTabs(tz) {
  try {
    const tabs = await chrome.tabs.query({ url: ["http://*/*", "https://*/*"] });
    for (const t of tabs) injectTab({ tabId: t.id, allFrames: true }, tz);
  } catch (_) {}
}

async function detectIPTimezone() {
  const sources = ["https://ipapi.co/timezone/", "https://worldtimeapi.org/api/ip"];
  for (const url of sources) {
    try {
      const r = await fetch(url, { cache: "no-store" });
      if (!r.ok) continue;
      const body = await r.text();
      const tz = url.includes("worldtimeapi") ? (JSON.parse(body).timezone || "") : body.trim();
      // Strict IANA shape, anchored both ends, so a hostile response cannot smuggle
      // markup/extra data downstream (e.g. America/Argentina/Buenos_Aires).
      if (ZONE_RE.test(tz)) return tz;
    } catch (_) { /* try next */ }
  }
  return null;
}

async function installBrowserIdentityHeaderRules() {
  try {
    const dnr = chrome.declarativeNetRequest;
    const identity = self.__cloakBrowserIdentity;
    if (!dnr || !identity || !identity.userAgent) return;

    const headers = [
      { header: "User-Agent", operation: "set", value: identity.userAgent },
    ];
    const uaData = identity.uaData || {};
    const brands = formatBrands(uaData.brands);
    const fullVersionList = formatBrands(uaData.fullVersionList);
    if (brands) headers.push({ header: "Sec-CH-UA", operation: "set", value: brands });
    headers.push({ header: "Sec-CH-UA-Mobile", operation: "set", value: uaData.mobile ? "?1" : "?0" });
    if (uaData.platform) headers.push({ header: "Sec-CH-UA-Platform", operation: "set", value: quoteHeader(uaData.platform) });
    if (fullVersionList) headers.push({ header: "Sec-CH-UA-Full-Version-List", operation: "set", value: fullVersionList });
    if (uaData.uaFullVersion) headers.push({ header: "Sec-CH-UA-Full-Version", operation: "set", value: quoteHeader(uaData.uaFullVersion) });
    if (uaData.platformVersion) headers.push({ header: "Sec-CH-UA-Platform-Version", operation: "set", value: quoteHeader(uaData.platformVersion) });
    if (uaData.architecture) headers.push({ header: "Sec-CH-UA-Arch", operation: "set", value: quoteHeader(uaData.architecture) });
    if (uaData.bitness) headers.push({ header: "Sec-CH-UA-Bitness", operation: "set", value: quoteHeader(uaData.bitness) });
    if (typeof uaData.model === "string") headers.push({ header: "Sec-CH-UA-Model", operation: "set", value: quoteHeader(uaData.model) });

    await dnr.updateSessionRules({
      removeRuleIds: [BROWSER_IDENTITY_HEADER_RULE_ID],
      addRules: [{
        id: BROWSER_IDENTITY_HEADER_RULE_ID,
        priority: 1,
        action: { type: "modifyHeaders", requestHeaders: headers },
        condition: {
          regexFilter: "^https?://",
          resourceTypes: ["main_frame", "sub_frame", "stylesheet", "script", "image", "font", "xmlhttprequest", "media", "other"],
        },
      }],
    });
  } catch (_) { /* header rules are best-effort; page spoof still applies */ }
}

function quoteHeader(value) {
  return `"${String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
}

function formatBrands(brands) {
  if (!Array.isArray(brands)) return "";
  return brands
    .filter((item) => item && typeof item.brand === "string" && typeof item.version === "string")
    .map((item) => `${quoteHeader(item.brand)};v=${quoteHeader(item.version)}`)
    .join(", ");
}
