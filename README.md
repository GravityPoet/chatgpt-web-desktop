# ChatGPT Desktop Web Wrapper

Unofficial desktop wrappers for the ChatGPT web experience.

This project is for people who prefer the ChatGPT web UI but still want a desktop-style app window. A common reason is that the web UI may expose controls earlier or more completely than a native desktop client, such as higher or advanced reasoning controls, while keeping normal browser features like login, file upload, voice permissions, downloads, and external-link handling.

## What This Solves

- Keeps the full ChatGPT web surface in a desktop shell.
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
  Rust + Tauri v2 implementation. Tested on macOS; intended to be a path toward
  Windows and Linux support, but those platforms still need dedicated verification.
```

The Swift version is macOS-only by design. The Tauri version is the better base for cross-platform work, but this repository currently treats macOS as the verified platform.

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

- macOS Swift wrapper: source included, native AppKit/WKWebView path.
- macOS Tauri wrapper: source included, Rust/Tauri v2 path.
- Windows/Linux Tauri builds: not yet verified in this repository.

## Disclaimer

This is an unofficial project and is not affiliated with, endorsed by, or sponsored by OpenAI. ChatGPT, OpenAI, and related marks belong to OpenAI. Do not use OpenAI logos or branding in a way that implies endorsement.
