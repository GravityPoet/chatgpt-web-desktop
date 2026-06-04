# ChatGPT Cloak

ChatGPT Cloak runs ChatGPT Web inside the locally installed CloakBrowser patched Chromium (anti-fingerprint), packaged as a single-tile macOS app.

This route is independent from the existing `swift/` and `tauri/` implementations. It does not use WKWebView, Tauri WebView, Docker, VNC, or CloakBrowser Manager.

## What it is now

The shipping UX is a **Chromium "installed app" (PWA)**, not a custom launcher:

- A single green Dock tile that opens the ChatGPT singleton (Chromium app-mode window) on the cloaked profile.
- One tile only — opening the singleton never spawns a second raw-browser tile.
- "Open the full browser" is reached from inside the singleton window: window **⋮ menu → 在 Chromium 中打开 (Open in Chromium)** — opens the plain Chromium browser (blue icon) on the same profile.
- Multiple identities: Chromium's native profile picker (**添加 / Add**) creates an isolated profile (separate cookie jar). The CloakBrowser binary also randomizes the fingerprint seed per launch, so profiles are not linkable by fingerprint.

### Runtime paths

- App bundle (PWA): `~/Applications/Chromium Apps.localized/ChatGPT Cloak.app`
- App-mode shortcut id: `CrAppModeShortcutID` under the profile
- ChatGPT URL: `https://chatgpt.com/`
- CloakBrowser Chromium: `~/.cloakbrowser/chromium-<version>/Chromium.app/Contents/MacOS/Chromium`
- Profile (cloaked, persistent): `~/Library/Application Support/ChatGPT Cloak/Profiles/main`

## Create the single-tile app

There is no stable CLI for Chromium's "Install as app", so this step is manual:

1. Open the cloaked profile in a full Chromium window (logged in to ChatGPT).
2. Chromium **⋮ → 更多工具 → 创建快捷方式…** (More tools → Create shortcut…).
3. Name it `ChatGPT Cloak`, **check 在窗口中打开 (Open as window)**, click 创建.

The bundle appears in `~/Applications/Chromium Apps.localized/` and Launchpad.

## Green icon

Chromium owns the PWA shim's `Contents/Resources/app.icns` and renders it as a small green
badge inset on a **white macOS tile** (and rebuilds it on shim updates). Editing `app.icns`
or the profile's source icon PNGs does **not** produce the full-bleed, Swift-style green icon —
Chrome re-insets it on the next rebuild.

The durable fix is a **Finder custom icon** (`kHasCustomIcon` + the bundle-root `Icon\r`
resource). LaunchServices and the Dock prefer the custom icon over `app.icns`, and it lives at
the bundle root, independent of Chrome's in-place `app.icns` rewrite:

```bash
./packaging/set-pwa-icon.sh
```

It applies `packaging/icon-green.icns` to `~/Applications/Chromium Apps.localized/ChatGPT Cloak.app`
via `NSWorkspace setIcon:forFile:` and refreshes the Dock. Verified: the LaunchServices-resolved
icon is full-bleed green and survives a PWA relaunch. Re-run only if a Chromium upgrade recreates
the shim from scratch.

## Microphone & Camera (Voice)

CloakBrowser ships an ad-hoc Chromium whose `Info.plist` has no `NSMicrophoneUsageDescription`. macOS TCC terminates the process the instant ChatGPT voice input touches the microphone (`"Chromium" 意外退出`).

Inject the usage strings and ad-hoc re-sign:

```bash
./packaging/patch-chromium.sh
```

CloakBrowser upgrades replace Chromium and drop the keys again, so re-run after each upgrade. The PWA path's coalition leader differs from a custom launcher's, so verify voice once after any change.

## Timezone (companion extension)

The cloaked binary does not match the browser timezone to the proxy/IP by itself, and the
`TZ`-env / flag knobs cannot reach the Dock-launched PWA. `extension/cloak-companion/` is an
unpacked MV3 extension that overrides the page-visible timezone (`Intl` + `Date`, DST-correct
and self-consistent) to a chosen zone, and can **auto-match the current IP's zone** — removing
the timezone-vs-IP mismatch that fingerprint / anti-fraud sites flag. It lives in the profile,
so the PWA app window inherits it; no launcher, no flags, single green icon preserved.

Install (ungoogled Chromium has no Web Store — unpacked is the normal path):

1. Open `chrome://extensions` on the `main` profile.
2. Toggle **Developer mode** (top-right).
3. **Load unpacked** → select `extension/cloak-companion`.
4. Click the toolbar icon → **自动匹配当前 IP**, or pick a zone from the list. The page reloads and reports the new zone.

Verified end-to-end: on a Netherlands proxy the extension auto-selected `Europe/Paris` and the
page then reported `Intl` zone Europe/Paris with `getTimezoneOffset` `-120` (was `Asia/Shanghai`).

## Detection status

Tested by driving the cloaked Chromium over CDP (minimal footprint: no `Runtime.enable` /
`Page.enable`) against bot.sannysoft.com, CreepJS, BrowserScan, FingerprintJS, and a Cloudflare
Turnstile page. Pass: `navigator.webdriver` hidden (all sannysoft rows green), `window.chrome`
present, 5 plugins, WebRTC fully blocked (no IP leak), BrowserScan "Bot Detection: No Detection".
Residual gaps: (1) **timezone ≠ IP** — fixed by the companion extension above; (2) WebGL leaks the
real GPU (`Apple M4 Pro`); (3) high-entropy client hints leak the real OS (`Mac OS 26.5.1`) and full
Chrome version. (2)/(3) are launch-flag knobs and remain out of reach on the PWA path.

## Known limitations

- **Page translate is dead.** CloakBrowser is **ungoogled-chromium**: Google domains are
  substituted (`chrome.9oo91e.qjz9zk`) and the Chrome Web Store / translate API are de-integrated
  at the network layer, so the built-in "translate this page" fails. Workaround: sideload a
  translate extension as **unpacked** (no Web Store) into the `main` profile; the app window inherits it.
- **Flag-gated stealth knobs don't reach the PWA.** `--fingerprint-webrtc-ip`, `--fingerprint-*`, `--proxy-server`, and `TZ` env are launch-time and the PWA shim does not accept them. The compiled-in binary patches (canvas / WebGL / audio / `navigator.webdriver` / CDP / TLS) still apply, and timezone is now covered by the companion extension. Remaining GPU / client-hint masking would require launching the engine ourselves (see `Sources/`), not the PWA.

## In-repo launcher (not installed)

`Sources/ChatGPTCloakLauncher/` and `packaging/make-app.sh` build a Swift launcher that spawns the cloaked Chromium with custom flags/env. It is **not** the shipping UX (the PWA is), but it is retained as the path for env/flag-based stealth launching (timezone, proxy, WebRTC). `cloakChromiumRelativePath` currently hardcodes the Chromium version and should be made to resolve the newest `~/.cloakbrowser/chromium-*` instead.

## Scope

First version supports the `main` profile. Future: profile management UI, per-profile proxy, GeoIP/manual timezone, auto-update of the CloakBrowser binary.
