import AppKit
import XCTest
@testable import ChatGPTSwiftWeb

@MainActor
final class AppSettingsWindowControllerTests: XCTestCase {
    func testSettingsContentRemainsReachableWhenItExceedsWindowHeight() {
        let controller = AppSettingsWindowController(
            state: AppSettingsState(
                appVersion: "0.1.3 (3)",
                currentProfileName: String(repeating: "很长的账号空间名称", count: 8),
                startupProfileName: "默认",
                homepage: "https://chatgpt.com/" + String(repeating: "long-path/", count: 20),
                promptDraftRestoreEnabled: true,
                promptDraftSummary: "12000 个字符，仅保存在本机偏好中",
                backgroundCompletionNotificationsEnabled: true,
                notificationPermissionStatus: "已授权",
                profileIsolation: String(repeating: "独立 WKWebsiteDataStore；", count: 10),
                fingerprintName: "默认 Safari（不混淆）",
                enhancedPrivacyEnabled: false,
                webRTCProtectionEnabled: false,
                rejectNonEssentialCookiesEnabled: true,
                keepThirdPartyLinksInApp: true,
                windowTitleDisplayMode: .appNameOnly,
                notesAutomationStatus: "按需请求",
                updateStatus: "未检查",
                distributionStatus: "本地构建"
            ),
            callbacks: AppSettingsCallbacks(
                setPromptDraftRestore: { _ in },
                setBackgroundCompletionNotifications: { _ in },
                setWebRTCProtection: { _ in },
                setRejectNonEssentialCookies: { _ in },
                setThirdPartyLinksInApp: { _ in },
                setWindowTitleDisplayMode: { _ in },
                setEnhancedPrivacy: { _ in },
                openNotesAutomationPrivacy: {},
                showDiagnostics: {},
                checkForUpdates: {},
                openReleasePage: {}
            )
        )

        controller.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(controller.window?.styleMask.contains(.resizable) == true)
        XCTAssertTrue(controller.contentScrollView.hasVerticalScroller)
        XCTAssertNotNil(controller.contentScrollView.documentView)
        XCTAssertGreaterThan(
            controller.contentScrollView.documentView?.fittingSize.height ?? 0,
            controller.contentScrollView.contentSize.height
        )
    }
}
