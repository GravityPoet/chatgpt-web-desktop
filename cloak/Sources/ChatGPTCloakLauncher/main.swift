import AppKit
import Darwin
import Foundation
import OSLog

private let appName = "NoTrace Browser"
private let appBundleIdentifier = "local.notrace-browser"
private let chromiumBundleIdentifier = "org.chromium.Chromium"
private let chatGPTAppURL = "https://chatgpt.com/"
private let defaultProfileID = "main"
private let cloakBrowserDirectoryName = ".cloakbrowser"
private let chromiumBinarySubpath = "Chromium.app/Contents/MacOS/Chromium"
private let launcherLogger = Logger(subsystem: appBundleIdentifier, category: "Launcher")
private var singleInstanceLockFileDescriptor: CInt = -1

@main
enum Main {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        SingleInstance.activateExistingInstanceOrAcquireLock()
        configureMainMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Resident app: open the ChatGPT singleton on launch and keep running (Dock running dot).
        openChatGPT()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon opens / focuses the ChatGPT singleton.
        openChatGPT()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let chatItem = NSMenuItem(title: "打开 ChatGPT", action: #selector(openChatGPTAction), keyEquivalent: "")
        chatItem.target = self
        menu.addItem(chatItem)
        let browserItem = NSMenuItem(title: "打开浏览器", action: #selector(openBrowserAction), keyEquivalent: "")
        browserItem.target = self
        menu.addItem(browserItem)
        return menu
    }

    @objc private func openChatGPTAction() { openChatGPT() }
    @objc private func openBrowserAction() { openFullBrowser() }

    private func openChatGPT() {
        do {
            let launcher = try CloakLauncher()
            let result = try launcher.launchOrActivate()
            launcherLogger.info("\(result.logMessage, privacy: .public)")
        } catch {
            presentError(error, title: "NoTrace Browser 无法打开 ChatGPT")
        }
    }

    private func openFullBrowser() {
        do {
            let launcher = try CloakLauncher()
            try launcher.openFullBrowser()
        } catch {
            presentError(error, title: "NoTrace Browser 无法打开浏览器")
        }
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: appName)
        let chatItem = NSMenuItem(title: "打开 ChatGPT", action: #selector(openChatGPTAction), keyEquivalent: "n")
        chatItem.target = self
        appMenu.addItem(chatItem)
        let browserItem = NSMenuItem(title: "打开浏览器", action: #selector(openBrowserAction), keyEquivalent: "b")
        browserItem.target = self
        appMenu.addItem(browserItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

struct CloakLauncher {
    private let fileManager = FileManager.default
    private let chromiumBinaryURL: URL
    private let supportDirectoryURL: URL
    private let profileDirectoryURL: URL

    init() throws {
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        chromiumBinaryURL = Self.resolveChromiumBinaryURL(home: homeDirectory, fileManager: fileManager)

        guard let baseSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw LauncherError.applicationSupportDirectoryUnavailable
        }

        supportDirectoryURL = baseSupportDirectory.appendingPathComponent(appName, isDirectory: true)
        profileDirectoryURL = supportDirectoryURL
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(defaultProfileID, isDirectory: true)
    }

    // Resolve the CloakBrowser Chromium binary without pinning a version. Mirrors
    // packaging/update-chromium.sh: prefer the `current` symlink the auto-updater maintains
    // (it is only repointed after the challenge gate passes), else fall back to the newest
    // ~/.cloakbrowser/chromium-* directory by natural version order. Returns the preferred
    // `current` path as a last resort so a missing install still surfaces a clear, stable path.
    private static func resolveChromiumBinaryURL(home: URL, fileManager: FileManager) -> URL {
        let cloakDir = home.appendingPathComponent(cloakBrowserDirectoryName, isDirectory: true)
        let currentBinary = cloakDir
            .appendingPathComponent("current", isDirectory: true)
            .appendingPathComponent(chromiumBinarySubpath)

        if fileManager.isExecutableFile(atPath: currentBinary.path) {
            return currentBinary
        }

        if let newest = newestVersionedChromiumBinaryURL(in: cloakDir, fileManager: fileManager) {
            return newest
        }

        return currentBinary
    }

    private static func newestVersionedChromiumBinaryURL(in cloakDir: URL, fileManager: FileManager) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cloakDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let versioned = entries
            .filter { $0.lastPathComponent.hasPrefix("chromium-") }
            .sorted {
                // Natural version order, equivalent to `sort -V` in update-chromium.sh.
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
            }

        for directory in versioned.reversed() {
            let binary = directory.appendingPathComponent(chromiumBinarySubpath)
            if fileManager.isExecutableFile(atPath: binary.path) {
                return binary
            }
        }

        return nil
    }

    func launchOrActivate() throws -> LaunchResult {
        try validateChromiumBinary()
        try prepareProfileDirectory()

        if let runningApp = existingCloakChromiumApp() {
            if runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) {
                return .activatedExisting(pid: runningApp.processIdentifier)
            }

            _ = runningApp.terminate()
            Thread.sleep(forTimeInterval: 1.0)
        }

        // No Cloak Chromium is running here, so neutralize session/crash restore before launching
        // to guarantee app-mode opens a single clean ChatGPT window, not a restored full browser.
        normalizeProfilePreferences()

        let process = Process()
        process.executableURL = chromiumBinaryURL
        process.arguments = chromiumArguments()
        process.currentDirectoryURL = chromiumBinaryURL.deletingLastPathComponent()

        do {
            try process.run()
        } catch {
            throw LauncherError.chromiumLaunchFailed(error.localizedDescription)
        }

        return .launchedNew(pid: process.processIdentifier)
    }

    // Opens a full Chromium browser window (normal chrome, tabs, address bar) on the same
    // profile. If the Cloak Chromium is already running, this opens a new window in it.
    func openFullBrowser() throws {
        try validateChromiumBinary()
        try prepareProfileDirectory()
        normalizeProfilePreferences()

        let process = Process()
        process.executableURL = chromiumBinaryURL
        process.arguments = [
            "--user-data-dir=\(profileDirectoryURL.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--new-window",
            chatGPTAppURL,
        ]
        process.currentDirectoryURL = chromiumBinaryURL.deletingLastPathComponent()

        do {
            try process.run()
        } catch {
            throw LauncherError.chromiumLaunchFailed(error.localizedDescription)
        }
    }

    private func validateChromiumBinary() throws {
        let path = chromiumBinaryURL.path

        guard fileManager.fileExists(atPath: path) else {
            throw LauncherError.chromiumBinaryMissing(path)
        }

        guard fileManager.isExecutableFile(atPath: path) else {
            throw LauncherError.chromiumBinaryNotExecutable(path)
        }
    }

    private func prepareProfileDirectory() throws {
        do {
            try fileManager.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw LauncherError.profileDirectoryCreationFailed(profileDirectoryURL.path, error.localizedDescription)
        }

        guard fileManager.isWritableFile(atPath: profileDirectoryURL.path) else {
            throw LauncherError.profileDirectoryNotWritable(profileDirectoryURL.path)
        }
    }

    // Make launches deterministic and safer: disable session restore, clear the crash flag, and
    // keep HTTPS-Only enabled for this profile before Chromium starts.
    private func normalizeProfilePreferences() {
        let prefsURL = profileDirectoryURL
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Preferences")

        do {
            try fileManager.createDirectory(
                at: prefsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: prefsURL),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }

        root["https_only_mode_enabled"] = true

        var session = root["session"] as? [String: Any] ?? [:]
        session["restore_on_startup"] = 5  // 5 = open New Tab page; do not restore previous windows
        root["session"] = session

        var profile = root["profile"] as? [String: Any] ?? [:]
        profile["exit_type"] = "Normal"  // suppress the "Chromium didn't shut down correctly" restore
        root["profile"] = profile

        if let output = try? JSONSerialization.data(withJSONObject: root) {
            try? output.write(to: prefsURL, options: .atomic)
        }
    }

    private func chromiumArguments() -> [String] {
        [
            "--app=\(chatGPTAppURL)",
            "--user-data-dir=\(profileDirectoryURL.path)",
            "--no-first-run",
            "--no-default-browser-check",
        ]
    }

    private func existingCloakChromiumApp() -> NSRunningApplication? {
        if let runningApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: chromiumBundleIdentifier)
            .first(where: { runningApp in
                guard runningApp.processIdentifier != getpid() else {
                    return false
                }

                let commandLine = Self.commandLine(for: runningApp.processIdentifier)
                return isMatchingCloakCommandLine(commandLine)
            }) {
            return runningApp
        }

        for pid in matchingCloakChromiumPIDs() {
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                return runningApp
            }
        }

        return nil
    }

