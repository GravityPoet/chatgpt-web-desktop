import XCTest
@testable import ChatGPTSwiftWebCore

final class NavigationRulesTests: XCTestCase {
    func testThirdPartyLinksDefaultToStayInsideAppUntilUserChangesPreference() {
        XCTAssertTrue(NavigationRules.defaultKeepThirdPartyLinksInApp)
    }

    func testValidatedExternalURLAddsHTTPSAndRejectsUnsafeSchemes() {
        XCTAssertEqual(NavigationRules.validatedExternalURL("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(NavigationRules.validatedExternalURL(" https://chatgpt.com/ ")?.absoluteString, "https://chatgpt.com/")
        XCTAssertNil(NavigationRules.validatedExternalURL("http://example.com"))
        XCTAssertNil(NavigationRules.validatedExternalURL("file:///tmp/test"))
        var credentialComponents = URLComponents()
        credentialComponents.scheme = "https"
        credentialComponents.user = "user"
        credentialComponents.password = "pass"
        credentialComponents.host = "example.com"
        XCTAssertNil(NavigationRules.validatedExternalURL(try XCTUnwrap(credentialComponents.url).absoluteString))
        XCTAssertNil(NavigationRules.validatedExternalURL("localhost"))
    }

    func testTrustedOriginAndInsecureThirdPartyNavigationPolicy() throws {
        XCTAssertTrue(NavigationRules.isTrustedAppOrigin(scheme: "https", host: "chatgpt.com"))
        XCTAssertTrue(NavigationRules.isTrustedAppOrigin(scheme: "https", host: "cdn.oaiusercontent.com"))
        XCTAssertFalse(NavigationRules.isTrustedAppOrigin(scheme: "https", host: "example.com"))
        XCTAssertFalse(NavigationRules.isTrustedAppOrigin(scheme: "http", host: "chatgpt.com"))

        let httpThirdParty = try XCTUnwrap(URL(string: "http://example.com/form"))
        let httpChatGPT = try XCTUnwrap(URL(string: "http://chatgpt.com/"))
        XCTAssertTrue(NavigationRules.shouldBlockInsecureThirdPartyNavigation(httpThirdParty))
        XCTAssertTrue(NavigationRules.shouldBlockInsecureThirdPartyNavigation(httpChatGPT))
    }

    func testWebViewNavigationRejectsExecutableSchemesAndCredentials() throws {
        let trustedSource = try XCTUnwrap(URL(string: "https://chatgpt.com/"))
        XCTAssertTrue(NavigationRules.isAllowedWebViewNavigationURL(URL(string: "https://example.com/")!))
        XCTAssertTrue(NavigationRules.isAllowedWebViewNavigationURL(URL(string: "about:blank")!))
        XCTAssertTrue(NavigationRules.isAllowedWebViewNavigationURL(URL(string: "data:text/html,ok")!, sourceURL: trustedSource))
        XCTAssertTrue(NavigationRules.isAllowedWebViewNavigationURL(URL(string: "blob:https://chatgpt.com/id")!, sourceURL: trustedSource))
        XCTAssertFalse(NavigationRules.isAllowedWebViewNavigationURL(URL(string: "file:///etc/hosts")!))
        XCTAssertFalse(NavigationRules.isAllowedWebViewNavigationURL(URL(string: "javascript:alert(1)")!))
        var credentialComponents = URLComponents()
        credentialComponents.scheme = "https"
        credentialComponents.user = "user"
        credentialComponents.password = "pass"
        credentialComponents.host = "example.com"
        credentialComponents.path = "/"
        XCTAssertFalse(NavigationRules.isAllowedWebViewNavigationURL(try XCTUnwrap(credentialComponents.url)))
    }

    func testSanitizedUserFacingURLRemovesAuthSecrets() throws {
        let authURL = try XCTUnwrap(URL(string: "https://accounts.google.com/o/oauth2/auth?code=secret&state=opaque#token"))
        let sanitized = try XCTUnwrap(NavigationRules.sanitizedUserFacingURL(authURL))
        XCTAssertEqual(sanitized.absoluteString, "https://accounts.google.com/o/oauth2/auth")

        let normalURL = try XCTUnwrap(URL(string: "https://example.com/article?view=full#section"))
        XCTAssertEqual(
            NavigationRules.sanitizedUserFacingURL(normalURL)?.absoluteString,
            "https://example.com/article?view=full"
        )

        let authorURL = try XCTUnwrap(URL(string: "https://example.com/author?sort=recent#bio"))
        XCTAssertEqual(
            NavigationRules.sanitizedUserFacingURL(authorURL)?.absoluteString,
            "https://example.com/author?sort=recent"
        )

        let continuationArticle = try XCTUnwrap(URL(string: "https://example.com/continue-reading?chapter=2"))
        XCTAssertEqual(
            NavigationRules.sanitizedUserFacingURL(continuationArticle)?.absoluteString,
            "https://example.com/continue-reading?chapter=2"
        )
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

    func testGoogleLookalikeHostIsNotTreatedAsTrustedOAuth() throws {
        let lookalike = try XCTUnwrap(URL(string: "https://accounts.google.evil.example/login"))
        let source = try XCTUnwrap(URL(string: "https://chatgpt.com/"))

        XCTAssertFalse(NavigationRules.isOAuthProviderHost("accounts.google.evil.example"))
        XCTAssertFalse(NavigationRules.shouldOpenInsideApp(lookalike, sourceURL: source))
        XCTAssertTrue(NavigationRules.shouldOpenInSystemBrowser(
            lookalike,
            sourceURL: source,
            navigationType: .linkActivated,
            keepThirdPartyLinksInApp: false
        ))
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
