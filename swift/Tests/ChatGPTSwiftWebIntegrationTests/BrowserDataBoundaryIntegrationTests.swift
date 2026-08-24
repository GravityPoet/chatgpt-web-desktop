import Foundation
import XCTest
@testable import ChatGPTSwiftWeb

final class BrowserDataBoundaryIntegrationTests: XCTestCase {
    func testCookieTransferKeepsOnlyOpenAIEcosystemDomains() throws {
        let allowed = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".chatgpt.com",
            .name: "session",
            .path: "/",
            .value: "redacted-test-value",
            .secure: "TRUE",
        ]))
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".example.com",
            .name: "tracking",
            .path: "/",
            .value: "must-not-transfer",
        ]))

        let transferable = BrowserDataBoundary.transferableCookies([allowed, unrelated])

        XCTAssertEqual(transferable.map(\.domain), [".chatgpt.com"])
        XCTAssertEqual(transferable.map(\.name), ["session"])
    }

    func testSensitiveFileWriterUsesPrivateModeAndAtomicBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTSwiftWeb-DataBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("export.json")
        let payload = Data("{\"safe\":true}".utf8)
        try BrowserDataBoundary.writeSensitiveData(payload, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }
}
