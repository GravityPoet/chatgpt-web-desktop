import XCTest
@testable import ChatGPTSwiftWebCore

final class NavigationRulesTests: XCTestCase {
    func testValidatedExternalURLAddsHTTPSAndRejectsUnsafeSchemes() {
        XCTAssertEqual(NavigationRules.validatedExternalURL("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(NavigationRules.validatedExternalURL(" https://chatgpt.com/ ")?.absoluteString, "https://chatgpt.com/")
        XCTAssertNil(NavigationRules.validatedExternalURL("http://example.com"))
        XCTAssertNil(NavigationRules.validatedExternalURL("file:///tmp/test"))
        XCTAssertNil(NavigationRules.validatedExternalURL("localhost"))
    }

    func testCleanTrackingParametersRemovesKnownTrackingAndPreservesFunctionalQuery() throws {
        let url = try XCTUnwrap(URL(string: "https://chatgpt.com/c/abc?utm_source=x&foo=1&gclid=abc&bar=2"))
        let cleaned = NavigationRules.cleanTrackingParameters(from: url)
        let components = try XCTUnwrap(URLComponents(url: cleaned, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "chatgpt.com")
        XCTAssertEqual(components.path, "/c/abc")
        XCTAssertEqual(components.queryItems?.map(\.name), ["foo", "bar"])
    }

    func testRoutingKeepsOpenAIAndAuthFlowsInsideApp() throws {
        let chatGPT = try XCTUnwrap(URL(string: "https://chatgpt.com/"))
        let openAI = try XCTUnwrap(URL(string: "https://help.openai.com/en/"))
        let googleOAuth = try XCTUnwrap(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=abc"))
        let callback = try XCTUnwrap(URL(string: "https://openai.com/auth/callback"))
        let source = try XCTUnwrap(URL(string: "https://accounts.google.com/o/oauth2/v2/auth"))

        XCTAssertTrue(NavigationRules.shouldOpenInsideApp(chatGPT))
        XCTAssertTrue(NavigationRules.shouldOpenInsideApp(openAI))
        XCTAssertTrue(NavigationRules.shouldOpenInsideApp(googleOAuth))
        XCTAssertTrue(NavigationRules.shouldOpenInsideApp(callback, sourceURL: source))
    }

    func testThirdPartyLinksRespectBrowserPreferenceAndNavigationType() throws {
        let thirdParty = try XCTUnwrap(URL(string: "https://example.com/article"))
        let source = try XCTUnwrap(URL(string: "https://chatgpt.com/"))

        XCTAssertFalse(NavigationRules.shouldOpenInSystemBrowser(
            thirdParty,
            sourceURL: source,
            navigationType: .linkActivated,
            keepThirdPartyLinksInApp: true
        ))
        XCTAssertTrue(NavigationRules.shouldOpenInSystemBrowser(
            thirdParty,
            sourceURL: source,
            navigationType: .linkActivated,
            keepThirdPartyLinksInApp: false
        ))
        XCTAssertFalse(NavigationRules.shouldOpenInSystemBrowser(
            thirdParty,
            sourceURL: source,
            navigationType: .other,
            keepThirdPartyLinksInApp: false
        ))
        XCTAssertTrue(NavigationRules.shouldOpenNewWindowInSystemBrowser(
            thirdParty,
            sourceURL: source,
            keepThirdPartyLinksInApp: false
        ))
    }
}
