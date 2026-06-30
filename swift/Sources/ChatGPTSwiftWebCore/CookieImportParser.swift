import Foundation

public enum CookieImportParser {
    public static let errorDomain = "ChatGPTSwiftWeb.CookieImport"
    private static let defaultHeaderCookieImportDomain = ".chatgpt.com"

    public static func parse(data: Data) throws -> [HTTPCookie] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw cookieImportError("Cookie 文件必须是 UTF-8 文本")
        }

        let normalizedText = text.removingUTF8ByteOrderMark()
        let trimmedText = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }

        let exportedCookies: [CookieImportRecord]
        if trimmedText.hasPrefix("[") || trimmedText.hasPrefix("{") {
            exportedCookies = try JSONDecoder().decode(CookieImportDocument.self, from: Data(trimmedText.utf8)).cookies
        } else if looksLikeNetscapeCookieText(trimmedText) {
            exportedCookies = try parseNetscapeCookieText(trimmedText)
        } else {
            exportedCookies = try parseHeaderCookieText(trimmedText)
        }

        let cookies = try exportedCookies.map { try $0.makeCookie() }
        guard !cookies.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }
        return cookies
    }

    public static func isAllowedDomain(_ domain: String) -> Bool {
        var normalized = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while normalized.hasPrefix(".") {
            normalized.removeFirst()
        }
        return normalized == "chatgpt.com"
            || normalized.hasSuffix(".chatgpt.com")
            || normalized == "openai.com"
            || normalized.hasSuffix(".openai.com")
    }

    public static func isEssentialCookieName(_ name: String) -> Bool {
        name.hasPrefix("__Secure-next-auth.session-token")
            || name == "cf_clearance"
            || name == "__Secure-oai-is"
            || name == "oai-sc"
    }

    public static func isSessionCookieName(_ name: String) -> Bool {
        name.hasPrefix("__Secure-next-auth.session-token")
    }

    public static func safeMessage(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .dataCorrupted:
                return "JSON 内容无效"
            case .keyNotFound:
                return "JSON 缺少必要字段"
            case .typeMismatch, .valueNotFound:
                return "JSON 字段类型不匹配"
            @unknown default:
                return "JSON 解析失败"
            }
        }

        let nsError = error as NSError
        if nsError.domain == errorDomain, let message = nsError.userInfo[NSLocalizedDescriptionKey] as? String {
            return message
        }

        return error.localizedDescription
    }

    public static func cookieImportError(_ message: String) -> NSError {
        NSError(domain: errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func looksLikeNetscapeCookieText(_ text: String) -> Bool {
        if text.localizedCaseInsensitiveContains("Netscape HTTP Cookie File") {
            return true
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            if line.hasPrefix("#") && !line.hasPrefix("#HttpOnly_") {
                continue
            }
            let fields = splitCookieFields(line, maxSplits: 6)
            return fields.count >= 7 && isNetscapeBoolean(fields[1]) && isNetscapeBoolean(fields[3]) && Int(fields[4]) != nil
        }

        return false
    }

    private static func parseNetscapeCookieText(_ text: String) throws -> [CookieImportRecord] {
        var cookies: [CookieImportRecord] = []

        for (lineIndex, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") {
                continue
            }

            let fields = splitCookieFields(line, maxSplits: 6)
            guard fields.count >= 7 else {
                throw cookieImportError("Netscape 第 \(lineIndex + 1) 行字段不足")
            }
            guard let includeSubdomains = parseNetscapeBoolean(fields[1]) else {
                throw cookieImportError("Netscape 第 \(lineIndex + 1) 行 includeSubdomains 无效")
            }
            guard let secure = parseNetscapeBoolean(fields[3]) else {
                throw cookieImportError("Netscape 第 \(lineIndex + 1) 行 secure 无效")
            }
            guard let expires = Double(fields[4]) else {
                throw cookieImportError("Netscape 第 \(lineIndex + 1) 行 expires 无效")
            }

            let isSession = expires <= 0
            cookies.append(
                CookieImportRecord(
                    domain: fields[0],
                    expirationDate: isSession ? nil : expires,
                    hostOnly: !includeSubdomains,
                    httpOnly: httpOnly,
                    name: fields[5],
                    path: fields[2].isEmpty ? "/" : fields[2],
                    sameSite: nil,
                    secure: secure,
                    session: isSession,
                    value: fields[6]
                )
            )
        }

        guard !cookies.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }
        return cookies
    }

    private static func parseHeaderCookieText(_ text: String) throws -> [CookieImportRecord] {
        var cookies: [CookieImportRecord] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }

            if let value = stripHeaderPrefix(line, prefix: "Set-Cookie:") {
                cookies.append(try parseSetCookieLine(value))
            } else if let value = stripHeaderPrefix(line, prefix: "Cookie:") {
                cookies.append(contentsOf: try parseCookieHeaderPairs(value))
            } else if looksLikeSetCookieLine(line) {
                cookies.append(try parseSetCookieLine(line))
            } else {
                cookies.append(contentsOf: try parseCookieHeaderPairs(line))
            }
        }

        guard !cookies.isEmpty else {
            throw cookieImportError("没有可导入的 cookie")
        }
        return cookies
    }

    private static func parseCookieHeaderPairs(_ header: String) throws -> [CookieImportRecord] {
        var cookies: [CookieImportRecord] = []

        for segment in header.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else {
                continue
            }

            let name = String(pair[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[pair.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isSetCookieAttribute(name) else {
                continue
            }

            cookies.append(headerCookie(name: name, value: value))
        }

        guard !cookies.isEmpty else {
            throw cookieImportError("Header String 没有可导入的 cookie")
        }
        return cookies
    }

    private static func parseSetCookieLine(_ line: String) throws -> CookieImportRecord {
        let segments = line.split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = segments.first, let separator = first.firstIndex(of: "=") else {
            throw cookieImportError("Set-Cookie Header 无效")
        }

        let name = String(first[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(first[first.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw cookieImportError("Set-Cookie Header cookie 名称为空")
        }

        var domain = defaultHeaderCookieImportDomain
        var path = "/"
        var secure = false
        var httpOnly = false
        var sameSite: String?
        var session = true
        var expirationDate: Double?

        for attribute in segments.dropFirst() {
            let lower = attribute.lowercased()
            if lower == "secure" {
                secure = true
            } else if lower == "httponly" {
                httpOnly = true
            } else if let separator = attribute.firstIndex(of: "=") {
                let key = String(attribute[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = String(attribute[attribute.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "domain":
                    domain = value
                case "path":
                    path = value.isEmpty ? "/" : value
                case "expires":
                    if let date = parseCookieExpiresDate(value) {
                        expirationDate = date.timeIntervalSince1970
                        session = false
                    }
                case "max-age":
                    if let maxAge = Double(value), maxAge > 0 {
                        expirationDate = Date().addingTimeInterval(maxAge).timeIntervalSince1970
                        session = false
                    }
                case "samesite":
                    sameSite = value
                default:
                    break
                }
            }
        }

        return CookieImportRecord(
            domain: domain,
            expirationDate: expirationDate,
            hostOnly: !domain.hasPrefix("."),
            httpOnly: httpOnly,
            name: name,
            path: path,
            sameSite: sameSite,
            secure: secure,
            session: session,
            value: value
        )
    }

    private static func headerCookie(name: String, value: String) -> CookieImportRecord {
        CookieImportRecord(
            domain: defaultHeaderCookieImportDomain,
            expirationDate: nil,
            hostOnly: false,
            httpOnly: false,
            name: name,
            path: "/",
            sameSite: nil,
            secure: true,
            session: true,
            value: value
        )
    }

    private static func splitCookieFields(_ line: String, maxSplits: Int) -> [String] {
        line.split(
            maxSplits: maxSplits,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        ).map(String.init)
    }

    private static func stripHeaderPrefix(_ line: String, prefix: String) -> String? {
        guard line.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil else {
            return nil
        }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeSetCookieLine(_ line: String) -> Bool {
        let lowerSegments = line.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard lowerSegments.count > 1, lowerSegments.first?.contains("=") == true else {
            return false
        }
        return lowerSegments.dropFirst().contains { segment in
            segment == "secure"
                || segment == "httponly"
                || segment.hasPrefix("domain=")
                || segment.hasPrefix("path=")
                || segment.hasPrefix("expires=")
                || segment.hasPrefix("max-age=")
                || segment.hasPrefix("samesite=")
        }
    }

    private static func isSetCookieAttribute(_ name: String) -> Bool {
        switch name.lowercased() {
        case "domain", "path", "expires", "max-age", "samesite", "secure", "httponly":
            return true
        default:
            return false
        }
    }

    private static func isNetscapeBoolean(_ value: String) -> Bool {
        parseNetscapeBoolean(value) != nil
    }

    private static func parseNetscapeBoolean(_ value: String) -> Bool? {
        switch value.uppercased() {
        case "TRUE":
            return true
        case "FALSE":
            return false
        default:
            return nil
        }
    }

    private static func parseCookieExpiresDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd-MMM-yyyy HH:mm:ss zzz",
            "EEE MMM dd HH:mm:ss yyyy",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }
}

private struct CookieImportDocument: Decodable {
    let cookies: [CookieImportRecord]

    enum CodingKeys: String, CodingKey {
        case cookies
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let cookies = try? singleValue.decode([CookieImportRecord].self) {
            self.cookies = cookies
            return
        }
        if let cookie = try? singleValue.decode(CookieImportRecord.self) {
            self.cookies = [cookie]
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cookies = try container.decode([CookieImportRecord].self, forKey: .cookies)
    }
}

private struct CookieImportRecord: Codable {
    let domain: String
    let expirationDate: Double?
    let hostOnly: Bool?
    let httpOnly: Bool?
    let name: String
    let path: String
    let sameSite: String?
    let secure: Bool?
    let session: Bool?
    let value: String

    func makeCookie() throws -> HTTPCookie {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cookiePath = path.isEmpty ? "/" : path

        guard !trimmedName.isEmpty else {
            throw CookieImportParser.cookieImportError("cookie 名称为空")
        }
        guard !trimmedDomain.isEmpty else {
            throw CookieImportParser.cookieImportError("cookie 域名为空")
        }
        guard CookieImportParser.isAllowedDomain(trimmedDomain) else {
            throw CookieImportParser.cookieImportError("cookie 域名不在 ChatGPT/OpenAI 白名单中：\(trimmedDomain)")
        }
        guard cookiePath.hasPrefix("/") else {
            throw CookieImportParser.cookieImportError("cookie path 无效")
        }
        guard !cookiePath.utf8.contains(0),
              !cookiePath.split(separator: "/").contains(where: { $0 == ".." }) else {
            throw CookieImportParser.cookieImportError("cookie path 不安全")
        }

        var cookieAttributes: [HTTPCookiePropertyKey: Any] = [
            .name: trimmedName,
            .value: value,
            .domain: trimmedDomain,
            .path: cookiePath,
            .version: "0",
        ]

        if secure == true {
            cookieAttributes[.secure] = "TRUE"
        }
        if httpOnly == true {
            cookieAttributes[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        if let sameSiteValue = normalizedSameSiteValue(sameSite) {
            cookieAttributes[HTTPCookiePropertyKey("SameSite")] = sameSiteValue
        }
        if session != true, let expirationDate {
            cookieAttributes[.expires] = Date(timeIntervalSince1970: expirationDate)
        }

        guard let result = HTTPCookie(properties: cookieAttributes) else {
            throw CookieImportParser.cookieImportError("cookie 数据无法转换")
        }

        return result
    }

    private func normalizedSameSiteValue(_ rawValue: String?) -> String? {
        switch rawValue?.lowercased() {
        case "lax":
            return "Lax"
        case "strict":
            return "Strict"
        case "none", "no_restriction":
            return "None"
        default:
            return nil
        }
    }
}

private extension String {
    func removingUTF8ByteOrderMark() -> String {
        if hasPrefix("\u{feff}") {
            return String(dropFirst())
        }
        return self
    }
}
