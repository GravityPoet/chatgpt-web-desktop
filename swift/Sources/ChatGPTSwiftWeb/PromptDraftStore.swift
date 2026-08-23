import Foundation

enum PromptDraftStore {
    private static let restoreDefaultsKey = "ChatGPTSwiftWeb.PromptDraftRestoreEnabled"
    private static let maximumCharacters = 12_000

    static func isRestoreEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: restoreDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: restoreDefaultsKey)
    }

    static func setRestoreEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: restoreDefaultsKey)
    }

    static func draft(for profileID: String?, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: draftKey(profileID: profileID)) ?? ""
    }

    static func draftSummary(for profileID: String?) -> String {
        let draft = draft(for: profileID)
        guard !draft.isEmpty else {
            return "无"
        }
        return "\(draft.count) 个字符，仅保存在本机偏好中"
    }

    static func saveDraft(_ rawText: String, profileID: String?, defaults: UserDefaults = .standard) {
        let text = normalizedDraft(rawText)
        let key = draftKey(profileID: profileID)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(text, forKey: key)
        }
    }

    static func clearDraft(for profileID: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: draftKey(profileID: profileID))
    }

    private static func draftKey(profileID: String?) -> String {
        "ChatGPTSwiftWeb.PromptDraft." + (profileID ?? "default")
    }

    private static func normalizedDraft(_ rawText: String) -> String {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        if text.count <= maximumCharacters {
            return text
        }
        return String(text.prefix(maximumCharacters))
    }
}
