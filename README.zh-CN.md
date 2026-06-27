# ChatGPT Web Desktop

语言：[English](README.md) | 简体中文

把 ChatGPT Web 封装成桌面应用，在原生 ChatGPT 桌面 App 没有暴露进阶 / high thinking 控制时，仍然可以使用网页版的模型选择器和更高思考强度选项。

这个项目解决的是一个非常具体的痛点：原生 ChatGPT 桌面 App 有时无法选择 ChatGPT Web 上可用的更高思考强度模式。这样在处理复杂问题时，你可能只能用更轻量的推理模式，无法让模型投入更多计算，给出更准确、更谨慎的答案。

这个 wrapper 会把完整的 ChatGPT Web 体验放进独立桌面窗口，包括网页版模型选择器，以及 advanced / high 风格的 thinking-time 控制。

它不会绕过 ChatGPT 订阅、使用额度或账号权限。它只是用你自己的 ChatGPT 账号，在桌面壳里打开官方 ChatGPT Web。

## 解决什么问题

- 恢复很多人打开 ChatGPT Web 的核心原因：当原生桌面 App 没有提供同等控制时，仍然可以选择更高思考强度。
- 在桌面 App 里保留 ChatGPT Web 的模型选择器和进阶 / high thinking 控制。
- 让你可以主动为代码、分析、写作、规划、研究等高要求任务投入更多推理 effort。
- 不会因为想用桌面窗口工作流，就丢掉网页版独有控制。
- 使用独立应用窗口，而不是普通浏览器标签页。
- WebView 存储与 Chrome、Safari 和其他 wrapper 隔离。
- 尽量在 App 内保留登录 / OAuth 流程。
- 外部链接通过系统浏览器打开。
- 增加桌面便利能力，例如窗口恢复、单实例、缩放快捷键和下载处理。

## 为什么使用它

如果 ChatGPT 是你的日常工作流，而普通浏览器标签页又不够顺手，可以考虑使用它。

- 你想尽快使用 ChatGPT Web 的最新控制项，而不是等待原生桌面客户端跟进。
- 你想在困难任务里选择 advanced / high thinking，而不是被限制在更快但更轻的默认模式。
- 你希望模型被允许投入更多 effort，从而给出更精确的复杂问题答案。
- 你想要一个专注的 ChatGPT 工作窗口，不被浏览器标签页淹没。
- 你想要独立 WebView profile，把 ChatGPT 登录态和主浏览器隔离。
- 你希望 ChatGPT 更像真正的桌面应用：Dock / taskbar、窗口位置恢复、缩放快捷键、单实例和可预测的外链处理。
- 你想要一个轻量开源 wrapper，不代理你的流量，不收集你的凭据，也不替换官方 ChatGPT Web。
- 你想同时保留原生 macOS 参考实现，以及可作为跨平台基础的 Tauri/Rust 实现。

## 适合谁

- 开发者：用于调试、架构审查、重构和代码生成时获得更强推理。
- 写作者和研究者：在桌面工作区内获得更长、更谨慎的回答。
- 重度用户：依赖 ChatGPT Web 功能，但更喜欢应用化窗口管理。
- 多浏览器或多账号用户：想要一个干净、隔离的 ChatGPT 使用面。
- 构建者：想参考如何用 Swift/WKWebView 或 Tauri 包装复杂 Web App。

## 实现版本

```text
swift/
  原生 macOS AppKit + WKWebView 实现。

tauri/
  Rust + Tauri v2 跨平台桌面实现。

cloak/
  多账号 macOS 启动器：每个账号一个隔离的 CloakBrowser（Chromium）profile。
```

Swift 版本是原生 macOS 实现。Tauri 版本是面向 macOS、Windows 和 Linux 桌面构建的跨平台实现。

cloak 版本面向需要同时运行多个 ChatGPT 账号、并希望各账号彻底隔离的用户。每个账号都有独立的 Chromium profile（独立的存储与登录态），通过 CloakBrowser 构建启动，配以每账号的指纹种子（navigator/UA/GPU/platform）、可选的每账号代理，以及由该账号自身网络出口推导的 timezone、locale 和 WebRTC-IP，使每个身份在内部保持一致。一个小型 Dock 选择器 App 列出账号并启动所选账号。

## 隐私

仓库不包含个人 cookie、session 数据、token 或本地浏览器 profile。

运行时登录态由操作系统 WebView 在本机保存。Swift App 包含一个可选 cookie 导入流程，用于用户主动选择本地 JSON 文件；但导出的 cookie 文件绝不能提交或分享。

Swift App 也提供清空网站数据的菜单动作，可以在重新加载 ChatGPT 前重置本 App WebView 保存的 cookie、登录态、缓存、localStorage、IndexedDB、Service Worker 和其他本地网站数据。

Swift App 还提供一组默认关闭的指纹控制项，用于在每个空间维持一致的浏览器身份：稳定的 Safari 家族 navigator/screen 画像、针对 Canvas/WebGL/Audio 的增强隐私扰动，以及 WebRTC 泄露防护。与这些独立：当网络出口（例如 VPN 出口）解析出的时区与系统不同时，App 会把页面时区与出口对齐，使上报时区与出口 IP 保持一致，且不改变其余真实 Safari 指纹。

## 构建

Swift：

```bash
cd swift
./packaging/make-app.sh
./packaging/make-dmg.sh
```

Tauri：

```bash
cd tauri
npm install
npm run build
npm run build:signed-dmg
```

## 状态

- Swift wrapper：原生 macOS AppKit/WKWebView 路线；可选的每空间指纹控制与 VPN 出口时区对齐。
- Tauri wrapper：Rust/Tauri v2 跨平台桌面路线。
- Cloak launcher：macOS 多账号路线；每账号隔离的 CloakBrowser profile、指纹种子、可选代理，以及由出口推导的 timezone/locale/WebRTC-IP，配一个 Dock 账号选择器。
- 打包辅助：已包含 macOS app/DMG 辅助脚本；其他桌面目标可以沿用标准 Tauri build flow。

## 免责声明

这是非官方项目，不隶属于 OpenAI，也未获得 OpenAI 背书、认可或赞助。ChatGPT、OpenAI 及相关标识归 OpenAI 所有。本文中提到 ChatGPT 和 OpenAI，仅用于说明与官方 ChatGPT Web 的兼容性。
