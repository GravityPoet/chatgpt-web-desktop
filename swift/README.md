# ChatGPT Swift

原生 macOS AppKit + WKWebView 的 ChatGPT 网页壳，用来在原生 ChatGPT 桌面 App 没有暴露更高思考强度选择时，把 ChatGPT Web 的模型选择器和进阶 / high thinking 控制保留在桌面窗口里，并和 Tauri/Rust 版并排对比。

## 特点

- 独立 bundle id：`local.chatgpt-web.swift`
- 独立 Cookie / WebsiteDataStore，与 Chrome、Tauri 版隔离
- 原生 `NSWindow`，窗口大小和位置由 macOS `setFrameAutosaveName` 记住
- 原生 Dock / App 图标 / 菜单 / 轻量工具栏
- `WKWebView` 加载 `https://chatgpt.com/`
- 可把 Apple Notes 当前选中的备忘录正文作为文本上下文插入 ChatGPT 输入框
- 标准 `设置…` 窗口，集中展示通用、隐私、备忘录和分发状态
- 只读 `诊断…` 面板，可复制 App/Profile/WebView/分发状态，便于排查白屏、加载失败和 WebKit 进程重启
- 支持 OAuth / 登录弹窗、新窗口、外部链接转默认浏览器
- 支持清空本 App 的 WebView 网站数据，重置 cookie、登录态、缓存、localStorage、IndexedDB 和 Service Worker
- 支持常规下载，以及网页内 `blob:` / `data:` 下载桥接到 `~/Downloads`
- 显式单实例锁：重复打开会激活已有窗口，不会堆多个进程
- `Info.plist` 已声明 Apple Events、麦克风、摄像头、下载目录权限说明

## 构建

```bash
./packaging/make-app.sh
```

输出：

```text
dist/ChatGPT Swift.app
```

> 不要提交 `.build/`、`dist/`、`.app`、`.dmg` 或 cookie/session 导出文件。

## 生成 DMG

```bash
./packaging/make-dmg.sh
```

输出：

```text
dist/ChatGPT Swift.dmg
```

## Developer ID / Notarization

本地构建会 codesign 并启用 hardened runtime。Developer ID 分发需要使用 Apple Developer 证书、timestamp 和 notarization：

```bash
CHATGPT_SWIFT_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
CHATGPT_SWIFT_CODESIGN_TIMESTAMP=1 \
./packaging/make-dmg.sh

APPLE_ID="you@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
./packaging/notarize-dmg.sh
```

也可以先把 notarization 凭据存到 Keychain profile，再执行：

```bash
CHATGPT_SWIFT_NOTARY_PROFILE="chatgpt-swift-notary" ./packaging/notarize-dmg.sh
```

脚本会执行 `notarytool submit --wait`、`stapler staple`、`stapler validate` 和 `spctl --assess`。没有真实 Developer ID 证书和 Apple 凭据时，不会声称已完成 notarization。

## 更新

App 菜单里的 `检查更新…` 会检查 GitHub Releases 并可打开发行页。完整自动安装更新还未启用；要做到官方级别的后台自动更新，需要接 Sparkle、生成 EdDSA key、发布 appcast，并把 DMG/zip 签名产物纳入 release 流程。

## 安装到 Applications

```bash
rm -rf "/Applications/ChatGPT Swift.app"
cp -R "dist/ChatGPT Swift.app" /Applications/
open "/Applications/ChatGPT Swift.app"
```

## 原生聊天架构边界

当前主聊天 UI 仍是 `chatgpt.com` 的整页 `WKWebView`。原生消息列表、原生 token streaming、原生 composer、代码块/表格/数学公式组件可以做，但不能可靠复用 `chatgpt.com` 私有 DOM；需要改成 OpenAI API 或自有中间层驱动的原生聊天栈，再实现会话存储、虚拟列表、异步 Markdown 渲染和组件化富文本。

官方参考：
- [ChatGPT macOS app release notes](https://help.openai.com/en/articles/9703738-chatgpt-macos-app-release-notes)
- [Work with Apps on macOS](https://help.openai.com/en/articles/10119604-work-with-apps-on-macos)
- [Downloading the ChatGPT macOS app](https://help.openai.com/en/articles/9275200-downloading-the-chatgpt-macos-app)
