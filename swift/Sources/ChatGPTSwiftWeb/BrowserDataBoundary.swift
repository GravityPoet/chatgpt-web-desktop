import Foundation
import ChatGPTSwiftWebCore

/// Native data operations are intentionally scoped to the OpenAI/ChatGPT cookie boundary.
/// A user may open third-party pages in a popup, but their sessions must never be cloned or
/// written to a portable export by this app.
enum BrowserDataBoundary {
    static func transferableCookies(_ cookies: [HTTPCookie]) -> [HTTPCookie] {
        cookies.filter { CookieImportParser.isAllowedDomain($0.domain) }
    }

    static func writeSensitiveData(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try data.write(to: temporaryURL, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
