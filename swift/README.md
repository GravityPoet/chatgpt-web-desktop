# ChatGPT Swift

原生 macOS AppKit + WKWebView 的 ChatGPT 网页壳，用来在桌面窗口里保留 ChatGPT Web 的模型选择器和进阶 / high 思考强度控制，并和 Tauri/Rust 版并排对比。

## 特点

- 独立 bundle id：`local.chatgpt-web.swift`
- 独立 Cookie / WebsiteDataStore，与 Chrome、Tauri 版隔离
- 原生 `NSWindow`，窗口大小和位置由 macOS `setFrameAutosaveName` 记住
- 原生 Dock / App 图标 / 菜单
- `WKWebView` 加载 `https://chatgpt.com/`
- 支持 OAuth / 登录弹窗、新窗口、外部链接转默认浏览器
- 支持常规下载，以及网页内 `blob:` / `data:` 下载桥接到 `~/Downloads`
- 显式单实例锁：重复打开会激活已有窗口，不会堆多个进程
- `Info.plist` 已声明麦克风、摄像头、下载目录权限说明

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

## 安装到 Applications

```bash
rm -rf "/Applications/ChatGPT Swift.app"
cp -R "dist/ChatGPT Swift.app" /Applications/
open "/Applications/ChatGPT Swift.app"
```
