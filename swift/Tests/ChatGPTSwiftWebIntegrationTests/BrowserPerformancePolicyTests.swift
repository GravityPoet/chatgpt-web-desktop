import Foundation
import XCTest
@testable import ChatGPTSwiftWeb

final class BrowserPerformancePolicyTests: XCTestCase {
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
