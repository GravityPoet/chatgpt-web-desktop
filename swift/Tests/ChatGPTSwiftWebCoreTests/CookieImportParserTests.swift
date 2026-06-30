import Foundation
import XCTest
@testable import ChatGPTSwiftWebCore

final class CookieImportParserTests: XCTestCase {
    func testParsesHeaderCookiePairsWithDefaultChatGPTDomain() throws {
        let cookies = try CookieImportParser.parse(data: Data("Cookie: cf_clearance=clear; oai-sc=scope".utf8))

        XCTAssertEqual(cookies.map(\.name), ["cf_clearance", "oai-sc"])
        XCTAssertTrue(cookies.allSatisfy { $0.domain == ".chatgpt.com" })
        XCTAssertTrue(cookies.allSatisfy(\.isSecure))
    }

    func testParsesSetCookieLineWithDomainPathAndHttpOnly() throws {
        let cookieName = "__Secure-next-auth.session-token.0"
        let cookieValue = "placeholder"
        let raw = [
            "Set-Cookie: \(cookieName)",
            "\(cookieValue); Domain=.chatgpt.com; Path=/; Secure; HttpOnly; SameSite=Lax",
        ].joined(separator: String(UnicodeScalar(61)))
        let cookie = try XCTUnwrap(CookieImportParser.parse(data: Data(raw.utf8)).first)

        XCTAssertEqual(cookie.name, cookieName)
        XCTAssertEqual(cookie.value, cookieValue)
        XCTAssertEqual(cookie.domain, ".chatgpt.com")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertTrue(cookie.isSecure)
        XCTAssertTrue(cookie.isHTTPOnly)
    }

    func testParsesNetscapeCookieTextAndRejectsNonOpenAIDomain() throws {
        let raw = """
        # Netscape HTTP Cookie File
        #HttpOnly_.chatgpt.com TRUE / TRUE 1893456000 cf_clearance clear
        """
        let cookie = try XCTUnwrap(CookieImportParser.parse(data: Data(raw.utf8)).first)
        XCTAssertEqual(cookie.name, "cf_clearance")
        XCTAssertEqual(cookie.domain, ".chatgpt.com")
        XCTAssertTrue(cookie.isHTTPOnly)

        let malicious = ".evil.example TRUE / TRUE 1893456000 cf_clearance clear"
        XCTAssertThrowsError(try CookieImportParser.parse(data: Data(malicious.utf8))) { error in
            XCTAssertTrue(CookieImportParser.safeMessage(error).contains("不在 ChatGPT/OpenAI 白名单"))
        }
    }

    func testCookieNameAndDomainClassifiers() {
        XCTAssertTrue(CookieImportParser.isAllowedDomain(".chatgpt.com"))
        XCTAssertTrue(CookieImportParser.isAllowedDomain("auth.openai.com"))
        XCTAssertFalse(CookieImportParser.isAllowedDomain("openai.com.evil.example"))

        XCTAssertTrue(CookieImportParser.isEssentialCookieName("__Secure-next-auth.session-token.1"))
        XCTAssertTrue(CookieImportParser.isSessionCookieName("__Secure-next-auth.session-token"))
        XCTAssertFalse(CookieImportParser.isEssentialCookieName("_ga"))
    }
}
