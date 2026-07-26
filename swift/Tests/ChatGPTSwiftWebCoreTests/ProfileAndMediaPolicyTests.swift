import XCTest
@testable import ChatGPTSwiftWebCore

final class ProfileAndMediaPolicyTests: XCTestCase {
    func testWindowTitleDefaultsToAppNameOnly() {
        XCTAssertEqual(
            ProfileWindowTitle.format(profileName: "person@example.com", isDefault: false),
            "ChatGPT Swift"
        )
        XCTAssertEqual(
            ProfileWindowTitle.format(profileName: "工作号", isDefault: false),
            "ChatGPT Swift"
        )
    }

    func testProfileNameModeUsesEmailLocalPartOrCustomName() {
        XCTAssertEqual(
            ProfileWindowTitle.format(
                profileName: "demo_user01@example.com",
                isDefault: false,
                mode: .profileName
            ),
            "ChatGPT Swift — demo_user01"
        )
        XCTAssertEqual(
            ProfileWindowTitle.format(profileName: "工作号", isDefault: false, mode: .profileName),
            "ChatGPT Swift — 工作号"
        )
    }

    func testFullProfileNameModeCanShowCompleteEmail() {
        XCTAssertEqual(
            ProfileWindowTitle.format(
                profileName: "work@example.com",
                isDefault: false,
                mode: .fullProfileName
            ),
            "ChatGPT Swift — work@example.com"
        )
    }

    func testAuthorizedChatGPTMicrophoneRequestIsGrantedWithoutAnotherWebPrompt() {
        XCTAssertEqual(
            MediaCapturePermissionPolicy.decision(
                originScheme: "https",
                originHost: "chatgpt.com",
                kind: .microphone,
                microphoneStatus: .authorized,
                cameraStatus: .notDetermined
            ),
            .grant
        )
    }

    func testFirstTrustedRequestStillPromptsAndDeniedSystemPermissionIsDenied() {
        XCTAssertEqual(
            MediaCapturePermissionPolicy.decision(
                originScheme: "https",
                originHost: "chat.openai.com",
                kind: .microphone,
                microphoneStatus: .notDetermined,
                cameraStatus: .notDetermined
            ),
            .prompt
        )
        XCTAssertEqual(
            MediaCapturePermissionPolicy.decision(
                originScheme: "https",
                originHost: "chatgpt.com",
                kind: .microphone,
                microphoneStatus: .denied,
                cameraStatus: .authorized
            ),
            .deny
        )
    }

    func testThirdPartyOriginKeepsBrowserStylePromptEvenWhenSystemAccessIsAuthorized() {
        XCTAssertEqual(
            MediaCapturePermissionPolicy.decision(
                originScheme: "https",
                originHost: "example.com",
                kind: .microphone,
                microphoneStatus: .authorized,
                cameraStatus: .authorized
            ),
            .prompt
        )
    }
}
