import Darwin
import Foundation

struct RemoteImageFile {
    let fileURL: URL
    let mimeType: String
    let byteCount: Int
}

enum RemoteImageLoadError: LocalizedError, Equatable {
    case invalidURL
    case blockedAddress
    case dnsResolutionFailed
    case invalidResponse
    case invalidRedirect
    case httpStatus(Int)
    case invalidContentLength
    case unsupportedMIMEType(String?)
    case tooLarge(maximumBytes: Int)
    case empty
    case fileWriteFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "图像地址必须是 HTTPS URL。"
        case .blockedAddress:
            return "为避免访问本机或内网地址，已阻止此图像请求。"
        case .dnsResolutionFailed:
            return "无法安全解析图像服务器地址。"
        case .invalidResponse:
            return "服务器没有返回有效的 HTTP 响应。"
        case .invalidRedirect:
            return "服务器尝试重定向到不安全的非 HTTPS 地址。"
        case let .httpStatus(statusCode):
            return "服务器返回 HTTP \(statusCode)。"
        case .invalidContentLength:
            return "服务器返回了无效的 Content-Length。"
        case let .unsupportedMIMEType(mimeType):
            if let mimeType, !mimeType.isEmpty {
                return "服务器返回的内容类型不是图像（\(mimeType)）。"
            }
            return "服务器没有返回图像内容类型。"
        case let .tooLarge(maximumBytes):
            return "图像超过 \(maximumBytes / 1024 / 1024) MB。"
        case .empty:
            return "图像数据为空。"
        case .fileWriteFailed:
            return "无法写入临时图像文件。"
        }
    }
}

/// A resolver seam keeps SSRF checks deterministic in integration tests while production uses
/// the system resolver. Every hostname is resolved again before following a redirect and before
/// accepting a response, which reduces DNS-rebinding exposure. URLSession may resolve again when
/// it opens the connection, so this is defense-in-depth rather than an absolute IP pin.
typealias RemoteImageHostResolver = @Sendable (String) throws -> [String]

