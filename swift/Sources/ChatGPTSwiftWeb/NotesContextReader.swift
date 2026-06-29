import Foundation

enum NotesContextError: LocalizedError {
    case emptySelection
    case automationDenied
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "没有读取到选中的备忘录"
        case .automationDenied:
            return "没有访问备忘录的权限。请在系统设置 > 隐私与安全性 > 自动化中允许 ChatGPT Swift 控制备忘录。"
        case .scriptFailed(let message):
            return "读取备忘录失败：\(message)"
        }
    }
}

enum NotesContextReader {
    static func readSelectedNote(completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: """
            tell application "Notes"
                if (count of windows) is 0 then activate
                set selectedNotes to selection
                if selectedNotes is {} then return ""
                set selectedNote to item 1 of selectedNotes
                set noteTitle to name of selectedNote
                set noteBodyHTML to body of selectedNote
                return noteTitle & linefeed & "----CHATGPT_SWIFT_NOTES_BODY----" & linefeed & noteBodyHTML
            end tell
            """)

            guard let descriptor = script?.executeAndReturnError(&errorInfo) else {
                if appleScriptErrorNumber(errorInfo) == -1743 {
                    completion(.failure(NotesContextError.automationDenied))
                    return
                }
                let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? "AppleScript 无返回"
                completion(.failure(NotesContextError.scriptFailed(message)))
                return
            }

            let rawText = descriptor.stringValue ?? ""
            let cleaned = contextText(from: rawText)

            guard !cleaned.isEmpty else {
                completion(.failure(NotesContextError.emptySelection))
                return
            }

            completion(.success("""
            以下是我当前备忘录里的上下文，请参考：

            \(cleaned)
            """))
        }
    }

    private static func contextText(from rawText: String) -> String {
        let marker = "----CHATGPT_SWIFT_NOTES_BODY----"
        let parts = rawText.components(separatedBy: marker)
        if parts.count >= 2 {
            let title = normalizePlainText(parts[0])
            let bodyHTML = parts.dropFirst().joined(separator: marker)
            let body = normalizePlainText(htmlToPlainText(bodyHTML))
            return [title, body]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }

        return normalizePlainText(htmlToPlainText(rawText))
    }

    private static func htmlToPlainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
              ) else {
            return html
        }
        return attributed.string
    }

    private static func normalizePlainText(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var normalizedLines: [String] = []
        var previousWasBlank = false
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank && previousWasBlank {
                continue
            }
            normalizedLines.append(line)
            previousWasBlank = isBlank
        }
        return normalizedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appleScriptErrorNumber(_ errorInfo: NSDictionary?) -> Int? {
        if let number = errorInfo?[NSAppleScript.errorNumber] as? NSNumber {
            return number.intValue
        }
        return errorInfo?[NSAppleScript.errorNumber] as? Int
    }
}
