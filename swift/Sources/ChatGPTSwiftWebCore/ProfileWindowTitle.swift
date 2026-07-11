import Foundation

public enum ProfileWindowTitle {
    public static func format(profileName: String, isDefault: Bool) -> String {
        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDefault && trimmedName == "默认" {
            return "ChatGPT Swift"
        }

        guard !trimmedName.isEmpty else {
            return "ChatGPT Swift"
        }

        let displayName = containsEmailAddress(trimmedName)
            ? "邮箱账号（已遮罩）"
            : trimmedName
        return "ChatGPT Swift · \(displayName)"
    }

    public static func containsEmailAddress(_ value: String) -> Bool {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        ) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }
}
