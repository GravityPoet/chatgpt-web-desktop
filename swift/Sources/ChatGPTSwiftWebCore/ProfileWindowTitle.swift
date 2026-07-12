import Foundation

public enum WindowTitleDisplayMode: String, CaseIterable {
    case appNameOnly
    case profileName
    case fullProfileName
}

public enum ProfileWindowTitle {
    public static func format(
        profileName: String,
        isDefault: Bool,
        mode: WindowTitleDisplayMode = .appNameOnly
    ) -> String {
        guard mode != .appNameOnly else {
            return "ChatGPT Swift"
        }

        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if isDefault && trimmedName == "默认" {
            return "ChatGPT Swift"
        }

        guard !trimmedName.isEmpty else {
            return "ChatGPT Swift"
        }

        let displayName: String
        switch mode {
        case .appNameOnly:
            return "ChatGPT Swift"
        case .profileName:
            displayName = emailLocalPart(from: trimmedName) ?? trimmedName
        case .fullProfileName:
            displayName = trimmedName
        }
        return "ChatGPT Swift — \(displayName)"
    }

    public static func emailLocalPart(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)^([A-Z0-9._%+-]+)@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        ) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = expression.firstMatch(in: trimmed, range: range),
              let localPartRange = Range(match.range(at: 1), in: trimmed)
        else {
            return nil
        }
        return String(trimmed[localPartRange])
    }
}
