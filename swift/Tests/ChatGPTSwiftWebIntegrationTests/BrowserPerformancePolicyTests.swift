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
}
