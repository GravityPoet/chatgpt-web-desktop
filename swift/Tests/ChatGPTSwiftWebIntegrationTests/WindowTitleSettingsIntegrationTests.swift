import XCTest
@testable import ChatGPTSwiftWeb
import ChatGPTSwiftWebCore

final class WindowTitleSettingsIntegrationTests: XCTestCase {
    func testPreferenceDefaultsToAppNameOnlyAndPersistsExplicitChoice() throws {
        let suiteName = "ChatGPTSwiftWeb.WindowTitleSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(WindowTitleSettings.mode(defaults: defaults), .appNameOnly)

        WindowTitleSettings.setMode(.profileName, defaults: defaults)
        XCTAssertEqual(WindowTitleSettings.mode(defaults: defaults), .profileName)

        WindowTitleSettings.setMode(.fullProfileName, defaults: defaults)
        XCTAssertEqual(WindowTitleSettings.mode(defaults: defaults), .fullProfileName)
    }

    func testUnknownStoredValueFallsBackToPrivateDefault() throws {
        let suiteName = "ChatGPTSwiftWeb.WindowTitleSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("future-mode", forKey: WindowTitleSettings.defaultsKey)
        XCTAssertEqual(WindowTitleSettings.mode(defaults: defaults), .appNameOnly)
    }
}
