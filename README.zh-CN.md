<h2 align="center">🌐 <a href="./README.md">Switch to the English version</a></h2>

# ChatGPT Web Desktop

<p align="center">
  <strong>在 2.7 MB 原生桌面 App 中掌控全量思考强度，拒绝被暗中降级模型。</strong><br>
  <em>不再妥协于官方 App 的浅层计算与自动降级。为复杂代码与深度研究强制拉满思考强度 — 封装在极致轻量、隐私隔离的原生 macOS 窗口中（macOS 12+ 通用架构）。</em>
</p>

<p align="center">
  <a href="https://github.com/GravityPoet/chatgpt-web-desktop/releases/latest"><img src="https://img.shields.io/github/v/release/GravityPoet/chatgpt-web-desktop?label=%E6%9C%80%E6%96%B0%E7%89%88%E6%9C%AC&color=007AFF" alt="最新版本"></a>
  <a href="https://github.com/GravityPoet/chatgpt-web-desktop/releases/latest"><img src="https://img.shields.io/badge/macOS-12.0%2B%20Universal-34C759" alt="macOS 12+ 通用架构"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/%E5%BC%80%E6%BA%90%E5%8D%8F%E8%AE%AE-MIT-blue.svg" alt="开源协议: MIT"></a>
</p>

<p align="center">
  <a href="https://github.com/GravityPoet/chatgpt-web-desktop/releases/latest/download/ChatGPT.Swift.dmg">
    <img src="https://img.shields.io/badge/%E7%AB%8B%E5%8D%B3%E4%B8%8B%E8%BD%BD-ChatGPT.Swift.dmg%20(2.7MB)-007AFF?style=for-the-badge&logo=apple&logoColor=white" alt="下载 ChatGPT Swift DMG">
  </a>
</p>

---

## 核心痛点：官方 App 的浅层计算与暗中降级模型

在面对复杂代码重构、系统架构设计、算法推导或深度研究时，**思考深度（Reasoning Effort）是决定回答质量的核心胜负手**。

然而官方桌面 App 与自动化路由往往优先权衡服务端算力成本：
- 提问常常被暗中分流到更轻量、思考时间更短的浅层模式；
- 细粒度的思考强度调节滑块、Extended Thinking 与网页端最新模型选择器经常被隐藏、延迟或受限；
- 在真正需要深度多步推演的关键问题上，容易得到浮于表面的平庸答案。

**ChatGPT Web Desktop 将网页端毫无保留、完全自主的深度推理能力，完整装进仅 2.7 MB 的轻量原生桌面 App。** 思考强度与模型完全由你手动掌控，绝不妥协、绝不被静默降级。

## 痛点对比（Before vs. After）

| 体验维度 | 官方桌面 App / 自动模式标签页 | ChatGPT Web Desktop |
|---|---|---|
| **思考强度控制** | 自动路由至浅层计算；暗中降级以节省算力 | **100% 自主掌控思考强度**：按需强制拉满 high/extended 深度推理 |
| **网页模型同步** | 网页版新控制项延迟或缺失 | **零时差使用**网页最新模型选择器、Canvas、Voice 与 Work 工具 |
| **系统兼容门槛** | 官方 App 强制要求 macOS 14+ Sonoma | **原生支持 macOS 12.0+**（Monterey, Ventura, Sonoma, Sequoia） |
| **安装包与体积** | 常见 Electron 封装动辄 150 MB+ | **~2.7 MB DMG**（Swift 原生通用架构，支持 Intel 与 Apple Silicon） |
| **工作流专注度** | 淹没在 50+ 浏览器标签页中 | **独立 Dock 图标**、自动记忆窗口位置、单实例防重复开启 |
| **上下文快速输入** | 从备忘录手动复制粘贴文本 | **一键读取 Apple Notes 备忘录**（快捷键 `Cmd+Option+N`） |
| **长回答进度感知** | 必须频繁切回标签页查看是否生成完毕 | **后台完成通知**：AI 生成完毕后自动发送 macOS 原生通知 |
| **Cookie 与隐私** | 与主浏览器混用 Cookie，容易被追踪 | **完全独立的 Profile 存储**，默认自动拒绝非必要追踪 Cookie |
| **文件下载支持** | 网页生成的 `blob:` / `data:` 经常在 WebView 卡死 | **原生下载桥接**，自动安全保存至 `~/Downloads` |
| **未发送草稿保护** | 意外刷新或进程崩溃丢失刚写好的长 Prompt | **草稿自动恢复**，重新加载后自动还原输入框内容 |

## 杀手级核心特性

### 1. 思考强度完全自主掌控 — 杜绝被暗中降级模型
完全由你决定模型在困难任务上投入多大的思考算力。直接在界面中自由选择最高思考强度、深度思考模式与专用推理模型，杜绝官方 App 或客户端为节省算力而进行的静默分流与浅层计算。在代码 Debug、复杂重构和学术推导中获得毫无保留的深度逻辑演算。