    private func matchingCloakChromiumPIDs() -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Chromium"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { line -> pid_t? in
                let pidText = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let pid = pid_t(pidText) else {
                    return nil
                }

                guard isMatchingCloakCommandLine(Self.commandLine(for: pid)) else {
                    return nil
                }

                return pid
            }
    }

    private func isMatchingCloakCommandLine(_ commandLine: String) -> Bool {
        commandLine.contains(chromiumBinaryURL.path)
            && commandLine.contains("--app=\(chatGPTAppURL)")
            && commandLine.contains("--user-data-dir=\(profileDirectoryURL.path)")
    }

    private static func commandLine(for pid: pid_t) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(pid), "-o", "command="]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }

        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum LaunchResult {
    case activatedExisting(pid: pid_t)
    case launchedNew(pid: pid_t)

    var logMessage: String {
        switch self {
        case .activatedExisting(let pid):
            return "Activated existing Cloak Chromium process \(pid)."
        case .launchedNew(let pid):
            return "Launched Cloak Chromium process \(pid)."
        }
    }
}

enum LauncherError: LocalizedError {
    case applicationSupportDirectoryUnavailable
    case chromiumBinaryMissing(String)
    case chromiumBinaryNotExecutable(String)
    case profileDirectoryCreationFailed(String, String)
    case profileDirectoryNotWritable(String)
    case chromiumLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "无法解析本机 Application Support 目录，暂时不能创建 NoTrace Browser 数据目录。"
        case .chromiumBinaryMissing(let path):
            return "找不到 CloakBrowser Chromium binary。\n\n预期路径：\(path)\n\n请确认 CloakBrowser 已安装：~/.cloakbrowser/current 指向某个 chromium-*，或 ~/.cloakbrowser/chromium-* 下存在 Chromium.app。"
        case .chromiumBinaryNotExecutable(let path):
            return "CloakBrowser Chromium binary 存在，但没有可执行权限。\n\n路径：\(path)"
        case .profileDirectoryCreationFailed(let path, let reason):
            return "无法创建 NoTrace Browser profile 目录。\n\n目录：\(path)\n错误：\(reason)"
        case .profileDirectoryNotWritable(let path):
            return "NoTrace Browser profile 目录不可写。\n\n目录：\(path)\n\n请检查该目录权限后再启动。"
        case .chromiumLaunchFailed(let reason):
            return "CloakBrowser Chromium 启动失败。\n\n错误：\(reason)"
        }
    }
}

enum SingleInstance {
    static func activateExistingInstanceOrAcquireLock() {
        let lockPath = lockFileURL().path
        let fileDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard fileDescriptor >= 0 else {
            return
        }

        if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            singleInstanceLockFileDescriptor = fileDescriptor
            return
        }

        close(fileDescriptor)
        activateExistingInstance()
        exit(0)
    }

    private static func lockFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appDirectory = supportDirectory.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent("launcher.lock")
    }

    private static func activateExistingInstance() {
        let currentPID = getpid()
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
        let existingApp = runningApps.first { $0.processIdentifier != currentPID }
        existingApp?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}
