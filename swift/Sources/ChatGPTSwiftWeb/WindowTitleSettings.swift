import ChatGPTSwiftWebCore
import Foundation

enum WindowTitleSettings {
    static let defaultsKey = "ChatGPTSwiftWeb.WindowTitleDisplayMode"

    static func mode(defaults: UserDefaults = .standard) -> WindowTitleDisplayMode {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let mode = WindowTitleDisplayMode(rawValue: rawValue)
        else {
            return .appNameOnly
        }
        return mode
    }

    static func setMode(_ mode: WindowTitleDisplayMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
        defaults.synchronize()
    }
}
