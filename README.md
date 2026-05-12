# ChatGPT Desktop Web Wrapper

Use ChatGPT Web as a desktop app, including the web UI's advanced/high thinking controls.

This project exists for one specific pain point: ChatGPT Web can expose richer reasoning controls than a native desktop client in some setups, including advanced thinking-time / high-effort modes. This wrapper keeps the full web experience available inside a dedicated desktop window, so you can choose the stronger reasoning mode when a task needs more compute and a smarter answer.

It does not bypass ChatGPT subscriptions, usage limits, or account permissions. It simply wraps the official ChatGPT web app in a desktop shell, using your own ChatGPT account.

## What This Solves

- Keeps ChatGPT Web's model picker and advanced/high thinking controls in a desktop app.
- Lets you use deeper reasoning for coding, analysis, writing, planning, research, and other high-stakes tasks.
- Avoids losing web-only controls just because you prefer a desktop-window workflow.
- Uses a dedicated app window instead of a normal browser tab.
- Keeps its WebView storage separate from Chrome, Safari, and other wrappers.
- Preserves login/OAuth flows inside the app when possible.
- Handles external links through the system browser.
- Adds desktop conveniences such as window restore, single-instance behavior, zoom shortcuts, and download handling.

## Implementations

```text
swift/
  Native macOS AppKit + WKWebView implementation.

tauri/
  Rust + Tauri v2 cross-platform desktop implementation.
```

The Swift version is a native macOS implementation. The Tauri version is the cross-platform implementation for desktop builds across macOS, Windows, and Linux.

## Privacy

The repository does not include personal cookies, session data, tokens, or local browser profiles.

Runtime login state is stored by the operating system WebView at runtime. The Swift app includes an optional cookie import flow for a user-selected local JSON file, but exported cookie files should never be committed or shared.

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

- Swift wrapper: native macOS AppKit/WKWebView path.
- Tauri wrapper: Rust/Tauri v2 cross-platform desktop path.
- Packaging helpers: macOS app/DMG helpers are included; other desktop targets can use the standard Tauri build flow.

## Disclaimer

This is an unofficial project and is not affiliated with, endorsed by, or sponsored by OpenAI. ChatGPT, OpenAI, and related marks belong to OpenAI. Do not use OpenAI logos or branding in a way that implies endorsement.
