import AppKit
import Foundation

enum NotesContextError: LocalizedError, Equatable {
    case emptySelection
    case automationDenied
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "没有读取到 Notes 列表中当前选中的备忘录"
        case .automationDenied:
            return "没有访问备忘录的权限。请在系统设置 > 隐私与安全性 > 自动化中允许 ChatGPT Swift 控制备忘录。"
        case .scriptFailed(let message):
            return "读取备忘录失败：\(message)"
        }
    }
}

enum NotesScriptExecutionResult {
    case success(String)
    case failure(number: Int?, message: String)
}

protocol NotesScriptExecuting {
    func execute(_ source: String) -> NotesScriptExecutionResult
}

struct SystemNotesScriptExecutor: NotesScriptExecuting {
    func execute(_ source: String) -> NotesScriptExecutionResult {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failure(number: nil, message: "AppleScript 无法创建")
        }

        let descriptor = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            let number: Int?
            if let value = errorInfo?[NSAppleScript.errorNumber] as? NSNumber {
                number = value.intValue
            } else {
                number = errorInfo?[NSAppleScript.errorNumber] as? Int
            }
            let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? "AppleScript 无返回"
            return .failure(number: number, message: message)
        }
        return .success(descriptor.stringValue ?? "")
    }
}

enum NotesContextReader {
    static let scriptSource = """
    tell application "Notes"
        if (count of windows) is 0 then activate
        set selectedNotes to selection
        if selectedNotes is {} then return ""
        set selectedNote to item 1 of selectedNotes
        set noteTitle to name of selectedNote
        set noteBodyHTML to body of selectedNote
        return noteTitle & linefeed & "----CHATGPT_SWIFT_NOTES_BODY----" & linefeed & noteBodyHTML
    end tell
    """

    static func readSelectedNote(
        executor: NotesScriptExecuting = SystemNotesScriptExecutor(),
        queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated),
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        queue.async {
            switch executor.execute(scriptSource) {
            case .failure(let number, let message):
                if number == -1743 {
                    completion(.failure(NotesContextError.automationDenied))
                } else {
                    completion(.failure(NotesContextError.scriptFailed(message)))
                }
            case .success(let rawText):
                let cleaned = contextText(from: rawText)
                guard !cleaned.isEmpty else {
                    completion(.failure(NotesContextError.emptySelection))
                    return
                }

                completion(.success("""
                以下是我在 Apple Notes 列表中当前选中的备忘录标题和完整正文，请参考：

                \(cleaned)
                """))
            }
        }
    }

    static func contextText(from rawText: String) -> String {
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

    static func htmlToPlainText(_ html: String) -> String {
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

    static func normalizePlainText(_ text: String) -> String {
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
}
