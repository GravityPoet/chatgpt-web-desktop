import Foundation
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

final class BrowserPerformancePolicyTests: XCTestCase {
    func testNativeProfileKeepsWebKitBaseUserAgentAndAppendsInstalledSafariVersion() {
        let controller = BrowserWindowController(
            initialURL: nil,
            title: "Native User Agent Test",
            isPopup: false,
            persistent: false,
            profileID: nil
        )
        defer { controller.window.close() }

        XCTAssertTrue(controller.webView.customUserAgent?.isEmpty ?? true)
        XCTAssertEqual(
            controller.webView.configuration.applicationNameForUserAgent,
            SafariUserAgentPolicy.currentApplicationName
        )
    }

    func testNativePopupConfigurationAlsoGetsInstalledSafariProductToken() {
        let configuration = WKWebViewConfiguration()
        let controller = BrowserWindowController(
            initialURL: nil,
            title: "Native Popup User Agent Test",
            isPopup: true,
            persistent: false,
            profileID: nil,
            configuration: configuration
        )
        defer { controller.window.close() }

        XCTAssertEqual(
            controller.webView.configuration.applicationNameForUserAgent,
            SafariUserAgentPolicy.currentApplicationName
        )
    }

    func testDownloadBridgeNeverIncludesCookiesForCrossOriginImages() {
        XCTAssertTrue(BrowserWindowController.downloadBridgeScript.contains("url.origin === location.origin"))
        XCTAssertTrue(BrowserWindowController.downloadBridgeScript.contains("credentials: 'same-origin'"))
        XCTAssertTrue(BrowserWindowController.downloadBridgeScript.contains("cookie-free URLSession"))
    }

    func testSafariUserAgentPolicyAcceptsOnlyNumericVersions() {
        XCTAssertEqual(
            SafariUserAgentPolicy.applicationName(safariVersion: "17.6.1"),
            "Version/17.6.1 Safari/605.1.15"
        )
        XCTAssertNil(SafariUserAgentPolicy.applicationName(safariVersion: "17.6 beta"))
        XCTAssertNil(SafariUserAgentPolicy.applicationName(safariVersion: "17..6"))
        XCTAssertNil(SafariUserAgentPolicy.applicationName(safariVersion: nil))
    }

    func testOnlyPersistentMainWindowsWriteTheRestoredFrame() {
        XCTAssertTrue(BrowserPerformancePolicy.shouldPersistWindowFrame(persistent: true, isPopup: false))
        XCTAssertFalse(BrowserPerformancePolicy.shouldPersistWindowFrame(persistent: false, isPopup: false))
        XCTAssertFalse(BrowserPerformancePolicy.shouldPersistWindowFrame(persistent: true, isPopup: true))
    }

    func testNativeProfileSkipsExitTimezoneRefresh() {
        XCTAssertFalse(BrowserPerformancePolicy.shouldRefreshExitTimezoneCache(hasExplicitFingerprint: false))
        XCTAssertTrue(BrowserPerformancePolicy.shouldRefreshExitTimezoneCache(hasExplicitFingerprint: true))
    }

    func testToolbarStatusNeverLabelsHostlessContentAsChatGPT() throws {
        XCTAssertEqual(
            BrowserWindowController.statusLocationText(for: try XCTUnwrap(URL(string: "https://chatgpt.com/c/example"))),
            "chatgpt.com"
        )
        XCTAssertEqual(
            BrowserWindowController.statusLocationText(for: try XCTUnwrap(URL(string: "about:blank"))),
            "about:"
        )
        XCTAssertEqual(BrowserWindowController.statusLocationText(for: nil), "未载入")
    }
}
