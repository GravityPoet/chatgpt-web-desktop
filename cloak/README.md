# NoTrace Browser

NoTrace Browser runs ChatGPT Web inside the locally installed CloakBrowser patched Chromium (anti-fingerprint), packaged as a single-tile macOS app.

This route is independent from the existing `swift/` and `tauri/` implementations. It does not use WKWebView, Tauri WebView, Docker, VNC, or CloakBrowser Manager.

## What it is now

The shipping UX is a **Chromium "installed app" (PWA)**, not a custom launcher:

- A single green Dock tile that opens the ChatGPT singleton (Chromium app-mode window) on the cloaked profile.
- One tile only — opening the singleton never spawns a second raw-browser tile.
- "Open the full browser" is reached from inside the singleton window: window **⋮ menu → 在 Chromium 中打开 (Open in Chromium)** — opens the plain Chromium browser (blue icon) on the same profile.
- Multiple identities: Chromium's native profile picker (**添加 / Add**) creates an isolated profile (separate cookie jar), but `--fingerprint` is a **process** flag — profiles opened inside the same running Chromium share one fingerprint, IP and timezone, so they stay linkable by *device* even though cookies are separate. For un-linkable identities use the **multi-account picker** (see below): a separate process per account with a stable per-account seed.
- New accounts created by the multi-account picker get a pinned random fingerprint seed in `.cloak-seed`; different accounts therefore do not share the same device fingerprint.

### Runtime paths

- App bundle (PWA): `~/Applications/Chromium Apps.localized/NoTrace Browser.app`
- App-mode shortcut id: `CrAppModeShortcutID` under the profile
- ChatGPT URL: `https://chatgpt.com/`
- CloakBrowser Chromium: `~/.cloakbrowser/chromium-<version>/Chromium.app/Contents/MacOS/Chromium`
- Profile (cloaked, persistent): `~/Library/Application Support/NoTrace Browser/Profiles/main`

## Create the single-tile app

There is no stable CLI for Chromium's "Install as app", so this step is manual:

1. Open the cloaked profile in a full Chromium window (logged in to ChatGPT).
2. Chromium **⋮ → 更多工具 → 创建快捷方式…** (More tools → Create shortcut…).
3. Name it `NoTrace Browser`, **check 在窗口中打开 (Open as window)**, click 创建.

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

It applies `packaging/icon-green.icns` to `~/Applications/Chromium Apps.localized/NoTrace Browser.app`
via `NSWorkspace setIcon:forFile:` and refreshes the Dock. Verified: the LaunchServices-resolved
icon is full-bleed green and survives a PWA relaunch. Re-run only if a Chromium upgrade recreates
the shim from scratch.

## Microphone, Camera & Passkey (TCC)

CloakBrowser ships an ad-hoc Chromium whose `Info.plist` has no `NSMicrophoneUsageDescription`. macOS TCC terminates the process the instant ChatGPT voice input touches the microphone (`"Chromium" 意外退出`).

The **same TCC rule breaks passkey sign-in**: a WebAuthn *hybrid transport* (phone-QR / caBLE) login touches CoreBluetooth, and with no `NSBluetoothAlwaysUsageDescription` the process is killed mid-flow — so ChatGPT silently falls back to a plugged-in USB security key. (The platform-authenticator / Touch-ID path is a separate limitation: it needs an Apple-granted restricted entitlement an ad-hoc binary cannot self-sign, so `isUVPAA` stays false regardless.)

Inject the usage strings (microphone, camera, **Bluetooth**) and ad-hoc re-sign:

```bash
./packaging/patch-chromium.sh
```

CloakBrowser upgrades replace Chromium and drop the keys again, so re-run after each upgrade — the auto-updater re-applies this patch to every staged candidate. The PWA path's coalition leader differs from a custom launcher's, so verify voice and phone-QR passkey once after any change.

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
Residual gaps depend on the launch path. (1) **timezone ≠ IP** — fixed by the companion extension
above on both paths. (2) WebGL GPU and (3) high-entropy client hints (real OS version, full Chrome
version) are now **masked on the multi-account / picker path** via CloakBrowser's `--fingerprint-gpu-*`
and `--fingerprint-*-version` flags: the GPU reports a per-seed Apple-Silicon Metal string
(`ANGLE (Apple, ANGLE Metal Renderer: Apple M1–M4, Unspecified Version)`, vendor `Google Inc. (Apple)`)
instead of the host's real `Apple M4 Pro`, and the client hints report a synthetic macOS version with
a GREASE-correct full-version list. On the **daily PWA path** (2)/(3) stay out of reach — the Dock shim
does not accept launch flags.

Headed audit (`selftest/run-live-challenge-audit.mjs`, account path) is green on bot.sannysoft.com,
BrowserScan ("No Detection"), BrowserLeaks WebRTC (no IP leak), CreepJS (0% headless / 0% stealth, live
Metal GPU string), and deviceandbrowserinfo (CDP / WebGL / client-hint consistency all false). One
honest residual: FingerprintPro still prints the OS as "Mac OS X 10.15.7" — the frozen UA-reduction
token real Chrome also sends — but it computes a visitorId and does not block.

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
**separate** CloakBrowser process per account, and `packaging/pick-account.sh`
opens a native AppKit account picker over it (also wired to the installed
`/Applications/Cloak Picker.app`, detached — no Terminal window). The picker
falls back to the older osascript list if Swift is unavailable, and manages
accounts in place with no terminal — new, rename (keeps the fingerprint), delete,
region label, and the locale / proxy toggles below.

