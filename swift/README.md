# ChatGPT Swift

原生 macOS AppKit + WKWebView 的 ChatGPT 网页壳，用来在原生 ChatGPT 桌面 App 没有暴露更高思考强度选择时，把 ChatGPT Web 的模型选择器和进阶 / high thinking 控制保留在桌面窗口里，并和 Tauri/Rust 版并排对比。

## 特点

- 独立 bundle id：`local.chatgpt-web.swift`
- 独立 Cookie / WebsiteDataStore，与 Chrome、Tauri 版隔离
- 原生 `NSWindow`，窗口大小和位置由 macOS `setFrameAutosaveName` 记住
- 原生 Dock / App 图标 / 菜单 / 轻量工具栏，toolbar 自定义布局会保存
- `WKWebView` 加载 `https://chatgpt.com/`
- 慢加载会收敛到 toolbar 状态；白屏、WebKit 渲染进程重启和加载失败才显示原生状态层，并尽量自动恢复
- 本机输入草稿恢复：刷新、白屏恢复或渲染进程重启后，尽量把未发送输入还原到网页输入框
- 可选后台完成通知：窗口不在前台时，检测到网页回复从生成中变为空闲后发送 macOS 通知
- 可把 Apple Notes 当前选中的备忘录正文作为文本上下文插入 ChatGPT 输入框
- 标准 `设置…` 窗口，集中展示通用、隐私、备忘录和分发状态
- 只读 `诊断…` 面板，可复制或导出诊断包，包含 App/Profile/WebView/分发状态、启动耗时、非正常退出线索、最近崩溃报告、CPU/RSS/footprint 采样趋势和最近本 App 日志
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

本地构建会 codesign 并启用 hardened runtime。由于本地自签名证书没有 Apple Team ID，脚本会自动使用 `packaging/local-debug.entitlements` 允许加载嵌入的 Sparkle framework。Developer ID 分发需要使用 Apple Developer 证书、timestamp 和 notarization：

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

## 更新 / Sparkle

App 菜单里的 `检查更新…` 优先使用 Sparkle；未配置 Sparkle 时回退到 GitHub Releases 并可打开发行页。本地默认构建不会启用自动安装更新，避免没有 feed/key 的开发构建进入半配置状态。

生成 Sparkle EdDSA 公钥：

```bash
./packaging/generate-sparkle-keys.sh
```

默认 Keychain account 是 `chatgpt-swift`；如需换名，两个脚本都使用同一个环境变量：

```bash
CHATGPT_SWIFT_SPARKLE_KEY_ACCOUNT="your-account" ./packaging/generate-sparkle-keys.sh
```

用 HTTPS appcast feed 和公钥打包：

```bash
CHATGPT_SWIFT_SPARKLE_FEED_URL="https://example.com/appcast.xml" \
CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY="YOUR_PUBLIC_EDDSA_KEY" \
./packaging/make-dmg.sh
```

从签名后的 DMG 生成 appcast：

```bash
CHATGPT_SWIFT_SPARKLE_DOWNLOAD_URL_PREFIX="https://example.com/releases/" \
./packaging/make-sparkle-appcast.sh
```

Sparkle 自动更新需要 HTTPS 托管 `appcast.xml` 和 DMG、Sparkle EdDSA 私钥在 Keychain 或 CI secret 中可用。Developer ID 签名和 notarization 不是 GitHub-only 分发的硬要求，但能减少 Gatekeeper 提示。私钥不要提交到仓库。

## GitHub Release CI

仓库提供手动触发的 GitHub Actions workflow：`.github/workflows/swift-macos-release.yml`。它会：

- 默认用本地自签名构建 GitHub Release DMG，不需要 Apple Developer 账号
- 如果选择 `distribution=developer-id`，才导入 Developer ID Application `.p12`、notarize 并 staple DMG
- 如果开启 `enable_sparkle=true`，才构建带 Sparkle feed/key 的 DMG，并生成带 EdDSA 签名的 `appcast.xml`
- 上传 `ChatGPT Swift.dmg` 到指定 GitHub Release；开启 Sparkle 时额外上传 `appcast.xml`

