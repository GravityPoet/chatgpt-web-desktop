import AppKit
import Carbon

struct QuickWindowShortcut: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt
    let character: String

    static let standard = QuickWindowShortcut(keyCode: 49, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, character: "空格")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var isValid: Bool {
        keyCode <= 126 && !character.isEmpty && character.count <= 16 &&
        !flags.intersection([.command, .control, .option]).isEmpty
    }
    var label: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
        (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + character
    }
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}

enum QuickWindowPreferences {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "ChatGPTSwiftWeb.QuickWindow.Enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "ChatGPTSwiftWeb.QuickWindow.Enabled") }
    }
    static var shortcut: QuickWindowShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: "ChatGPTSwiftWeb.QuickWindow.Shortcut"),
                  let shortcut = try? JSONDecoder().decode(QuickWindowShortcut.self, from: data), shortcut.isValid else { return .standard }
            return shortcut
        }
        set { if let data = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(data, forKey: "ChatGPTSwiftWeb.QuickWindow.Shortcut") } }
    }
}

@MainActor
final class QuickWindowHotKey {
    static let shared = QuickWindowHotKey()
    private var hotKey: EventHotKeyRef?
    private var registeredShortcut: QuickWindowShortcut?
    private var eventHandler: EventHandlerRef?
    var action: (() -> Void)?
    private(set) var statusText = "未启用"

    @discardableResult
    func register(_ shortcut: QuickWindowShortcut) -> Bool {
        if shortcut == registeredShortcut, hotKey != nil { return true }
        guard shortcut.isValid else { statusText = "请选择包含 ⌘、⌥ 或 ⌃ 的组合键"; return false }
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard result == noErr, id.signature == 0x43535751 else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<QuickWindowHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { owner.action?() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr else { statusText = "快捷键服务不可用（\(status)）"; return false }
        }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                        EventHotKeyID(signature: 0x43535751, id: 1), GetApplicationEventTarget(), 0, &next)
        guard result == noErr else { statusText = "快捷键被占用或不可注册（\(result)），请换一个组合"; return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = next
        registeredShortcut = shortcut
        statusText = "已启用：\(shortcut.label)"
        return true
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredShortcut = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        statusText = "未启用"
    }
}

final class ShortcutRecorderButton: NSButton {
    private var recording = false
    private var shortcut: QuickWindowShortcut
    private let onChange: (QuickWindowShortcut) -> Void
    override var acceptsFirstResponder: Bool { true }

    init(shortcut: QuickWindowShortcut, onChange: @escaping (QuickWindowShortcut) -> Void) {
        self.shortcut = shortcut
        self.onChange = onChange
        super.init(frame: .zero)
        title = "更改快捷键：\(shortcut.label)"
        bezelStyle = .rounded
        target = self
        action = #selector(recordShortcut)
        setAccessibilityLabel("更改快速窗口全局快捷键")
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func recordShortcut() {
        recording = true
        title = "按下新的组合键，Esc 取消"
        window?.makeFirstResponder(self)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = "更改快捷键：\(shortcut.label)"; return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let character = event.keyCode == 49 ? "空格" : (event.charactersIgnoringModifiers ?? "").uppercased()
        let next = QuickWindowShortcut(keyCode: event.keyCode, modifiers: flags.rawValue, character: character)
        guard next.isValid else { title = "请包含 ⌘、⌥ 或 ⌃，Esc 取消"; return }
        recording = false
        shortcut = next
        title = "更改快捷键：\(next.label)"
        onChange(next)
    }
}

extension AppDelegate {
    @MainActor
    func configureQuickWindowHotKey() {
        QuickWindowHotKey.shared.action = { [weak self] in self?.showQuickWindow(nil) }
        if QuickWindowPreferences.isEnabled { _ = QuickWindowHotKey.shared.register(QuickWindowPreferences.shortcut) }
    }

    @MainActor
    func setQuickWindowEnabled(_ enabled: Bool) {
        if enabled, !QuickWindowHotKey.shared.register(QuickWindowPreferences.shortcut) {
            mainController?.showToast(QuickWindowHotKey.shared.statusText, duration: 10)
        } else {
            QuickWindowPreferences.isEnabled = enabled
            if !enabled { QuickWindowHotKey.shared.stop(); quickController?.dispose(); quickController = nil }
        }
        refreshNativeUtilityWindows()
    }

    @MainActor
    func setQuickWindowShortcut(_ shortcut: QuickWindowShortcut) {
        guard shortcut.isValid else { return }
        if shortcut == QuickWindowPreferences.shortcut { return }
        if QuickWindowPreferences.isEnabled, !QuickWindowHotKey.shared.register(shortcut) {
            mainController?.showToast(QuickWindowHotKey.shared.statusText, duration: 10)
        } else { QuickWindowPreferences.shortcut = shortcut }
        refreshNativeUtilityWindows()
    }

    @MainActor @objc func showQuickWindow(_ sender: Any?) {
        guard !profileMutationInProgress, ProfileStore.pendingDataMutation == nil, !ProfileStore.metadataRecoveryRequired else { return }
        guard QuickWindowPreferences.isEnabled else { openAppSettingsAction(nil); return }
        let profile = ProfileStore.currentProfile()
        if let existing = quickController, existing.profileID != profile.id || existing.isDisposing {
            existing.dispose()
            quickController = nil
        }
        if quickController == nil {
            quickController = BrowserWindowController(initialURL: chatGPTURL, title: "ChatGPT Swift · 快速窗口", isPopup: true,
                                                       persistent: true, profileID: profile.id,
                                                       closeHandler: { [weak self] in self?.quickController = nil }, isQuickWindow: true)
        }
        quickController?.focusWhenReady = true
        quickController?.show()
        if quickController?.webView.isLoading == false { quickController?.focusPromptComposer() }
    }
}
