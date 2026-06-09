import AppKit
import CryptoKit
import Darwin
import Foundation

private let appTitle = "Cloak Picker"
private var retainedDelegate: AccountPickerAppDelegate?

@main
enum AccountPickerMain {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            runSelfCheck()
            return
        }

        let app = NSApplication.shared
        let delegate = AccountPickerAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private static func runSelfCheck() {
        do {
            let store = AccountStore()
            try store.validateLaunchScript()
            let accounts = try store.loadAccounts()
            print("account-picker: ok (\(accounts.count) account(s)); launch=\(store.launchScriptURL.path)")
        } catch {
            fputs("account-picker: \(describe(error))\n", stderr)
            exit(1)
        }
    }
}

final class AccountPickerAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AccountPickerViewController(store: AccountStore())
        let window = NSWindow(contentViewController: controller)
        window.title = appTitle
        window.setContentSize(NSSize(width: 820, height: 560))
        window.minSize = NSSize(width: 760, height: 500)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct Account: Equatable {
    let name: String
    let directoryURL: URL
    let seed: String
    let region: String?
    let localeEnabled: Bool
    let proxyDisplay: String
    let hasProxy: Bool
}

final class AccountStore {
    private let fileManager = FileManager.default
    let accountBaseURL: URL
    let launchScriptURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let homeURL = fileManager.homeDirectoryForCurrentUser

        if let accountBase = environment["CLOAK_ACCOUNT_BASE"], !accountBase.isEmpty {
            accountBaseURL = URL(fileURLWithPath: accountBase, isDirectory: true)
        } else {
            accountBaseURL = homeURL
                .appendingPathComponent("Library/Application Support/ChatGPT Cloak/Accounts", isDirectory: true)
        }

