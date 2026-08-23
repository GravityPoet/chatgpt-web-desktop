import Foundation

struct RemoteImageFile {
    let fileURL: URL
    let mimeType: String
    let byteCount: Int
}

enum RemoteImageLoadError: LocalizedError, Equatable {
    case invalidURL
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
        completion: @escaping Completion
    ) {
        precondition(maximumBytes > 0)
        self.sourceURL = sourceURL
        self.maximumBytes = maximumBytes
        self.temporaryDirectory = temporaryDirectory
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
        guard session == nil, !isFinished else {
            return
        }

        guard sourceURL.scheme?.caseInsensitiveCompare("https") == .orderedSame,
              sourceURL.host?.isEmpty == false,
              sourceURL.user == nil,
              sourceURL.password == nil else {
            finish(.failure(RemoteImageLoadError.invalidURL))
            return
        }

        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Cookie")

        let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let task = session.dataTask(with: request)
        dataTask = task
        task.resume()
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

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(RemoteImageLoadError.httpStatus(httpResponse.statusCode)))
            return
        }

        let normalizedMIMEType = httpResponse.mimeType?.lowercased()
        guard let normalizedMIMEType,
              normalizedMIMEType.hasPrefix("image/"),
              normalizedMIMEType.count > "image/".count else {
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
        guard let redirectURL = newRequest.url,
              redirectURL.scheme?.lowercased() == "https",
              redirectURL.user == nil,
              redirectURL.password == nil else {
            completionHandler(nil)
            finish(.failure(RemoteImageLoadError.invalidRedirect))
            return
        }

        var sanitizedRequest = newRequest
        sanitizedRequest.httpShouldHandleCookies = false
        sanitizedRequest.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(sanitizedRequest)
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
}
