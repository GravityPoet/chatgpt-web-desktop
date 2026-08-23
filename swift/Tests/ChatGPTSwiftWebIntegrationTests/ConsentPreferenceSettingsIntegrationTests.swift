import Foundation
import WebKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class CookieConsentSettingsIntegrationTests: XCTestCase {
    func testRejectNonEssentialCookiesIsEnabledByDefaultAndCanBeDisabled() throws {
        let suiteName = "ChatGPTSwiftWeb.CookieConsentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(CookieConsentSettings.isEnabled(defaults: defaults))
        CookieConsentSettings.setEnabled(false, defaults: defaults)
        XCTAssertFalse(CookieConsentSettings.isEnabled(defaults: defaults))
        CookieConsentSettings.setEnabled(true, defaults: defaults)
        XCTAssertTrue(CookieConsentSettings.isEnabled(defaults: defaults))
    }

    func testApplyingDefaultConsentSeedsOnlyChatGPTRejectionPreferences() throws {
        let suiteName = "ChatGPTSwiftWeb.CookieConsentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WKWebsiteDataStore.nonPersistent()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let applied = expectation(description: "consent cookies applied")
        var capturedCookies: [HTTPCookie] = []

        CookieConsentSettings.applyIfEnabled(to: store, defaults: defaults, now: now) {
            store.httpCookieStore.getAllCookies { cookies in
                capturedCookies = cookies.filter {
                    CookieConsentSettings.rejectionCookieNames.contains($0.name)
                }
                applied.fulfill()
            }
        }
        wait(for: [applied], timeout: 3)

        XCTAssertEqual(Set(capturedCookies.map(\.name)), Set(CookieConsentSettings.rejectionCookieNames))
        XCTAssertTrue(capturedCookies.allSatisfy { $0.value == "false" })
        XCTAssertTrue(CookieConsentSettings.rejectionIsApplied(in: capturedCookies))
        XCTAssertTrue(capturedCookies.allSatisfy {
            $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "chatgpt.com"
        })
        XCTAssertTrue(capturedCookies.allSatisfy { $0.path == "/" && $0.isSecure })
        XCTAssertTrue(capturedCookies.allSatisfy {
            guard let expiresDate = $0.expiresDate else {
                return false
            }
            return expiresDate.timeIntervalSince(now) > 150 * 24 * 60 * 60
                && expiresDate.timeIntervalSince(now) < 190 * 24 * 60 * 60
        })
    }

    func testDisabledPreferenceDoesNotSeedConsentCookies() throws {
        let suiteName = "ChatGPTSwiftWeb.CookieConsentSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        CookieConsentSettings.setEnabled(false, defaults: defaults)
        let store = WKWebsiteDataStore.nonPersistent()
        let applied = expectation(description: "disabled consent policy skipped")
        var capturedCookies: [HTTPCookie] = []

        CookieConsentSettings.applyIfEnabled(to: store, defaults: defaults) {
            store.httpCookieStore.getAllCookies { cookies in
                capturedCookies = cookies.filter {
                    CookieConsentSettings.rejectionCookieNames.contains($0.name)
                }
                applied.fulfill()
            }
        }
        wait(for: [applied], timeout: 3)

        XCTAssertTrue(capturedCookies.isEmpty)
    }

    func testClearingManagedCookiesPreservesOtherChatGPTCookies() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let seeded = expectation(description: "managed consent cookies seeded")
        CookieConsentSettings.applyIfEnabled(to: store) {
            seeded.fulfill()
        }
        wait(for: [seeded], timeout: 3)

        let unrelatedCookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".chatgpt.com",
            .name: "session-preserved-for-test",
            .path: "/",
            .value: "keep-me",
        ]))
        let inserted = expectation(description: "unrelated cookie inserted")
        store.httpCookieStore.setCookie(unrelatedCookie) {
            inserted.fulfill()
        }
        wait(for: [inserted], timeout: 3)

        let cleared = expectation(description: "managed consent cookies cleared")
        CookieConsentSettings.clearManagedRejectionCookies(from: store) {
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 3)

        let inspected = expectation(description: "cookies inspected")
        var remainingCookies: [HTTPCookie] = []
        store.httpCookieStore.getAllCookies { cookies in
            remainingCookies = cookies
            inspected.fulfill()
        }
        wait(for: [inspected], timeout: 3)

        XCTAssertFalse(CookieConsentSettings.rejectionIsApplied(in: remainingCookies))
        XCTAssertTrue(remainingCookies.contains {
            $0.name == "session-preserved-for-test" && $0.value == "keep-me"
        })
    }
}
