import Foundation

enum PromptDraftStore {
    private static let restoreDefaultsKey = "ChatGPTSwiftWeb.PromptDraftRestoreEnabled"
    private static let maximumCharacters = 200_000

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

    static func draft(for profileID: String?, conversationID: String?, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: draftKey(profileID: profileID, conversationID: conversationID))
            ?? (conversationID == nil || conversationID == "/" ? draft(for: profileID, defaults: defaults) : "")
    }

    static func draftSummary(for profileID: String?) -> String {
        let prefix = draftKey(profileID: profileID)
        let count = UserDefaults.standard.dictionaryRepresentation().filter { $0.key == prefix || $0.key.hasPrefix(prefix + ".") }.values.compactMap { $0 as? String }.reduce(0) { $0 + $1.count }
        guard count > 0 else {
            return "无"
        }
        return "\(count) 个字符，按会话保存在本机"
    }

    static func saveDraft(_ rawText: String, profileID: String?, defaults: UserDefaults = .standard) {
        saveDraft(rawText, profileID: profileID, conversationID: nil, defaults: defaults)
    }

    static func saveDraft(_ rawText: String, profileID: String?, conversationID: String?, defaults: UserDefaults = .standard) {
        let text = normalizedDraft(rawText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let key = draftKey(profileID: profileID, conversationID: conversationID)
        if conversationID == "/" { defaults.removeObject(forKey: draftKey(profileID: profileID)) }
        guard defaults.string(forKey: key) != text else { return }
        defaults.set(text, forKey: key)
    }

    static func clearDraft(for profileID: String?, defaults: UserDefaults = .standard) {
        clearAllDrafts(for: profileID, defaults: defaults)
    }

    static func clearDraft(for profileID: String?, conversationID: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: draftKey(profileID: profileID, conversationID: conversationID))
        if conversationID == "/" { defaults.removeObject(forKey: draftKey(profileID: profileID)) }
    }

    static func clearAllDrafts(for profileID: String?, defaults: UserDefaults = .standard) {
        let prefix = "ChatGPTSwiftWeb.PromptDraft.\(profileID ?? "default")."
        for key in defaults.dictionaryRepresentation().keys where key == draftKey(profileID: profileID) || key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    static func profileDrafts(for profileID: String, defaults: UserDefaults = .standard) -> [String: String] {
        let prefix = draftKey(profileID: profileID)
        return defaults.dictionaryRepresentation().filter { $0.key == prefix || $0.key.hasPrefix(prefix + ".") }.compactMapValues { $0 as? String }
    }

    static func restoreProfileDrafts(_ drafts: [String: String], profileID: String, defaults: UserDefaults = .standard) {
        let prefix = draftKey(profileID: profileID)
        for (key, text) in drafts where (key == prefix || key.hasPrefix(prefix + ".")) && defaults.object(forKey: key) == nil {
            defaults.set(text, forKey: key)
        }
    }

    private static func draftKey(profileID: String?) -> String {
        "ChatGPTSwiftWeb.PromptDraft." + (profileID ?? "default")
    }

    private static func draftKey(profileID: String?, conversationID: String?) -> String {
        guard let conversationID, !conversationID.isEmpty else { return draftKey(profileID: profileID) }
        return draftKey(profileID: profileID) + "." + conversationID
    }

    private static func normalizedDraft(_ rawText: String) -> String {
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        if text.count <= maximumCharacters {
            return text
        }
        return String(text.prefix(maximumCharacters))
    }
}
