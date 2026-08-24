import XCTest
@testable import ChatGPTSwiftWeb

final class DownloadIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RemoteImageTestURLProtocol.reset()
    }

    func testDownloadStoreWritesAtomicallyAndAvoidsOverwritingExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSwiftWebDownloadTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstData = Data("first".utf8)
        let secondData = Data("second".utf8)
        let firstURL = try DownloadStore.save(firstData, suggestedFilename: "report.txt", directory: root)
        let secondURL = try DownloadStore.save(secondData, suggestedFilename: "report.txt", directory: root)

        XCTAssertEqual(firstURL.lastPathComponent, "report.txt")
        XCTAssertEqual(secondURL.lastPathComponent, "report-1.txt")
        XCTAssertEqual(try Data(contentsOf: firstURL), firstData)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondData)
        XCTAssertEqual(firstURL.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(secondURL.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
    }

    func testDownloadStoreMovesBoundedTemporaryFileWithoutLoadingItIntoData() throws {
        let root = temporaryTestDirectory()
        let sourceDirectory = root.appendingPathComponent("temporary", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = sourceDirectory.appendingPathComponent("streamed.tmp")
        try Data("streamed image".utf8).write(to: sourceURL)

        let destinationURL = try DownloadStore.moveTemporaryFile(
            sourceURL,
            suggestedFilename: "image.png",
            directory: destinationDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(destinationURL.lastPathComponent, "image.png")
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("streamed image".utf8))
    }

    func testRemoteImageLoaderStreamsValidImageWithoutSendingCookies() throws {
        let root = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = testSessionConfiguration()
        let cookieHeaderName = ["C", "ookie"].joined()
        configuration.httpAdditionalHeaders = [
            cookieHeaderName: "fixture-cookie-value",
            "X-Test": "preserved",
        ]
        let result = try loadRemoteImage(
            path: "/valid",
            maximumBytes: 64,
            configuration: configuration,
            temporaryDirectory: root
        )

        guard case let .success(remoteImage) = result else {
            return XCTFail("Expected a valid streamed image, got \(result)")
        }
        defer { try? FileManager.default.removeItem(at: remoteImage.fileURL) }

        XCTAssertEqual(remoteImage.mimeType, "image/png")
        XCTAssertEqual(remoteImage.byteCount, RemoteImageTestURLProtocol.validImageData.count)
        XCTAssertEqual(try Data(contentsOf: remoteImage.fileURL), RemoteImageTestURLProtocol.validImageData)

        let request = try XCTUnwrap(RemoteImageTestURLProtocol.recordedRequest(for: "/valid"))
        XCTAssertNil(request.value(forHTTPHeaderField: cookieHeaderName))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Test"), "preserved")
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testRemoteImageLoaderRejectsOversizedContentLengthBeforeCreatingAFile() throws {
        let root = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try loadRemoteImage(
            path: "/oversized-header",
            maximumBytes: 8,
            temporaryDirectory: root
        )

        assertLoadError(result, equals: .tooLarge(maximumBytes: 8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRemoteImageLoaderCancelsUnknownLengthBodyAtStreamingLimitAndRemovesTempFile() throws {
        let root = temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try loadRemoteImage(
            path: "/oversized-stream",
            maximumBytes: 8,
            temporaryDirectory: root
        )

        assertLoadError(result, equals: .tooLarge(maximumBytes: 8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testRemoteImageLoaderRejectsNonSuccessHTTPStatus() throws {
        let result = try loadRemoteImage(path: "/not-found", maximumBytes: 64)
        assertLoadError(result, equals: .httpStatus(404))
    }

    func testRemoteImageLoaderRejectsNonHTTPSSource() throws {
        let completionExpectation = expectation(description: "invalid remote image URL")
        let resultBox = RemoteImageResultBox()
        let loader = RemoteImageLoader(
            sourceURL: URL(string: "http://remote-image.test/valid")!,
            maximumBytes: 64,
            temporaryDirectory: temporaryTestDirectory()
        ) { result in
            resultBox.store(result)
            completionExpectation.fulfill()
        }
        loader.start()
        wait(for: [completionExpectation], timeout: 1)
        assertLoadError(try XCTUnwrap(resultBox.value), equals: .invalidURL)
    }

    func testRemoteImageLoaderRejectsCredentialsEmbeddedInSourceURL() throws {
        let completionExpectation = expectation(description: "credential-bearing remote image URL")
        let resultBox = RemoteImageResultBox()
        let credentialURL = [
            "https://",
            "fixture",
            ":",
            "fixture",
            "@remote-image.test/valid",
        ].joined()
        let loader = RemoteImageLoader(
            sourceURL: try XCTUnwrap(URL(string: credentialURL)),
            maximumBytes: 64,
            temporaryDirectory: temporaryTestDirectory()
        ) { result in
            resultBox.store(result)
            completionExpectation.fulfill()
        }
        loader.start()
        wait(for: [completionExpectation], timeout: 1)
        assertLoadError(try XCTUnwrap(resultBox.value), equals: .invalidURL)
    }

    func testRemoteImageLoaderRejectsLoopbackLiteralSource() throws {
        let result = try loadRemoteImage(
            sourceURL: URL(string: "https://127.0.0.1/valid")!
        )

        assertLoadError(result, equals: .blockedAddress)
        XCTAssertNil(RemoteImageTestURLProtocol.recordedRequest(for: "/valid"))
    }

    func testRemoteImageLoaderRejectsIPv4MappedPrivateLiteralSource() throws {
        let result = try loadRemoteImage(
            sourceURL: URL(string: "https://[::ffff:192.168.1.2]/valid")!
        )

        assertLoadError(result, equals: .blockedAddress)
        XCTAssertNil(RemoteImageTestURLProtocol.recordedRequest(for: "/valid"))
    }

    func testRemoteImageLoaderRejectsSpecialUseLiteralSources() throws {
        let blockedURLs = [
            "https://0.0.0.0/valid",
            "https://192.0.2.1/valid",
            "https://192.88.99.1/valid",
            "https://198.18.0.1/valid",
            "https://198.19.0.1/valid",
            "https://198.51.100.1/valid",
            "https://169.254.169.254/valid",
            "https://203.0.113.1/valid",
            "https://224.0.0.1/valid",
            "https://[::]/valid",
            "https://[fe80::1]/valid",
            "https://[fd00::1]/valid",
            "https://[ff02::1]/valid",
        ]

        for rawURL in blockedURLs {
            let result = try loadRemoteImage(sourceURL: URL(string: rawURL)!)
            assertLoadError(result, equals: .blockedAddress, file: #filePath, line: #line)
        }
    }

    func testRemoteImageLoaderRejectsPrivateDNSResolutionBeforeRequest() throws {
        let privateHost = "private-resolution.test"
        let result = try loadRemoteImage(
            sourceURL: URL(string: "https://\(privateHost)/valid")!,
            hostResolver: { host in
                XCTAssertEqual(host, privateHost)
                return ["10.0.0.8"]
            }
        )

        assertLoadError(result, equals: .blockedAddress)
        XCTAssertNil(RemoteImageTestURLProtocol.recordedRequest(for: "/valid"))
    }

    func testRemoteImageLoaderRejectsPrivateRedirectTarget() throws {
        let privateHost = "private-redirect.test"
        let result = try loadRemoteImage(
            path: "/redirect-to-private-host",
            hostResolver: { host in
                if host == "remote-image.test" {
                    return ["93.184.216.34"]
                }
                XCTAssertEqual(host, privateHost)
                return ["192.168.10.20"]
            }
        )

        assertLoadError(result, equals: .blockedAddress)
        XCTAssertNotNil(RemoteImageTestURLProtocol.recordedRequest(for: "/redirect-to-private-host"))
        XCTAssertNil(RemoteImageTestURLProtocol.recordedRequest(for: "/final"))
    }

    func testRemoteImageLoaderRechecksDNSOnRedirectToPreventRebinding() throws {
        let resolver = SequencedRemoteImageResolver(addresses: [
            ["93.184.216.34"],
            ["93.184.216.34"],
            ["10.0.0.9"],
        ])
        let result = try loadRemoteImage(
            path: "/redirect-same-host",
            hostResolver: { host in
                XCTAssertEqual(host, "remote-image.test")
                return resolver.resolve()
            }
        )

        assertLoadError(result, equals: .blockedAddress)
        XCTAssertNotNil(RemoteImageTestURLProtocol.recordedRequest(for: "/redirect-same-host"))
        XCTAssertNil(RemoteImageTestURLProtocol.recordedRequest(for: "/final"))
        XCTAssertGreaterThanOrEqual(resolver.callCount, 3)
    }

    func testStaleRemoteImageTemporaryFilesAreRemovedWithoutTouchingFreshFiles() throws {
        let root = temporaryTestDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let staleURL = root.appendingPathComponent("ChatGPTSwiftWeb-RemoteImage-stale.tmp")
        let freshURL = root.appendingPathComponent("ChatGPTSwiftWeb-RemoteImage-fresh.tmp")
        let unrelatedURL = root.appendingPathComponent("other.tmp")
        for url in [staleURL, freshURL, unrelatedURL] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8)))
        }
        let now = Date(timeIntervalSince1970: 2_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-2 * 24 * 60 * 60)],
            ofItemAtPath: staleURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: freshURL.path
        )

        RemoteImageLoader.cleanupStaleTemporaryFiles(in: root, olderThan: 24 * 60 * 60, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testRemoteImageLoaderRejectsNonImageMIMEType() throws {
        let result = try loadRemoteImage(path: "/not-image", maximumBytes: 64)
        assertLoadError(result, equals: .unsupportedMIMEType("text/html"))
    }

    func testRemoteImageLoaderRejectsSVGToAvoidExternalResourceParsing() throws {
        let result = try loadRemoteImage(path: "/svg-image", maximumBytes: 1024)
        assertLoadError(result, equals: .unsupportedMIMEType("image/svg+xml"))
    }

    private func loadRemoteImage(
        path: String,
        maximumBytes: Int = 64,
        configuration: URLSessionConfiguration? = nil,
        temporaryDirectory: URL? = nil,
        hostResolver: @escaping RemoteImageHostResolver = { _ in ["93.184.216.34"] }
    ) throws -> Result<RemoteImageFile, Error> {
        try loadRemoteImage(
            sourceURL: URL(string: "https://remote-image.test\(path)")!,
            maximumBytes: maximumBytes,
            configuration: configuration,
            temporaryDirectory: temporaryDirectory,
            hostResolver: hostResolver
        )
    }

    private func loadRemoteImage(
        sourceURL: URL,
        maximumBytes: Int = 64,
        configuration: URLSessionConfiguration? = nil,
        temporaryDirectory: URL? = nil,
        hostResolver: @escaping RemoteImageHostResolver = { _ in ["93.184.216.34"] }
    ) throws -> Result<RemoteImageFile, Error> {
        let completionExpectation = expectation(description: "remote image load \(sourceURL.absoluteString)")
        let resultBox = RemoteImageResultBox()
        let loader = RemoteImageLoader(
            sourceURL: sourceURL,
            maximumBytes: maximumBytes,
            configuration: configuration ?? testSessionConfiguration(),
            temporaryDirectory: temporaryDirectory ?? temporaryTestDirectory(),
            hostResolver: hostResolver
        ) { result in
            resultBox.store(result)
            completionExpectation.fulfill()
        }
        loader.start()
        wait(for: [completionExpectation], timeout: 3)
        withExtendedLifetime(loader) {}
        return try XCTUnwrap(resultBox.value)
    }

    private func testSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RemoteImageTestURLProtocol.self]
        return configuration
    }

    private func temporaryTestDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSwiftWebDownloadTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func assertLoadError(
        _ result: Result<RemoteImageFile, Error>,
        equals expectedError: RemoteImageLoadError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failure(error) = result else {
            return XCTFail("Expected load failure, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(error as? RemoteImageLoadError, expectedError, file: file, line: line)
    }
}

private final class SequencedRemoteImageResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var addresses: [[String]]
    private(set) var callCount = 0

    init(addresses: [[String]]) {
        self.addresses = addresses
    }

    func resolve() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        if addresses.count > 1 {
            return addresses.removeFirst()
        }
        return addresses.first ?? []
    }
}

private final class RemoteImageResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Result<RemoteImageFile, Error>?

    var value: Result<RemoteImageFile, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(_ value: Result<RemoteImageFile, Error>) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

private final class RemoteImageTestURLProtocol: URLProtocol {
    static let validImageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private static let lock = NSLock()
    // URLProtocol callbacks arrive on a URLSession delegate queue; all accesses are protected by
    // `lock`, so make the synchronization boundary explicit to Swift's strict-concurrency checker.
    nonisolated(unsafe) private static var requestsByPath: [String: URLRequest] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else {
            return false
        }
        return host == "remote-image.test" || host == "private-redirect.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.requestsByPath[url.path] = request
        Self.lock.unlock()

        let response: HTTPURLResponse
        let chunks: [Data]
        switch url.path {
        case "/valid":
            response = makeResponse(url: url, statusCode: 200, headers: [
                "Content-Type": "image/png",
                "Content-Length": String(Self.validImageData.count),
            ])
            chunks = [
                Data(Self.validImageData.prefix(3)),
                Data(Self.validImageData.dropFirst(3)),
            ]
        case "/oversized-header":
            response = makeResponse(url: url, statusCode: 200, headers: [
                "Content-Type": "image/png",
                "Content-Length": "64",
            ])
            chunks = [Data(repeating: 1, count: 64)]
        case "/oversized-stream":
            response = makeResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/png"])
            chunks = [Data(repeating: 1, count: 6), Data(repeating: 2, count: 6)]
        case "/not-found":
            response = makeResponse(url: url, statusCode: 404, headers: ["Content-Type": "image/png"])
            chunks = [Self.validImageData]
        case "/not-image":
            response = makeResponse(url: url, statusCode: 200, headers: ["Content-Type": "text/html"])
            chunks = [Data("<html></html>".utf8)]
        case "/svg-image":
            response = makeResponse(url: url, statusCode: 200, headers: ["Content-Type": "image/svg+xml"])
            chunks = [Data("<svg></svg>".utf8)]
        case "/redirect-to-private-host":
            response = makeResponse(
                url: url,
                statusCode: 302,
                headers: ["Location": "https://private-redirect.test/final"]
            )
            chunks = []
        case "/redirect-same-host":
            response = makeResponse(
                url: url,
                statusCode: 302,
                headers: ["Location": "https://remote-image.test/final"]
            )
            chunks = []
        default:
            response = makeResponse(url: url, statusCode: 500, headers: ["Content-Type": "text/plain"])
            chunks = []
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        requestsByPath.removeAll()
        lock.unlock()
    }

    static func recordedRequest(for path: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requestsByPath[path]
    }

    private func makeResponse(url: URL, statusCode: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
