import Foundation

enum BrowserPerformancePolicy {
    static let windowFramePersistenceDelay: TimeInterval = 0.3

    static func shouldPersistWindowFrame(persistent: Bool, isPopup: Bool) -> Bool {
        persistent && !isPopup
    }

    static func shouldRefreshExitTimezoneCache(hasExplicitFingerprint: Bool) -> Bool {
        hasExplicitFingerprint
    }
}
