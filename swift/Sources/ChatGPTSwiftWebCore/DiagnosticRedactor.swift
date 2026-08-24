import Foundation

public enum DiagnosticRedactor {
    public static let placeholder = "<redacted>"

    private static let safeRouteNames: Set<String> = [
        "auth",
        "c",
        "g",
        "gpts",
        "library",
        "plugins",
        "projects",
        "scheduled",
        "settings",
        "share",
    ]

    public static func url(_ url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(),
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else {
            return "<redacted-url>"
        }

        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        var result = "\(scheme)://\(host)"
        if let port = url.port {
            result += ":\(port)"
        }

        let pathSegments = url.path.split(separator: "/", omittingEmptySubsequences: true)
        if pathSegments.isEmpty {
            result += "/"
        } else {
            let firstSegment = String(pathSegments[0]).lowercased()
            if safeRouteNames.contains(firstSegment) {
                result += "/\(firstSegment)"
                if pathSegments.count > 1 {
                    result += "/\(placeholder)"
                }
            } else {
                result += "/\(placeholder)"
            }
        }

        if url.query != nil {
            result += "?\(placeholder)"
        }
        if url.fragment != nil {
            result += "#\(placeholder)"
        }
        return result
    }

    public static func profileLabel(isDefault: Bool, persistent: Bool = true) -> String {
        guard persistent else {
            return "无痕"
        }
        return isDefault ? "默认" : "自定义空间（名称已脱敏）"
    }

    public static func pageTitle(_ title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return "nil"
        }
        return title == "ChatGPT" ? title : placeholder
    }

    public static func text(_ text: String) -> String {
        var result = replacingURLs(in: text)
        result = replacingMatches(
            pattern: #"(?i)(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            in: result,
            template: "<redacted-email>"
        )
        result = replacingMatches(
            pattern: #"(?<![A-Za-z0-9])(/Users/)[^/\s]+"#,
            in: result,
            template: "$1<redacted>"
        )
        return result
    }

    private static func replacingURLs(in text: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"https?://[^\s\"'<>\[\]{}]+"#,
            options: [.caseInsensitive]
        ) else {
            return text
        }

        var result = text
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range).reversed() {
            guard let originalRange = Range(match.range, in: result) else {
                continue
            }
            var rawURL = String(result[originalRange])
            while let last = rawURL.last, ".,;!?".contains(last) {
                rawURL.removeLast()
            }
            while rawURL.last == ")" && rawURL.filter({ $0 == ")" }).count > rawURL.filter({ $0 == "(" }).count {
                rawURL.removeLast()
            }
            guard let url = URL(string: rawURL) else {
                continue
            }
            result.replaceSubrange(originalRange, with: self.url(url))
        }
        return result
    }

    private static func replacingMatches(pattern: String, in text: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