默认 GitHub-only 分发不需要配置额外 secrets；它会上传自签名 DMG，用户首次打开时可能遇到 macOS Gatekeeper 提示，需要右键打开或手动允许。

如果选择 `distribution=developer-id`，需要配置这些 GitHub Secrets：

```text
CHATGPT_SWIFT_CERTIFICATE_P12_BASE64
CHATGPT_SWIFT_CERTIFICATE_PASSWORD
APPLE_ID
APPLE_TEAM_ID
APPLE_APP_SPECIFIC_PASSWORD
```

如果开启 `enable_sparkle=true`，还需要配置这些 GitHub Secrets：

```text
CHATGPT_SWIFT_SPARKLE_PUBLIC_ED_KEY
CHATGPT_SWIFT_SPARKLE_ED_PRIVATE_KEY
```

检查 GitHub-only 默认分发是否可运行：

```bash
./packaging/check-release-readiness.sh --github-secrets GravityPoet/chatgpt-web-desktop
```

检查 Developer ID + Sparkle 完整分发所需 secrets：

```bash
./packaging/check-release-readiness.sh \
  --github-secrets GravityPoet/chatgpt-web-desktop \
  --distribution developer-id \
  --sparkle on
```

如果本机已经有 Developer ID `.p12`、Sparkle EdDSA key 和 Apple notarization 凭据，并且你确实要做 notarized/Sparkle 分发，可以用脚本写入 GitHub Secrets：

```bash
./packaging/configure-release-credentials.sh \
  --repo GravityPoet/chatgpt-web-desktop \
  --certificate-p12 "/path/to/developer-id.p12" \
  --certificate-password "p12-password" \
  --sparkle-public-ed-key "sparkle-public-key" \
  --sparkle-private-ed-key "sparkle-private-key" \
  --apple-id "you@example.com" \
  --apple-team-id "TEAMID" \
  --apple-app-specific-password "xxxx-xxxx-xxxx-xxxx"
```

脚本通过 `gh secret set` 写入 GitHub，不会把 secret 值打印到终端；它适合在你自己的本机执行，不要在共享机器上用命令行参数传私钥。不要把 `.p12` 或 Sparkle 私钥提交到仓库。

开启 Sparkle 时推荐的 `feed_url` 是固定入口：

```text
https://github.com/GravityPoet/chatgpt-web-desktop/releases/latest/download/appcast.xml
```

发布某个 tag 时，workflow 会把 appcast 内的下载地址指向该 tag 的 release asset，例如 `https://github.com/GravityPoet/chatgpt-web-desktop/releases/download/v0.1.2/`。
如果只想先检查产物，可以用 draft release；要让 Sparkle 客户端真正通过 `latest/download/appcast.xml` 自动发现更新，release 必须发布为非 draft。

## 安装到 Applications

```bash
rm -rf "/Applications/ChatGPT Swift.app"
cp -R "dist/ChatGPT Swift.app" /Applications/
open "/Applications/ChatGPT Swift.app"
```

## 原生聊天架构边界

当前主聊天 UI 仍是 `chatgpt.com` 的整页 `WKWebView`。原生消息列表、原生 token streaming、原生 composer、代码块/表格/数学公式组件可以做，但不能可靠复用 `chatgpt.com` 私有 DOM；需要改成 OpenAI API 或自有中间层驱动的原生聊天栈，再实现会话存储、虚拟列表、异步 Markdown 渲染和组件化富文本。

Route A 当前策略：不新增第二个聊天界面，不替换主聊天区；只在现有 WebView 壳层上补窗口、状态、恢复、设置、诊断和少量 macOS 原生集成。

官方参考：
- [ChatGPT macOS app release notes](https://help.openai.com/en/articles/9703738-chatgpt-macos-app-release-notes)
- [Work with Apps on macOS](https://help.openai.com/en/articles/10119604-work-with-apps-on-macos)
- [Downloading the ChatGPT macOS app](https://help.openai.com/en/articles/9275200-downloading-the-chatgpt-macos-app)
