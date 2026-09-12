import AppKit
import Foundation
import OSLog

// Kept outside main.swift so executable integration tests initialize these values lazily.
let chatGPTURL = URL(string: "https://chatgpt.com/")!
let appBundleIdentifier = "local.chatgpt-web.swift"
let releasePageURL = URL(string: "https://github.com/GravityPoet/chatgpt-web-desktop/releases")!
let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/GravityPoet/chatgpt-web-desktop/releases/latest")!
let browserLogger = Logger(subsystem: appBundleIdentifier, category: "Browser")
let mainFrameDefaultsKey = "ChatGPTSwiftWeb.MainWindowFrame"
let webZoomDefaultsKey = "ChatGPTSwiftWeb.WebViewZoom"
let backgroundCompletionNotificationsDefaultsKey = "ChatGPTSwiftWeb.BackgroundCompletionNotificationsEnabled"
let lastRunStartedAtDefaultsKey = "ChatGPTSwiftWeb.LastRunStartedAt"
let lastRunEndedAtDefaultsKey = "ChatGPTSwiftWeb.LastRunEndedAt"
let lastRunCleanExitDefaultsKey = "ChatGPTSwiftWeb.LastRunCleanExit"
let minimumWebZoom: CGFloat = 0.85
let maximumWebZoom: CGFloat = 1.40
let webZoomStep: CGFloat = 0.05
let maximumCookieImportBytes = 2 * 1024 * 1024
let maximumProfileImportBytes = 1 * 1024 * 1024
let maximumBridgeDownloadBytes = 64 * 1024 * 1024
let maximumBridgeDownloadPayloadCharacters = maximumBridgeDownloadBytes * 2 + 4096
let profilesDefaultsKey = "ChatGPTSwiftWeb.Profiles"
let currentProfileDefaultsKey = "ChatGPTSwiftWeb.CurrentProfileID"
let startupProfileDefaultsKey = "ChatGPTSwiftWeb.StartupProfileID"
let defaultProfileID = "default"
let profileHomepageDefaultsPrefix = "ChatGPTSwiftWeb.ProfileHomepage."
let profileFingerprintDefaultsPrefix = "ChatGPTSwiftWeb.ProfileFingerprint."
let profileFingerprintDisabledDefaultsPrefix = "ChatGPTSwiftWeb.ProfileFingerprintDisabled."
let profileEnhancedPrivacyDefaultsPrefix = "ChatGPTSwiftWeb.ProfileEnhancedPrivacy."
let webRTCProtectionDefaultsKey = "ChatGPTSwiftWeb.WebRTCProtectionEnabled"
let keepThirdPartyLinksInAppDefaultsKey = "ChatGPTSwiftWeb.KeepThirdPartyLinksInApp"
let smokeReportPathEnvironmentKey = "CHATGPT_SWIFT_SMOKE_REPORT_PATH"
let smokeTimeoutEnvironmentKey = "CHATGPT_SWIFT_SMOKE_TIMEOUT_SECONDS"