/// Streams a single remote image into a bounded temporary file.
///
/// The loader deliberately uses an isolated session with cookie and credential stores disabled.
/// Response metadata is validated before accepting body bytes, and the task is cancelled as soon
/// as the streamed byte count would exceed `maximumBytes`.
final class RemoteImageLoader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    typealias Completion = (Result<RemoteImageFile, Error>) -> Void
    private static let temporaryFilePrefix = "ChatGPTSwiftWeb-RemoteImage-"

    private let sourceURL: URL
    private let maximumBytes: Int
    private let completion: Completion
    private let temporaryDirectory: URL
    private let sessionConfiguration: URLSessionConfiguration
    private let hostResolver: RemoteImageHostResolver
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "ChatGPTSwiftWeb.RemoteImageLoader"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var temporaryFileURL: URL?
    private var fileHandle: FileHandle?
    private var mimeType: String?
    private var receivedByteCount = 0
    private var isFinished = false

    init(
        sourceURL: URL,
        maximumBytes: Int,
        configuration: URLSessionConfiguration = .ephemeral,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        hostResolver: @escaping RemoteImageHostResolver = RemoteImageLoader.defaultHostResolver,
        completion: @escaping Completion
    ) {
        precondition(maximumBytes > 0)
        self.sourceURL = sourceURL
        self.maximumBytes = maximumBytes
        self.temporaryDirectory = temporaryDirectory
        self.hostResolver = hostResolver
        self.completion = completion

        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = Self.removingCookieHeader(from: configuration.httpAdditionalHeaders)
        sessionConfiguration = configuration
        super.init()
    }

    func start() {
        delegateQueue.addOperation { [weak self] in
            guard let self, self.session == nil, !self.isFinished else {
                return
            }

            guard let validationError = self.validationError(for: self.sourceURL, isRedirect: false) else {
                var request = URLRequest(url: self.sourceURL)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.httpShouldHandleCookies = false
                request.setValue(nil, forHTTPHeaderField: "Cookie")

                let session = URLSession(
                    configuration: self.sessionConfiguration,
                    delegate: self,
                    delegateQueue: self.delegateQueue
                )
                self.session = session
                let task = session.dataTask(with: request)
                self.dataTask = task
                task.resume()
                return
            }

            self.finish(.failure(validationError))
        }
    }

    func cancel() {
        delegateQueue.addOperation { [weak self] in
            guard let self else {
                return
            }
            if self.isFinished {
                self.removeTemporaryFile()
                return
            }
            self.dataTask?.cancel()
            self.finish(.failure(URLError(.cancelled)))
        }
    }

    static func cleanupStaleTemporaryFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix(temporaryFilePrefix) {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory != true,
                  let modifiedAt = values.contentModificationDate,
                  now.timeIntervalSince(modifiedAt) > age else {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !isFinished else {
            completionHandler(.cancel)
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(RemoteImageLoadError.invalidResponse))
            return
        }

        if let validationError = validationError(for: httpResponse.url, isRedirect: false) {
            completionHandler(.cancel)
            finish(.failure(validationError))
            return
        }

        let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]
        if redirectStatusCodes.contains(httpResponse.statusCode) {
            guard let location = httpResponse.value(forHTTPHeaderField: "Location"),
                  let responseURL = httpResponse.url,
                  let redirectURL = URL(string: location, relativeTo: responseURL)?.absoluteURL else {
                completionHandler(.cancel)
                finish(.failure(RemoteImageLoadError.invalidRedirect))
                return
            }
            if let validationError = validationError(for: redirectURL, isRedirect: true) {
                completionHandler(.cancel)
                finish(.failure(validationError))
                return
            }
            completionHandler(.allow)
            return
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(RemoteImageLoadError.httpStatus(httpResponse.statusCode)))
            return
        }

        let normalizedMIMEType = httpResponse.mimeType?.lowercased()
        guard let normalizedMIMEType,
              normalizedMIMEType.hasPrefix("image/"),
              normalizedMIMEType.count > "image/".count,
              normalizedMIMEType != "image/svg+xml" else {
            completionHandler(.cancel)
            finish(.failure(RemoteImageLoadError.unsupportedMIMEType(httpResponse.mimeType)))
            return
        }

        if let rawContentLength = httpResponse.value(forHTTPHeaderField: "Content-Length") {
            let trimmedContentLength = rawContentLength.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let contentLength = Int64(trimmedContentLength), contentLength >= 0 else {
                completionHandler(.cancel)
                finish(.failure(RemoteImageLoadError.invalidContentLength))
                return
            }
            guard contentLength <= Int64(maximumBytes) else {
                completionHandler(.cancel)
                finish(.failure(RemoteImageLoadError.tooLarge(maximumBytes: maximumBytes)))
                return
            }
        } else if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(RemoteImageLoadError.tooLarge(maximumBytes: maximumBytes)))
            return
        }

        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let temporaryFileURL = temporaryDirectory
                .appendingPathComponent("\(Self.temporaryFilePrefix)\(UUID().uuidString).tmp", isDirectory: false)
            guard FileManager.default.createFile(
                atPath: temporaryFileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw RemoteImageLoadError.fileWriteFailed
            }
            self.temporaryFileURL = temporaryFileURL
            fileHandle = try FileHandle(forWritingTo: temporaryFileURL)
            mimeType = normalizedMIMEType
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isFinished else {
            return
        }

        guard data.count <= maximumBytes - receivedByteCount else {
            dataTask.cancel()
            finish(.failure(RemoteImageLoadError.tooLarge(maximumBytes: maximumBytes)))
            return
        }

        guard let fileHandle else {
            dataTask.cancel()
            finish(.failure(RemoteImageLoadError.fileWriteFailed))
            return
        }

        do {
            try fileHandle.write(contentsOf: data)
            receivedByteCount += data.count
        } catch {
            dataTask.cancel()
            finish(.failure(RemoteImageLoadError.fileWriteFailed))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !isFinished else {
            return
        }

        if let error {
            finish(.failure(error))
            return
        }

        guard receivedByteCount > 0 else {
            finish(.failure(RemoteImageLoadError.empty))
            return
        }

        guard let temporaryFileURL, let mimeType else {
            finish(.failure(RemoteImageLoadError.invalidResponse))
            return
        }

        finish(.success(RemoteImageFile(
            fileURL: temporaryFileURL,
            mimeType: mimeType,
            byteCount: receivedByteCount
        )))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = newRequest.url else {
            completionHandler(nil)
            finish(.failure(RemoteImageLoadError.invalidRedirect))
            return
        }

        if let validationError = validationError(for: redirectURL, isRedirect: true) {
            completionHandler(nil)
            finish(.failure(validationError))
            return
        }

        var sanitizedRequest = newRequest
        sanitizedRequest.httpShouldHandleCookies = false
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(sanitizedRequest)
    }

    private func validationError(for url: URL?, isRedirect: Bool) -> RemoteImageLoadError? {
        guard let url,
              url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return isRedirect ? .invalidRedirect : .invalidURL
        }

        if let endpoint = Self.parseIPAddress(host) {
            return Self.isBlocked(endpoint) ? .blockedAddress : nil
        }

        do {
            let resolvedAddresses = try hostResolver(host)
            guard !resolvedAddresses.isEmpty else {
                return .dnsResolutionFailed
            }
            for resolvedAddress in resolvedAddresses {
                guard let endpoint = Self.parseIPAddress(resolvedAddress) else {
                    return .dnsResolutionFailed
                }
                if Self.isBlocked(endpoint) {
                    return .blockedAddress
                }
            }
            return nil
        } catch {
            return .dnsResolutionFailed
        }
    }

    private func finish(_ result: Result<RemoteImageFile, Error>) {
        guard !isFinished else {
            return
        }
        isFinished = true

        try? fileHandle?.close()
        fileHandle = nil
        dataTask = nil
        session?.finishTasksAndInvalidate()
        session = nil

        if case .failure = result, let temporaryFileURL {
            try? FileManager.default.removeItem(at: temporaryFileURL)
        }
        completion(result)
    }

    private func removeTemporaryFile() {
        if let temporaryFileURL {
            try? FileManager.default.removeItem(at: temporaryFileURL)
            self.temporaryFileURL = nil
        }
    }

    private static func removingCookieHeader(from headers: [AnyHashable: Any]?) -> [AnyHashable: Any]? {
        guard let headers else {
            return nil
        }
        return headers.filter { key, _ in
            String(describing: key).caseInsensitiveCompare("Cookie") != .orderedSame
        }
    }

    private enum ParsedIPAddress {
        case ipv4([UInt8])
        case ipv6([UInt8])
    }

    private static let defaultHostResolver: RemoteImageHostResolver = { host in
        try resolveHost(host)
    }

    private static func resolveHost(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM)

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let firstResult = result else {
            throw RemoteImageLoadError.dnsResolutionFailed
        }
        defer { freeaddrinfo(firstResult) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = firstResult
        while let entry = current {
            let addressInfo = entry.pointee
            if let socketAddress = addressInfo.ai_addr {
                var numericHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    socketAddress,
                    addressInfo.ai_addrlen,
                    &numericHost,
                    socklen_t(numericHost.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    addresses.append(String(cString: numericHost))
                }
            }
            current = addressInfo.ai_next
        }

        guard !addresses.isEmpty else {
            throw RemoteImageLoadError.dnsResolutionFailed
        }
        return Array(Set(addresses))
    }

    private static func parseIPAddress(_ value: String) -> ParsedIPAddress? {
        var normalized = value
        if let zoneSeparator = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<zoneSeparator])
        }

        var ipv4 = in_addr()
        if normalized.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            return .ipv4(bytes)
        }

        var ipv6 = in6_addr()
        if normalized.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0.prefix(16)) }
            return .ipv6(bytes)
        }
        return nil
    }

    private static func isBlocked(_ endpoint: ParsedIPAddress) -> Bool {
        switch endpoint {
        case let .ipv4(bytes):
            return isBlockedIPv4(bytes)
        case let .ipv6(bytes):
            return isBlockedIPv6(bytes)
        }
    }

    private static func isBlockedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else {
            return true
        }
        let first = bytes[0]
        let second = bytes[1]
        let third = bytes[2]

        // Unspecified, private, shared, loopback, link-local, multicast, and reserved space.
        if first == 0 || first == 10 || first == 127 || first >= 224 {
            return true
        }
        if first == 100, (64...127).contains(second) {
            return true
        }
        if first == 169, second == 254 {
            return true
        }
        if first == 172, (16...31).contains(second) {
            return true
        }
        if first == 192, second == 168 {
            return true
        }
        if first == 192, second == 0, third == 0 {
            return true
        }
        // IETF special-use and benchmark ranges are not routable public image targets. Blocking
        // them closes the remaining SSRF bypasses that are easy to miss when only RFC1918 ranges
        // are considered.
        if first == 192, second == 0, third == 2 {
            return true
        }
        if first == 192, second == 88, third == 99 {
            return true
        }
        if first == 198, (second == 18 || second == 19) {
            return true
        }
        if first == 198, second == 51, third == 100 {
            return true
        }
        if first == 203, second == 0, third == 113 {
            return true
        }
        return false
    }

    private static func isBlockedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else {
            return true
        }

        if bytes.allSatisfy({ $0 == 0 }) || (bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1) {
            return true
        }
        if bytes[0] == 0xff || (bytes[0] & 0xfe) == 0xfc {
            return true
        }
        if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 {
            return true
        }
        if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0xc0 {
            return true
        }

        let isIPv4Mapped = bytes.prefix(10).allSatisfy({ $0 == 0 })
            && bytes[10] == 0xff
            && bytes[11] == 0xff
        let isIPv4Compatible = bytes.prefix(12).allSatisfy({ $0 == 0 })
        if isIPv4Mapped || isIPv4Compatible {
            return isBlockedIPv4(Array(bytes.suffix(4)))
        }

        // 6to4 and the standard NAT64 prefix embed an IPv4 destination.
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            return isBlockedIPv4(Array(bytes[2..<6]))
        }
        if bytes[0] == 0x00, bytes[1] == 0x64, bytes[2] == 0xff, bytes[3] == 0x9b {
            return isBlockedIPv4(Array(bytes.suffix(4)))
        }
        return false
    }
}
