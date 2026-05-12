# ChatGPT Desktop Web Wrapper

Use ChatGPT Web as a desktop app, so you can choose advanced/high thinking controls when the native app does not expose them.

This project exists for one specific pain point: in the native ChatGPT desktop app, you may not be able to choose the higher thinking-strength mode available on ChatGPT Web. That means you can get stuck with a lighter reasoning mode when you actually want the model to spend more compute on a harder problem and produce a more accurate, more carefully reasoned answer.

This wrapper keeps the full ChatGPT Web experience available inside a dedicated desktop window, including the web model picker and thinking-time controls such as advanced/high-style reasoning choices.

It does not bypass ChatGPT subscriptions, usage limits, or account permissions. It simply wraps the official ChatGPT web app in a desktop shell, using your own ChatGPT account.

## What This Solves

- Restores the practical reason people open ChatGPT Web: choosing a higher thinking-strength mode when the native app does not offer the same control.
- Keeps ChatGPT Web's model picker and advanced/high thinking controls in a desktop app.
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

This is an unofficial project and is not affiliated with, endorsed by, or sponsored by OpenAI. ChatGPT, OpenAI, and related marks belong to OpenAI. References to ChatGPT and OpenAI are used only to describe compatibility with the official ChatGPT web app.
