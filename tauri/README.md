# ChatGPT Tauri

这是一个定制 Rust/Tauri v2 桌面版，用来把 `chatgpt.com` 封装成独立桌面应用。

核心价值：保留 ChatGPT Web 上的模型选择器和进阶 / high 思考强度控制，同时提供独立桌面窗口、独立 WebView 登录态、下载、缩放、单实例等桌面体验。它不绕过 ChatGPT 订阅、额度或账号权限，只是让你在桌面 App 里直接使用网页版能力。

它和 Chrome Launcher 版不同：

```text
Chrome Launcher: Rust 启动器 + 本机 Google Chrome，网页兼容最稳，但 Dock 图标显示 Chrome。
Tauri 版: Rust + Tauri + 系统 WebView，Dock 图标正常，是真正独立 App，并保留 Tauri 面向 macOS、Windows 和 Linux 的跨平台路线。
```

## 目标

- Dock 和窗口显示 `ChatGPT Rust` 图标。
- 用 Tauri v2 直接加载 `https://chatgpt.com/`。
- 使用独立 bundle id 的 WKWebView 持久数据，不和 Safari/Chrome 混用 cookie。
- 登录/OAuth 弹窗优先留在 App 内，避免把登录上下文甩到系统浏览器。
- 外部普通链接交给系统默认浏览器打开。
- 重复启动时聚焦已有窗口。
- 记住主窗口大小和位置；可以手动把外框拖到屏幕边缘，下次打开恢复。
- 不再注入网页缩放；只记外框，不改 ChatGPT 页面比例。
- 拦截 `blob:` / `data:` 下载并写入 `~/Downloads`，补 WKWebView 下载盲点。
- 支持 `Cmd + +/-/0` 缩放，并在缩放后触发 `resize`，规避复杂网页缩放渲染丢元素。
- 生成 macOS `.app` 和 `.dmg`。
- 实测登录、登录态、上传、语音、下载和外链。

## 跨平台路线

Tauri 本身面向 macOS、Windows 和 Linux 桌面应用。本项目保留通用 Rust/Tauri 结构，并把外部链接打开逻辑按平台分支处理；macOS app/DMG 打包脚本放在 `packaging/`，其他桌面平台可沿用标准 Tauri build flow。

## 构建

```bash
npm install
npm run build
npm run build:signed-dmg
```

输出位置：

```text
src-tauri/target/release/bundle/macos/ChatGPT Rust.app
src-tauri/target/release/bundle/dmg/ChatGPT Rust_0.1.0_aarch64.dmg
dist/ChatGPT-Rust-0.1.0-arm64.dmg
```

## 实测清单

```text
1. 正常登录 ChatGPT
2. 关闭重开后登录态仍在
3. Google/Apple/Microsoft 登录跳转可用
4. 文件上传可用
5. 语音/麦克风权限可触发并可用（已实测可输入语音）
6. 下载生成文件可用
7. 外链行为可接受
8. 重复启动不会开一堆主窗口
9. 手动调整外框后，退出重开可恢复窗口大小和位置
```

如果这些都通过，这个 Tauri 版就是更适合日常使用的 Rust 独立 App 方案。若登录、语音或上传有硬伤，保留 Chrome Launcher 版作为满血 Chrome fallback。

> 不要提交 `node_modules/`、`src-tauri/target/`、`dist/`、`backups/` 或 cookie/session 导出文件。