### 2. 网页版完整能力 + 2.7 MB 极致轻量原生桌面
无需忍受浏览器杂乱的标签页，直接在原生 macOS 窗口中使用模型选择器、思考强度调节、语音输入、Canvas 及 Work。基于 AppKit + WKWebView 构建，体积仅约 2.7 MB，秒速启动，原生兼容 macOS 12+（Apple Silicon 与 Intel）。

### 3. 深度融入 macOS 工作流的原生集成
- **Apple Notes 一键导入（`Cmd+Option+N`）**：在备忘录选中内容后，一键自动提取标题与正文填入 ChatGPT 输入框，免去繁琐复制粘贴。
- **后台完成通知**：处理长文生成或深度思考推理时，切换到其他工作窗口；回答生成完毕后系统自动弹出 macOS 横幅通知。
- **智能下载桥接**：完美支持 ChatGPT 生成的各类文件、代码与图片，自动桥接保存至系统 `~/Downloads` 目录。
- **输入草稿防丢保护**：页面刷新、白屏恢复或 WebKit 渲染进程重启后，自动尝试将未发送的 Prompt 还原到输入框。

### 4. 独立空间与开箱即用的隐私保护
- **独立 Cookie 存储库**：ChatGPT 登录凭证与 Safari、Chrome 完全隔离，多账号互不干扰。
- **默认拒绝追踪 Cookie**：自动配置 OpenAI 官方 Cookie Consent 偏好为拒绝非必要追踪 Cookie，同时保留正常登录态。
- **无中转、无劫持**：所有流量直连 OpenAI 官方服务器，绝不代理流量、不收集密码、不收集任何敏感数据。

## 极简上手（60 秒搞定）

> **前置要求**：macOS 12.0+（Apple Silicon 或 Intel Mac），以及有效的 ChatGPT 账号。

### 方式一：直接下载安装包（推荐）

1. **下载** 最新版 [ChatGPT.Swift.dmg](https://github.com/GravityPoet/chatgpt-web-desktop/releases/latest/download/ChatGPT.Swift.dmg)（约 2.7 MB）。
2. 打开 DMG 文件，将 **ChatGPT Swift** 拖入 `Applications` 应用程序文件夹。
3. 打开 `ChatGPT Swift` 并登录你的 ChatGPT 账号即可使用。

*(注：由于本包使用统一自签名，若 macOS 首次打开时提示未验证开发者，前往“系统设置 > 隐私与安全性”点击“仍要打开”即可)*

### 方式二：从源码构建

```bash
git clone https://github.com/GravityPoet/chatgpt-web-desktop.git
cd chatgpt-web-desktop/swift
./packaging/make-app.sh
```

构建好的通用架构应用位于 `dist/ChatGPT Swift.zip`。

## 适用人群与场景

- **开发者与算法工程师**：在独立、无干扰的桌面窗口中为架构设计、代码审查和复杂 Debug 强制拉满最高推理强度，杜绝静默降级。
- **写作者与研究人员**：通过 Apple Notes 快速导入研究笔记，并在长篇深度回答生成时放心切换窗口，依靠后台通知获知完成状态。
- **仍在 macOS 12 / 13 系统的用户**：无需升级整机系统即可畅享丝滑的 ChatGPT 原生桌面级体验。
- **多账号与注重隐私的用户**：拥有独立的账号 Profile 与 Cookie 存储，杜绝浏览器追踪与数据混杂。

## 仓库内实现路线

- **`swift/`（macOS 主力推荐）**：基于 AppKit + WKWebView 的原生 macOS 封装，提供 `arm64 + x86_64` 通用二进制产物（推荐 Mac 用户直接使用）。
- **`tauri/`（跨平台）**：基于 Rust + Tauri v2 的轻量跨平台桌面封装，面向 macOS、Windows 与 Linux 构建。
- **`cloak/`（多账号隔离）**：面向多账号用户的独立启动器，通过每账号隔离的 Chromium Profile、指纹种子与出口时区推导实现账号环境隔离。

## 隐私承诺与数据安全

- **仅限本机存储**：Session 与 Cookie 均由 macOS 系统底层 WKWebView 安全沙盒保存在本机。
- **零第三方服务器**：所有网络请求直接在你的电脑与 `chatgpt.com` 之间传输，无任何自建代理、无按键记录、无数据收集。
- **官方 Cookie 偏好**：开箱即默认向 OpenAI 提交拒绝非必要追踪 Cookie 偏好。

## 免责声明

本项目为独立开源项目，不隶属于 OpenAI，亦未获得 OpenAI 的认可、背书或赞助。ChatGPT、OpenAI 及相关标识均为 OpenAI 的注册商标。

---

<p align="center">
  <strong>准备好完全掌控 ChatGPT 的深度思考算力了吗？</strong><br><br>
  <a href="https://github.com/GravityPoet/chatgpt-web-desktop/releases/latest/download/ChatGPT.Swift.dmg">
    <img src="https://img.shields.io/badge/%E7%AB%8B%E5%8D%B3%E4%B8%8B%E8%BD%BD-ChatGPT.Swift.dmg%20(2.7MB)-007AFF?style=for-the-badge&logo=apple&logoColor=white" alt="下载 ChatGPT Swift DMG">
  </a>
</p>
