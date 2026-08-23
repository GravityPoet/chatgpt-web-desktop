import Foundation
import XCTest
@testable import ChatGPTSwiftWeb

final class PromptDraftStoreIntegrationTests: XCTestCase {
    func testClearingDraftRemovesStoredTextForOnlyThatProfile() throws {
        let suiteName = "ChatGPTSwiftWeb.PromptDraftStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = "profile-a"
        let otherProfileID = "profile-b"

        PromptDraftStore.saveDraft("sensitive local draft", profileID: profileID, defaults: defaults)
        PromptDraftStore.saveDraft("other draft", profileID: otherProfileID, defaults: defaults)
        PromptDraftStore.clearDraft(for: profileID, defaults: defaults)

        XCTAssertEqual(PromptDraftStore.draft(for: profileID, defaults: defaults), "")
        XCTAssertEqual(PromptDraftStore.draft(for: otherProfileID, defaults: defaults), "other draft")
    }
}
