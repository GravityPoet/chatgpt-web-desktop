import AppKit
import ChatGPTSwiftWebCore
import Darwin
import Foundation
import OSLog
import Sparkle
import UniformTypeIdentifiers
import UserNotifications
import WebKit

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
let processStartedAt = Date()

enum SmokeTestEnvironment {
    static var reportPath: String? {
        let rawPath = ProcessInfo.processInfo.environment[smokeReportPathEnvironmentKey] ?? ""
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPath.isEmpty ? nil : trimmedPath
    }

    static var isEnabled: Bool {
        reportPath != nil
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let htmlURL: String?
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}

struct ProcessRunResult {
    let exitCode: Int32
    let output: String
    let errorOutput: String
}

final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func drain(_ fileHandle: FileHandle) {
        let collected = fileHandle.readDataToEndOfFile()
        lock.lock()
        data = collected
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let collected = data
        lock.unlock()
        return String(data: collected, encoding: .utf8) ?? ""
    }
}

struct PerformanceSample {
    let timestamp: Date
    let cpuPercent: Double
    let residentBytes: UInt64
    let footprintBytes: UInt64
}

final class ProcessPerformanceMonitor {
    private let lock = NSLock()
    private var timer: Timer?
    private var samples: [PerformanceSample] = []
    private var lastCPUTime: TimeInterval?
    private var lastWallTime: Date?
    private let maximumSamples = 180

    func start() {
        recordSample()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.recordSample()
        }
        timer?.tolerance = 2
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func diagnosticRows() -> [(String, String)] {
        let snapshot = snapshotSamples()
        guard !snapshot.isEmpty else {
            return [("性能采样", "暂无样本")]
        }

        let latest = snapshot[snapshot.count - 1]
        let cpuValues = snapshot.map(\.cpuPercent)
        let residentValues = snapshot.map(\.residentBytes)
        let footprintValues = snapshot.map(\.footprintBytes)
        return [
            ("性能采样窗口", "\(snapshot.count) 个样本，\(Self.dateText(snapshot[0].timestamp)) → \(Self.dateText(latest.timestamp))"),
            ("CPU 当前 / 平均 / 峰值", "\(Self.percentText(latest.cpuPercent)) / \(Self.percentText(Self.average(cpuValues))) / \(Self.percentText(cpuValues.max() ?? 0))"),
            ("RSS 当前 / 平均 / 峰值", "\(Self.bytesText(latest.residentBytes)) / \(Self.bytesText(Self.average(residentValues))) / \(Self.bytesText(residentValues.max() ?? 0))"),
            ("Footprint 当前 / 平均 / 峰值", "\(Self.bytesText(latest.footprintBytes)) / \(Self.bytesText(Self.average(footprintValues))) / \(Self.bytesText(footprintValues.max() ?? 0))"),
        ]
    }

    func csvText() -> String {
        let snapshot = snapshotSamples()
        let header = "timestamp,cpu_percent_one_core,resident_bytes,footprint_bytes"
        let body = snapshot.map { sample in
            "\(Self.dateText(sample.timestamp)),\(String(format: "%.2f", sample.cpuPercent)),\(sample.residentBytes),\(sample.footprintBytes)"
        }
        return ([header] + body).joined(separator: "\n") + "\n"
    }

    private func recordSample() {
        let now = Date()
        let cpuTime = Self.currentCPUTime()
        let memory = Self.currentMemory()
        let cpuPercent: Double
        if let lastCPUTime, let lastWallTime {
            let wallDelta = max(0.001, now.timeIntervalSince(lastWallTime))
            cpuPercent = max(0, (cpuTime - lastCPUTime) / wallDelta * 100)
        } else {
            cpuPercent = 0
        }

        let sample = PerformanceSample(
            timestamp: now,
            cpuPercent: cpuPercent,
            residentBytes: memory.residentBytes,
            footprintBytes: memory.footprintBytes
        )

        lock.lock()
        samples.append(sample)
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
        lastCPUTime = cpuTime
        lastWallTime = now
        lock.unlock()
    }

    private func snapshotSamples() -> [PerformanceSample] {
        lock.lock()
        let snapshot = samples
        lock.unlock()
        return snapshot
    }

    private static func currentCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0
        }
        let user = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func currentMemory() -> (residentBytes: UInt64, footprintBytes: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (0, 0)
        }
        return (UInt64(info.resident_size), UInt64(info.phys_footprint))
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func average(_ values: [UInt64]) -> UInt64 {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(UInt64(0), +) / UInt64(values.count)
    }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private static func bytesText(_ bytes: UInt64) -> String {
        guard bytes > 0 else {
            return "未知"
        }
        let mib = Double(bytes) / 1_048_576
        return String(format: "%.1f MiB", mib)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum BackgroundCompletionNotifications {
    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: backgroundCompletionNotificationsDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: backgroundCompletionNotificationsDefaultsKey)
    }
}

let applicationDelegate = AppDelegate()

if !SmokeTestEnvironment.isEnabled {
    SingleInstance.activateExistingInstanceOrAcquireLock()
}

let app = NSApplication.shared
app.delegate = applicationDelegate
app.run()

enum SingleInstance {
    // The descriptor is deliberately process-global and is only assigned after flock succeeds.
    // `nonisolated(unsafe)` documents that the OS file lock, not Swift actor isolation, is the
    // synchronization primitive for this single-instance guard.
    nonisolated(unsafe) private static var lockFileDescriptor: CInt = -1

    static func activateExistingInstanceOrAcquireLock() {
        let lockPath = lockFileURL().path
        let fileDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)

        guard fileDescriptor >= 0 else {
            return
        }

        if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            lockFileDescriptor = fileDescriptor
            return
        }

        close(fileDescriptor)
        activateExistingInstance()
        exit(0)
    }

    private static func lockFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appDirectory = supportDirectory.appendingPathComponent(appBundleIdentifier, isDirectory: true)
        try? FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent("single-instance.lock")
    }

    private static func activateExistingInstance() {
        let currentPID = getpid()
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)
        let existingApp = runningApps.first { $0.processIdentifier != currentPID }
        existingApp?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}