Experimental cross-platform path: `cloak-cli` now provides the Rust behavior-equivalent
account API and launch dry-run, and `cloak-picker/` contains the Tauri day-mode picker.
Build and install the picker app with `packaging/install-cloak-picker-app.sh`; it
rebuilds the Tauri bundle, re-signs it, and atomically replaces
`/Applications/Cloak Picker.app`. `packaging/pick-account.sh` prefers that installed
app and falls back to `target/release/bundle/macos/Cloak Picker.app` for development.
Raw `target/{release,debug}/cloak-picker` binaries are
only used when `CLOAK_PICKER_RAW=1`, because they can open a blank WebView if frontend
assets were not embedded by a Tauri build. Set
`CLOAK_PICKER_TAURI=0` or `CLOAK_PICKER_LEGACY=1` to force the older Swift/osascript
fallback.

Because Cloak Picker **statically links `cloak-core`** (a Cargo path dependency), a change to
`crates/cloak-core` does not reach the installed app until it is rebuilt — and the CloakBrowser
auto-updater rebuilds the engine *binary*, never the Picker. `packaging/check-picker-fresh.sh`
closes that gap: it content-hashes the Rust source the Picker embeds, stamps it at install time, and
on every auto-update tick (and on demand) compares the two. Drift logs a warning plus a macOS
notification carrying the one-line rebuild command; `check-picker-fresh.sh --rebuild` (or
`CLOAK_PICKER_AUTO_REBUILD=1`) rebuilds and re-stamps in place.

The Rust path keeps the current extension contract: `--load-extension` and
`--disable-extensions-except` include the per-account `.cloak-companion`, every
unpacked extension under
`CLOAK_EXTRA_EXTENSIONS_DIR` (default:
`~/Library/Mobile Documents/com~apple~CloudDocs/电脑文件/Google插件/Cloak 浏览器插件`),
and every root-level `.crx` unpacked into
`Accounts/<name>/.cloak-extra-extensions/<slug>`. `沉浸式翻译` is intentionally not
auto-loaded as a default plugin. Real browser launches load the remaining default
plugins; the background selftest intentionally excludes the headless-incompatible
`Chromium Web Store 插件` while keeping the compatible cookie helpers.

Account launches pass CloakBrowser's native fingerprint flags and keep the
companion seed hook enabled for the current local binary, because the regression
selftest proves canvas/getImageData/audio only vary by account seed with that hook
installed. `CLOAK_COMPANION_PAGE_SPOOF=0` (or legacy `CLOAK_JS_FINGERPRINT=0`) can
disable the page-world hook for experiments, but it should not become the default
until this exact patched Chromium binary proves native-only per-seed parity.

Before changing launcher, picker, extension loading, or selftest behavior, run:

```bash
packaging/verify-challenge-contract.sh
```

That contract check uses a temporary account directory, verifies the current
CloakBrowser binary hash, asserts Rust and Bash dry-run challenge flags/default
extensions, confirms `沉浸式翻译` is not default-loaded, and runs the pair-mode
headless privacy selftest.

For headed/live detection-site audits, use:

```bash
node selftest/run-live-challenge-audit.mjs --headed --site browserscan --site fingerprintjs
```

The live audit also uses a temporary account directory and the current Rust
launch plan. It records JSON reports under `selftest/live-results/`. Cloudflare
or Turnstile URLs should be passed as `--manual-url <url>` for observation and
screenshots; the audit harness does not auto-click or solve challenges.

Each account gets:

- **Stable per-account fingerprint** — `--fingerprint=<seed>`. Accounts created
  by the picker get a random pinned `.cloak-seed`, so every new account becomes a
  different stable device. Legacy/direct-launched accounts fall back to
  `sha256(name) → 10000–99999`. Honest-Mac platform/GPU
  (`--fingerprint-platform=macos`); faking Windows-on-Mac creates detectable
  contradictions.
- **Own login/storage** — `--user-data-dir` under
  `~/Library/Application Support/NoTrace Browser/Accounts/<name>`, never the daily
  `main` PWA profile.
- **Timezone follows the VPN exit** — the zone is read from the current IP and
  passed as `--fingerprint-timezone` plus `TZ`, so ICU reports it in **both** the
  main thread and Web Workers (a page-world spoof cannot reach workers).
- **Optional locale** — a per-account toggle (picker → ⚙︎ Toggle locale, or
  `LOCALE=1`) sets `--lang`, `--fingerprint-locale`, and `--accept-lang` so
  `navigator.languages` and the Accept-Language header follow the VPN region. Off
  by default (plain en-US is the least-surprising signal, and lookup failure omits
  the flag rather than creating a mismatch).
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
Do not rely on Chromium's native **Install as app** for isolation: `chatgpt.com`
has one fixed installed-app id, so native PWA shims can overwrite each other and
may not preserve process-level fingerprint flags. The isolation boundary is the
account launch itself: `Accounts/<name>` profile + `.cloak-seed` + launch flags.

Done since the first version: clickable profile picker with in-place management,
GeoIP timezone (companion + `TZ`, main thread *and* workers), per-account locale,
**per-account proxy** (no-auth direct, authenticated via the local SOCKS5 relay,
concurrent multi-region), and hands-off CloakBrowser auto-update
(`packaging/update-chromium.sh` + launchd, SHA256-verified, self-test gated with
rollback, now also checking installed-Picker freshness against `cloak-core`). GPU /
client-hint masking is covered on the multi-account picker path via CloakBrowser's
fingerprint flags; it stays out of reach only on the **daily PWA path**, whose Dock
shim does not accept launch flags.
