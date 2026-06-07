# ChatGPT Cloak

ChatGPT Cloak runs ChatGPT Web inside the locally installed CloakBrowser patched Chromium (anti-fingerprint), packaged as a single-tile macOS app.

This route is independent from the existing `swift/` and `tauri/` implementations. It does not use WKWebView, Tauri WebView, Docker, VNC, or CloakBrowser Manager.

## What it is now

The shipping UX is a **Chromium "installed app" (PWA)**, not a custom launcher:

- A single green Dock tile that opens the ChatGPT singleton (Chromium app-mode window) on the cloaked profile.
- One tile only — opening the singleton never spawns a second raw-browser tile.
- "Open the full browser" is reached from inside the singleton window: window **⋮ menu → 在 Chromium 中打开 (Open in Chromium)** — opens the plain Chromium browser (blue icon) on the same profile.
- Multiple identities: Chromium's native profile picker (**添加 / Add**) creates an isolated profile (separate cookie jar), but `--fingerprint` is a **process** flag — profiles opened inside the same running Chromium share one fingerprint, IP and timezone, so they stay linkable by *device* even though cookies are separate. For un-linkable identities use the **multi-account picker** (see below): a separate process per account with a stable per-account seed.

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

## Multi-account identities (picker)

For more than one ChatGPT account, the strong path is **not** the native profile
switcher (those profiles share one process → one fingerprint/IP/timezone, so they
stay linkable by device). Instead `packaging/launch-account.sh <name>` launches a
**separate** CloakBrowser process per account, and `packaging/pick-account.sh` is
a clickable osascript list over it (also wired to a double-clickable
`~/Desktop/Cloak 账号.app`, Chromium icon, detached — no Terminal window). The list
also manages accounts in place with no terminal — new, rename (keeps the
fingerprint), delete, region label, and the locale / proxy toggles below.

Each account gets:

- **Stable per-account fingerprint** — `--fingerprint=<seed>`, seed derived from
  the name (`sha256(name) → 10000–99999`), so one account always rebuilds the same
  device and different accounts differ. Honest-Mac platform/GPU
  (`--fingerprint-platform=macos`); faking Windows-on-Mac creates detectable
  contradictions.
- **Own login/storage** — `--user-data-dir` under
  `~/Library/Application Support/ChatGPT Cloak/Accounts/<name>`, never the daily
  `main` PWA profile.
- **Timezone follows the VPN exit** — the zone is read from the current IP and
  exported via `TZ`, so ICU reports it in **both** the main thread and Web Workers
  (a page-world spoof cannot reach workers).
- **Optional locale** — a per-account toggle (picker → ⚙︎ Toggle locale, or
  `LOCALE=1`) sets `--accept-lang` so `navigator.languages` and the Accept-Language
  header follow the VPN region. Off by default (plain en-US is the least-surprising
  signal, and lookup failure omits the flag rather than creating a mismatch).
- **Optional per-account proxy** — set/clear from the picker (🌐) or by writing a
  URL to `Accounts/<name>/.cloak-proxy` (chmod 600). A no-auth proxy is handed to
  `--proxy-server` directly; an **authenticated** one (`scheme://user:pass@host:port`)
  is bridged through a local no-auth SOCKS5 relay (`packaging/proxy-relay.py`),
  because Chromium has no SOCKS5 auth of its own. Remote DNS is preserved through the
  proxy (no OS-resolver leak), and the relay is torn down when the browser quits.

Accounts that rely on the **system VPN** (no per-account proxy) are **sequential** —
switch the VPN to the account's region before launching, one at a time. Accounts that
carry **their own proxy** can run **concurrently**, each pinned to its own exit.

> This whole layer is **orchestration on the stock CloakBrowser binary** — it adds
> no binary patches, only per-account launch flags + env. All anti-fingerprint
> strength is CloakBrowser's compiled-in C++ patches; remove these scripts and the
> stealth is unchanged, remove CloakBrowser and the scripts do nothing.

## In-repo launcher (not installed)

`Sources/ChatGPTCloakLauncher/` and `packaging/make-app.sh` build a Swift launcher that spawns the cloaked Chromium with custom flags/env. It is **not** the shipping UX (the PWA is), but it is retained as the path for env/flag-based stealth launching (timezone, proxy, WebRTC). `cloakChromiumRelativePath` currently hardcodes the Chromium version and should be made to resolve the newest `~/.cloakbrowser/chromium-*` instead.

## Scope

The daily PWA covers the `main` profile; the picker above covers multi-account.
Done since the first version: clickable profile picker with in-place management,
GeoIP timezone (companion + `TZ`, main thread *and* workers), per-account locale,
**per-account proxy** (no-auth direct, authenticated via the local SOCKS5 relay,
concurrent multi-region), and hands-off CloakBrowser auto-update
(`packaging/update-chromium.sh` + launchd, SHA256-verified, self-test gated with
rollback). Still out of reach on the PWA path: GPU / client-hint masking — that
needs the flag-capable launcher, not the Dock shim.
