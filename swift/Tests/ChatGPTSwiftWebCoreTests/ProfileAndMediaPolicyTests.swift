import XCTest
@testable import ChatGPTSwiftWebCore

final class ProfileAndMediaPolicyTests: XCTestCase {
    func testEmailProfileNameIsMaskedInWindowTitle() {
        let title = ProfileWindowTitle.format(profileName: "person@example.com", isDefault: false)
        XCTAssertEqual(title, "ChatGPT Swift · 邮箱账号（已遮罩）")
        XCTAssertFalse(title.contains("person"))
        XCTAssertFalse(title.contains("example.com"))
    }

    func testEmbeddedEmailIsAlsoMaskedButOrdinaryProfileNameRemainsVisible() {
        XCTAssertEqual(
            ProfileWindowTitle.format(profileName: "Work person@example.com", isDefault: false),
            "ChatGPT Swift · 邮箱账号（已遮罩）"
        )
        XCTAssertEqual(
            ProfileWindowTitle.format(profileName: "工作号", isDefault: false),
            "ChatGPT Swift · 工作号"
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