        if let launchScript = environment["CLOAK_LAUNCH_SCRIPT"], !launchScript.isEmpty {
            launchScriptURL = URL(fileURLWithPath: launchScript)
        } else {
            let rootPath = environment["CLOAK_REPO_ROOT"] ?? fileManager.currentDirectoryPath
            launchScriptURL = URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent("packaging/launch-account.sh")
        }
    }

    func validateLaunchScript() throws {
        guard fileManager.fileExists(atPath: launchScriptURL.path) else {
            throw PickerError.launchScriptMissing(launchScriptURL.path)
        }
        guard fileManager.isExecutableFile(atPath: launchScriptURL.path) else {
            throw PickerError.launchScriptNotExecutable(launchScriptURL.path)
        }
    }

    func loadAccounts() throws -> [Account] {
        try fileManager.createDirectory(at: accountBaseURL, withIntermediateDirectories: true)
        chmod(accountBaseURL.path, S_IRWXU)

        let directories = try fileManager.contentsOfDirectory(
            at: accountBaseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return directories
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true && url.lastPathComponent != "main"
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { readAccount(at: $0) }
    }

    func createAccount(named name: String) throws -> Account {
        try validateAccountName(name)
        let directory = accountBaseURL.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw PickerError.duplicateAccount(name)
        }

        try secureAccountDirectory(directory)
        try writeSecret(String(randomSeed()), to: directory.appendingPathComponent(".cloak-seed"))
        return readAccount(at: directory)
    }

    func rename(_ account: Account, to newName: String) throws {
        try validateAccountName(newName)
        let destination = accountBaseURL.appendingPathComponent(newName, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw PickerError.duplicateAccount(newName)
        }

        try secureAccountDirectory(account.directoryURL)
        try writeSecret(account.seed, to: account.directoryURL.appendingPathComponent(".cloak-seed"))
        try fileManager.moveItem(at: account.directoryURL, to: destination)
        try secureAccountDirectory(destination)
    }

    func setProxy(_ account: Account, value: String?) throws {
        let target = account.directoryURL.appendingPathComponent(".cloak-proxy")
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            removeIfPresent(target)
            return
        }

        guard rawValue.hasPrefix("socks5://") || rawValue.hasPrefix("http://") || rawValue.hasPrefix("https://") else {
            throw PickerError.invalidProxy
        }

        try secureAccountDirectory(account.directoryURL)
        try writeSecret(rawValue, to: target)
    }

    func setRegion(_ account: Account, value: String?) throws {
        let target = account.directoryURL.appendingPathComponent(".cloak-region")
        guard let rawValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty else {
            try secureAccountDirectory(account.directoryURL)
            removeIfPresent(target)
            return
        }

        try secureAccountDirectory(account.directoryURL)
        try writeSecret(rawValue, to: target)
    }

    func toggleLocale(_ account: Account) throws {
        let target = account.directoryURL.appendingPathComponent(".cloak-locale")
        if fileManager.fileExists(atPath: target.path) {
            removeIfPresent(target)
            return
        }

        try secureAccountDirectory(account.directoryURL)
        try Data().write(to: target, options: .atomic)
        chmod(target.path, S_IRUSR | S_IWUSR)
    }

    func delete(_ account: Account) throws {
        try fileManager.removeItem(at: account.directoryURL)
    }

    func launch(_ account: Account) throws {
        try validateLaunchScript()

        let process = Process()
        process.executableURL = launchScriptURL
        process.arguments = [account.name]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment

        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullOutput
            process.standardError = nullOutput
        }

        do {
            try process.run()
        } catch {
            throw PickerError.launchFailed(error.localizedDescription)
        }
    }

    private func readAccount(at directory: URL) -> Account {
        try? secureAccountDirectory(directory)

        let name = directory.lastPathComponent
        var seed = deterministicSeed(for: name)
        if let pinnedSeed = readFirstLine(directory.appendingPathComponent(".cloak-seed")),
           pinnedSeed.range(of: #"^[0-9]{4,5}$"#, options: .regularExpression) != nil {
            seed = pinnedSeed
        }

        let region = readFirstLine(directory.appendingPathComponent(".cloak-region"))
        let proxyURL = readFirstLine(directory.appendingPathComponent(".cloak-proxy"))
        let localeEnabled = fileManager.fileExists(atPath: directory.appendingPathComponent(".cloak-locale").path)

        return Account(
            name: name,
            directoryURL: directory,
            seed: seed,
            region: region?.isEmpty == false ? region : nil,
            localeEnabled: localeEnabled,
            proxyDisplay: proxyURL.map(maskProxy) ?? "关",
            hasProxy: proxyURL != nil
        )
    }

    private func secureAccountDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, S_IRWXU)
        for fileName in [".cloak-seed", ".cloak-proxy", ".cloak-locale", ".cloak-region"] {
            let fileURL = directory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: fileURL.path) {
                chmod(fileURL.path, S_IRUSR | S_IWUSR)
            }
        }
    }

    private func validateAccountName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.@+-_")
        guard !name.isEmpty,
              name != "main",
              !name.hasPrefix("."),
              !name.hasSuffix("."),
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains("..") else {
            throw PickerError.invalidName
        }
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw PickerError.invalidName
        }
    }

    private func writeSecret(_ value: String, to url: URL) throws {
        try Data((value + "\n").utf8).write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
    }

    private func removeIfPresent(_ url: URL) {
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func readFirstLine(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return content.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private func deterministicSeed(for name: String) -> String {
        let digest = SHA256.hash(data: Data(name.utf8))
        let prefix = digest.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        return String(prefix % 90_000 + 10_000)
    }

    private func randomSeed() -> UInt32 {
        UInt32.random(in: 0..<90_000) + 10_000
    }

    private func maskProxy(_ proxyURL: String) -> String {
        guard let schemeRange = proxyURL.range(of: "://") else {
            return proxyURL
        }

        let scheme = proxyURL[..<schemeRange.lowerBound]
        let rest = proxyURL[schemeRange.upperBound...]
        let host = rest.split(separator: "@", maxSplits: 1).last.map(String.init) ?? String(rest)
        return "\(scheme)://\(host)"
    }
}

final class AccountPickerViewController: NSViewController {
    private let store: AccountStore
    private var accounts: [Account] = []
    private var selectedAccountName: String?
    private let listStack = NSStackView()
    private let detailStack = NSStackView()
    private let accountCountLabel = NSTextField(labelWithString: "")

    init(store: AccountStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.background.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        reloadAccounts(selecting: nil)
    }

    private func buildLayout() {
        let rootStack = NSStackView()
        rootStack.orientation = .horizontal
        rootStack.alignment = .top
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            rootStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            rootStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])

        let leftPane = makePane()
        let rightPane = makePane()
        rootStack.addArrangedSubview(leftPane)
        rootStack.addArrangedSubview(rightPane)

        leftPane.widthAnchor.constraint(equalToConstant: 350).isActive = true
        rightPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 370).isActive = true

        buildListPane(in: leftPane)
        buildDetailPane(in: rightPane)
    }

    private func buildListPane(in pane: NSView) {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 2

        let title = label("账号", font: .systemFont(ofSize: 20, weight: .semibold), color: Palette.primaryText)
        accountCountLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accountCountLabel.textColor = Palette.secondaryText
        titleStack.addArrangedSubview(title)
        titleStack.addArrangedSubview(accountCountLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        header.addArrangedSubview(titleStack)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(toolbarButton("刷新", symbol: "arrow.clockwise", action: #selector(refreshAccounts)))
        header.addArrangedSubview(toolbarButton("新建", symbol: "plus", action: #selector(newAccount)))

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = 8
        listStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(listStack)

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        let stack = paneStack(in: pane)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(scrollView)
    }

    private func buildDetailPane(in pane: NSView) {
        detailStack.orientation = .vertical
        detailStack.alignment = .width
        detailStack.spacing = 14
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = paneStack(in: pane)
        stack.addArrangedSubview(detailStack)
    }

    private func paneStack(in pane: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16),
        ])

        return stack
    }

    private func makePane() -> NSView {
        let pane = NSView()
        pane.wantsLayer = true
        pane.layer?.backgroundColor = Palette.pane.cgColor
        pane.layer?.cornerRadius = 8
        pane.layer?.borderWidth = 1
        pane.layer?.borderColor = Palette.border.cgColor
        pane.translatesAutoresizingMaskIntoConstraints = false
        return pane
    }

    private func reloadAccounts(selecting desiredName: String?) {
        do {
            accounts = try store.loadAccounts()
        } catch {
            presentError(error, title: "无法读取账号")
            accounts = []
        }

        if let desiredName, accounts.contains(where: { $0.name == desiredName }) {
            selectedAccountName = desiredName
        } else if let selectedAccountName, accounts.contains(where: { $0.name == selectedAccountName }) {
            self.selectedAccountName = selectedAccountName
        } else {
            selectedAccountName = accounts.first?.name
        }

        renderList()
        renderDetail()
    }

    private func renderList() {
        clearStack(listStack)
        accountCountLabel.stringValue = "\(accounts.count) 个隔离账号"

        guard !accounts.isEmpty else {
            listStack.addArrangedSubview(EmptyStateView(
                title: "还没有账号",
                subtitle: "先新建一个隔离账号。",
                buttonTitle: "新建账号",
                target: self,
                action: #selector(newAccount)
            ))
            return
        }

        for account in accounts {
            let row = AccountRowView(account: account)
            row.isChosen = account.name == selectedAccountName
            row.target = self
            row.action = #selector(selectAccount(_:))
            row.onDoubleClick = { [weak self] in
                self?.selectedAccountName = account.name
                self?.launchSelectedAccount()
            }
            listStack.addArrangedSubview(row)
        }
    }

    private func renderDetail() {
        clearStack(detailStack)

        guard let account = selectedAccount() else {
            detailStack.addArrangedSubview(EmptyStateView(
                title: "选择账号",
                subtitle: "左侧选择后启动或管理。",
                buttonTitle: "刷新",
                target: self,
                action: #selector(refreshAccounts)
            ))
            return
        }

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let avatar = AvatarView()
        avatar.letter = String(account.name.prefix(1)).uppercased()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: 46).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        titleStack.addArrangedSubview(label(account.name, font: .systemFont(ofSize: 22, weight: .semibold), color: Palette.primaryText))
        titleStack.addArrangedSubview(label("独立 profile / fingerprint", font: .systemFont(ofSize: 12, weight: .medium), color: Palette.secondaryText))

        header.addArrangedSubview(avatar)
        header.addArrangedSubview(titleStack)
        detailStack.addArrangedSubview(header)

        let launchButton = primaryButton("启动账号", symbol: "play.fill", action: #selector(launchSelectedAccount))
        launchButton.keyEquivalent = "\r"
        detailStack.addArrangedSubview(launchButton)
        detailStack.addArrangedSubview(metadataGrid(for: account))

        let actionGrid = NSGridView(views: [
            [actionButton("代理", symbol: "network", action: #selector(editProxy)),
             actionButton("区域", symbol: "tag", action: #selector(editRegion))],
            [actionButton(account.localeEnabled ? "关闭语言" : "开启语言", symbol: "globe", action: #selector(toggleLocale)),
             actionButton("重命名", symbol: "pencil", action: #selector(renameAccount))],
            [dangerButton("删除账号", symbol: "trash", action: #selector(deleteAccount)),
             actionButton("刷新", symbol: "arrow.clockwise", action: #selector(refreshAccounts))],
        ])
        actionGrid.rowSpacing = 8
        actionGrid.columnSpacing = 8
        detailStack.addArrangedSubview(actionGrid)

        let reminder = label(
            "不要用 Chromium 原生 Profile 切换账号；隔离入口是这个选择器。",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: Palette.warning
        )
        reminder.lineBreakMode = .byWordWrapping
        reminder.maximumNumberOfLines = 2
        detailStack.addArrangedSubview(reminder)
    }

    private func metadataGrid(for account: Account) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = Palette.card.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Palette.border.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let rows: [[NSView]] = [
            [metaKey("指纹"), metaValue(account.seed, monospaced: true)],
            [metaKey("区域"), metaValue(account.region ?? "未设置")],
            [metaKey("语言"), metaValue(account.localeEnabled ? "跟随出口" : "关")],
            [metaKey("代理"), metaValue(account.proxyDisplay)],
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(grid)

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])

        return card
    }

    private func selectedAccount() -> Account? {
        guard let selectedAccountName else {
            return nil
        }
        return accounts.first { $0.name == selectedAccountName }
    }

    @objc private func selectAccount(_ sender: AccountRowView) {
        selectedAccountName = sender.account.name
        renderList()
        renderDetail()
    }

    @objc private func refreshAccounts() {
        reloadAccounts(selecting: selectedAccountName)
    }

    @objc private func newAccount() {
        guard let name = promptForText(title: "新建账号", message: "可用字母、数字、.、@、+、-、_；不能叫 main。")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty else {
            return
        }

        do {
            let account = try store.createAccount(named: name)
            reloadAccounts(selecting: account.name)
        } catch {
            presentError(error, title: "无法新建账号")
        }
    }

    @objc private func editProxy() {
        guard let account = selectedAccount() else {
            return
        }

        let currentProxy = readFirstLine(account.directoryURL.appendingPathComponent(".cloak-proxy")) ?? ""
        guard let value = promptForText(
            title: "设置代理",
            message: "留空会清除。例：socks5://user:pass@host:1080 或 http://host:8080",
            defaultValue: currentProxy,
            allowsEmpty: true
        ) else {
            return
        }

        do {
            try store.setProxy(account, value: value)
            reloadAccounts(selecting: account.name)
        } catch {
            presentError(error, title: "无法设置代理")
        }
    }

    @objc private func editRegion() {
        guard let account = selectedAccount() else {
            return
        }

        guard let value = promptForText(
            title: "设置区域标签",
            message: "留空会清除。例：JP-Tokyo 或 东京",
            defaultValue: account.region ?? "",
            allowsEmpty: true
        ) else {
            return
        }

        do {
            try store.setRegion(account, value: value)
            reloadAccounts(selecting: account.name)
        } catch {
            presentError(error, title: "无法设置区域标签")
        }
    }

    @objc private func toggleLocale() {
        guard let account = selectedAccount() else {
            return
        }

        do {
            try store.toggleLocale(account)
            reloadAccounts(selecting: account.name)
        } catch {
            presentError(error, title: "无法切换语言")
        }
    }

    @objc private func renameAccount() {
        guard let account = selectedAccount(),
              let newName = promptForText(title: "重命名账号", message: "重命名会保留原指纹。", defaultValue: account.name)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !newName.isEmpty,
              newName != account.name else {
            return
        }

        do {
            try store.rename(account, to: newName)
            reloadAccounts(selecting: newName)
        } catch {
            presentError(error, title: "无法重命名账号")
        }
    }

    @objc private func deleteAccount() {
        guard let account = selectedAccount() else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "删除「\(account.name)」？"
        alert.informativeText = "这会永久清除它的 cookie / 登录，无法撤销。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除")

        guard alert.runModal() == .alertSecondButtonReturn else {
            return
        }

        do {
            try store.delete(account)
            reloadAccounts(selecting: nil)
        } catch {
            presentError(error, title: "无法删除账号")
        }
    }

    @objc private func launchSelectedAccount() {
        guard let account = selectedAccount() else {
            return
        }

        do {
            try store.launch(account)
            NSApp.terminate(nil)
        } catch {
            presentError(error, title: "无法启动账号")
        }
    }

    private func promptForText(title: String, message: String, defaultValue: String = "", allowsEmpty: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let value = field.stringValue
        if !allowsEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return value
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = describe(error)
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func toolbarButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        return button
    }

    private func primaryButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = actionButton(title, symbol: symbol, action: action)
        button.bezelColor = Palette.accent
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 42).isActive = true
        return button
    }

    private func actionButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func dangerButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = actionButton(title, symbol: symbol, action: action)
        button.contentTintColor = Palette.danger
        return button
    }

    private func metaKey(_ text: String) -> NSTextField {
        label(text, font: .systemFont(ofSize: 12, weight: .medium), color: Palette.secondaryText)
    }

    private func metaValue(_ text: String, monospaced: Bool = false) -> NSTextField {
        let font: NSFont = monospaced ? .monospacedDigitSystemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13, weight: .semibold)
        let value = label(text, font: font, color: Palette.primaryText)
        value.lineBreakMode = .byTruncatingMiddle
        return value
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func readFirstLine(_ url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return content.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private func clearStack(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

final class AccountRowView: NSControl {
    let account: Account
    var onDoubleClick: (() -> Void)?
    var isChosen = false {
        didSet { applyStyle() }
    }

    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let chipStack = NSStackView()
    private let avatar = AvatarView()

    init(account: Account) {
        self.account = account
        super.init(frame: .zero)
        setup()
        configure()
        applyStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
        if event.clickCount == 2 {
            onDoubleClick?()
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 82).isActive = true

        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = Palette.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        metaLabel.textColor = Palette.secondaryText
        metaLabel.lineBreakMode = .byTruncatingTail

        chipStack.orientation = .horizontal
        chipStack.spacing = 6
        chipStack.alignment = .leading

        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(metaLabel)
        textStack.addArrangedSubview(chipStack)

        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        chevron.contentTintColor = Palette.tertiaryText
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 38),
            avatar.heightAnchor.constraint(equalToConstant: 38),

            textStack.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func configure() {
        avatar.letter = String(account.name.prefix(1)).uppercased()
        nameLabel.stringValue = account.name
        metaLabel.stringValue = "指纹 \(account.seed)"

        clearChips()
        addChip(account.region ?? "未设区域", color: account.region == nil ? Palette.neutralChip : Palette.infoChip)
        addChip(account.localeEnabled ? "语言 开" : "语言 关", color: account.localeEnabled ? Palette.successChip : Palette.neutralChip)
        addChip(account.hasProxy ? account.proxyDisplay : "代理 关", color: account.hasProxy ? Palette.warningChip : Palette.neutralChip)
    }

    private func addChip(_ text: String, color: NSColor) {
        chipStack.addArrangedSubview(PillLabel(text: text, backgroundColor: color))
    }

    private func clearChips() {
        for view in chipStack.arrangedSubviews {
            chipStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func applyStyle() {
        layer?.backgroundColor = (isChosen ? Palette.selectedCard : Palette.card).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (isChosen ? Palette.accent : Palette.border).cgColor
    }
}

final class EmptyStateView: NSView {
    init(title: String, subtitle: String, buttonTitle: String, target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.card.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Palette.border.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let icon = NSImageView(image: NSImage(systemSymbolName: "person.crop.circle.badge.plus", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Palette.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Palette.primaryText

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        subtitleLabel.textColor = Palette.secondaryText

        let button = NSButton(title: buttonTitle, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(button)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PillLabel: NSView {
    private let label: NSTextField
    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 3

    init(text: String, backgroundColor: NSColor) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.cornerRadius = 5

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Palette.primaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding),
            widthAnchor.constraint(lessThanOrEqualToConstant: 128),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: min(size.width + horizontalPadding * 2, 128), height: size.height + verticalPadding * 2)
    }
}

final class AvatarView: NSView {
    var letter: String = "" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(ovalIn: bounds)
        Palette.accent.setFill()
        path.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.black.withAlphaComponent(0.78),
        ]
        let string = NSString(string: letter.isEmpty ? "C" : letter)
        let size = string.size(withAttributes: attributes)
        string.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 - 1),
            withAttributes: attributes
        )
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum Palette {
    static let background = NSColor(hex: 0x0b0f12)
    static let pane = NSColor(hex: 0x13181c)
    static let card = NSColor(hex: 0x1a2025)
    static let selectedCard = NSColor(hex: 0x203129)
    static let border = NSColor.white.withAlphaComponent(0.08)
    static let primaryText = NSColor(hex: 0xf4f7f5)
    static let secondaryText = NSColor(hex: 0xa7b0ad)
    static let tertiaryText = NSColor(hex: 0x6f7976)
    static let accent = NSColor(hex: 0x55d890)
    static let danger = NSColor(hex: 0xff6b6b)
    static let warning = NSColor(hex: 0xf1c75b)
    static let neutralChip = NSColor(hex: 0x2a3137)
    static let successChip = NSColor(hex: 0x1d4d39)
    static let infoChip = NSColor(hex: 0x1f4467)
    static let warningChip = NSColor(hex: 0x5a4220)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let red = CGFloat((hex >> 16) & 0xff) / 255
        let green = CGFloat((hex >> 8) & 0xff) / 255
        let blue = CGFloat(hex & 0xff) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum PickerError: LocalizedError {
    case invalidName
    case duplicateAccount(String)
    case invalidProxy
    case launchScriptMissing(String)
    case launchScriptNotExecutable(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "名字无效：可用字母、数字、.、@、+、-、_；不能叫 main，不能以 . 开头/结尾，不能含 /、\\ 或连续 ..。"
        case .duplicateAccount(let name):
            return "「\(name)」已存在。"
        case .invalidProxy:
            return "代理须以 socks5://、http:// 或 https:// 开头。"
        case .launchScriptMissing(let path):
            return "找不到启动脚本：\(path)"
        case .launchScriptNotExecutable(let path):
            return "启动脚本不可执行：\(path)"
        case .launchFailed(let reason):
            return "启动脚本运行失败：\(reason)"
        }
    }
}

private func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
}
