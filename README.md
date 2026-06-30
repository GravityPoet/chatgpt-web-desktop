# ChatGPT Web Desktop

Languages: English | [简体中文](README.zh-CN.md)

Use ChatGPT Web as a desktop app with isolated profiles, web-first feature parity, and lightweight native desktop integration.

This project started from one specific pain point: ChatGPT Web sometimes exposed model or reasoning controls before the native desktop app did. OpenAI's official macOS app has since added more native capabilities, including model selection, Projects, Tasks, Canvas, Work with Apps, and IDE editing, and now targets macOS 14+ on Apple Silicon.

This wrapper is now best understood as a small, auditable WebView desktop shell: it keeps the full ChatGPT Web surface available inside a dedicated window, with separate WebView storage, predictable link/download handling, and optional privacy/profile controls.

It does not bypass ChatGPT subscriptions, usage limits, or account permissions. It simply wraps the official ChatGPT web app in a desktop shell, using your own ChatGPT account.

## What This Solves

- Keeps ChatGPT Web's model picker and web-first controls in a desktop app.
- Provides a macOS 12-compatible Swift implementation for machines that cannot run the current official macOS app requirements.
- Lets you deliberately spend more reasoning effort on coding, analysis, writing, planning, research, and other high-stakes tasks.
- Avoids losing web-only controls just because you prefer a desktop-window workflow.
- Uses a dedicated app window instead of a normal browser tab.
- Keeps its WebView storage separate from Chrome, Safari, and other wrappers.
- Preserves login/OAuth flows inside the app when possible.
- Handles external links through the system browser.
- Adds desktop conveniences such as window restore, single-instance behavior, zoom shortcuts, and download handling.

## Why Use This

Use it when ChatGPT is part of your daily workflow and a normal browser tab is not enough.

- You want access to ChatGPT Web's newest controls without waiting for a native desktop client to match them.
- You want to choose advanced/high thinking for hard work instead of being forced into a faster, lighter default mode.
- You want answers that can be more precise because the model is allowed to spend more effort on difficult prompts.
- You want a focused ChatGPT workspace that does not get buried among browser tabs.
- You want a separate WebView profile, useful for keeping ChatGPT login state isolated from your main browser.
- You want ChatGPT to feel like a real desktop app: Dock/taskbar presence, restored window position, zoom shortcuts, single-instance behavior, and predictable external-link handling.
- You want a lightweight open-source wrapper that does not proxy your traffic, collect your credentials, or replace the official ChatGPT web app.
- You want both a native macOS reference implementation and a Tauri/Rust implementation that can serve as a cross-platform base.

## Good For

- Developers who want stronger reasoning for debugging, architecture review, refactors, and code generation.
- Writers and researchers who want longer, more careful answers without leaving a desktop workspace.
- Power users who rely on ChatGPT Web features but prefer app-like window management.
- People who use multiple browsers or accounts and want a clean, isolated ChatGPT surface.
- Builders who want a small reference project for wrapping a complex web app with Swift/WKWebView or Tauri.

## Implementations

```text
swift/
  Native macOS AppKit + WKWebView implementation.

tauri/
  Rust + Tauri v2 cross-platform desktop implementation.

cloak/
  Multi-account macOS launcher: one isolated CloakBrowser (Chromium) profile per account.
```

The Swift version is a native macOS implementation. The Tauri version is the cross-platform implementation for desktop builds across macOS, Windows, and Linux.

The cloak version targets people who run several ChatGPT accounts and want each one to stay fully separate. Every account gets its own isolated Chromium profile (independent storage and login state) launched through a CloakBrowser build, with a per-account fingerprint seed (navigator/UA/GPU/platform), an optional per-account proxy, and timezone, locale, and WebRTC-IP values derived from that account's own network egress so each identity stays internally consistent. A small Dock picker app lists the accounts and launches the selected one.

## Privacy

The repository does not include personal cookies, session data, tokens, or local browser profiles.

Runtime login state is stored by the operating system WebView at runtime. The Swift app includes an optional cookie import flow for a user-selected local JSON file, but exported cookie files should never be committed or shared.

The Swift app also includes a clear website data action for resetting this app's WebView cookies, login state, cache, localStorage, IndexedDB, service workers, and other local website data before reloading ChatGPT.

The Swift app additionally provides optional, off-by-default fingerprint controls for a consistent per-profile browser identity: a stable Safari-family navigator/screen profile, enhanced-privacy noise for Canvas/WebGL/Audio, and WebRTC leak protection. Independently of those, when the network egress (for example a VPN exit) resolves to a different timezone than the system, the app aligns the page timezone with the exit so the reported timezone stays consistent with the exit IP, without otherwise altering the real Safari fingerprint.

## Build

Swift:

```bash
cd swift
./packaging/make-app.sh
./packaging/make-dmg.sh
```

Tauri:

```bash
cd tauri
npm install
npm run build
npm run build:signed-dmg
```

## Status

- Swift wrapper: native macOS AppKit/WKWebView path; optional per-profile fingerprint controls and VPN-egress timezone alignment.
- Tauri wrapper: Rust/Tauri v2 cross-platform desktop path.
- Cloak launcher: macOS multi-account path; per-account isolated CloakBrowser profile, fingerprint seed, optional proxy, and egress-derived timezone/locale/WebRTC-IP, with a Dock account picker.
- Packaging helpers: macOS app/DMG helpers are included; other desktop targets can use the standard Tauri build flow.

## Disclaimer

This is an unofficial project and is not affiliated with, endorsed by, or sponsored by OpenAI. ChatGPT, OpenAI, and related marks belong to OpenAI. References to ChatGPT and OpenAI are used only to describe compatibility with the official ChatGPT web app.
