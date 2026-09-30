import Foundation
import WebKit

/// Keeps Cloudflare challenge pages inside the normal WebKit session and exposes only
/// non-sensitive health signals. It deliberately does not solve or bypass challenges.
extension BrowserWindowController {
    static func isCloudflareChallengeNavigationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        if host == "challenges.cloudflare.com" || host.hasSuffix(".challenges.cloudflare.com") {
            return true
        }
        let path = url.path.lowercased()
        return path.hasPrefix("/cdn-cgi/challenge-platform/")
            || path.hasPrefix("/cdn-cgi/challenge/")
    }

    func beginCloudflareChallenge(reason: String) {
        guard !isDisposing else { return }
        if isCloudflareChallengeActive {
            if cloudflareChallengeLastReason != reason {
                cloudflareChallengeLoopCount += 1
            }
        } else {
            cloudflareChallengeCount += 1
            cloudflareChallengeStartedAt = Date()
        }
        isCloudflareChallengeActive = true
        lastFailureStatus = nil
        hasFailedNavigation = false
        cloudflareChallengeLastReason = reason
        refreshCloudflareChallengeCookieStatus()
        scheduleCloudflareChallengeWatchdog()
        updateNativeChromeStatus()
    }

    func completeCloudflareChallenge() {
        guard isCloudflareChallengeActive else { return }
        isCloudflareChallengeActive = false
        cloudflareChallengeResolvedCount += 1
        cloudflareChallengeStartedAt = nil
        cloudflareChallengeLastReason = "已完成"
        cancelCloudflareChallengeWatchdog()
        refreshCloudflareChallengeCookieStatus()
        updateNativeChromeStatus()
    }

    func failCloudflareChallenge(reason: String) {
        guard isCloudflareChallengeActive else { return }
        isCloudflareChallengeActive = false
        cloudflareChallengeStartedAt = nil
        cloudflareChallengeLastReason = reason
        cancelCloudflareChallengeWatchdog()
        refreshCloudflareChallengeCookieStatus()
        updateNativeChromeStatus()
    }

    func noteCloudflareNetworkChange() {
        guard isCloudflareChallengeActive else { return }
        cloudflareChallengeLoopCount += 1
        cloudflareChallengeLastReason = "网络接口发生变化；请保持当前网络不变"
        refreshCloudflareChallengeCookieStatus()
        scheduleCloudflareChallengeWatchdog()
        updateNativeChromeStatus()
    }

    func invalidateCloudflareChallengeTracking() {
        cloudflareChallengeWatchdogGeneration &+= 1
        cloudflareChallengeWatchdogWorkItem?.cancel()
        cloudflareChallengeWatchdogWorkItem = nil
        isCloudflareChallengeActive = false
        cloudflareChallengeStartedAt = nil
    }

    private func scheduleCloudflareChallengeWatchdog() {
        cloudflareChallengeWatchdogGeneration &+= 1
        let expected = cloudflareChallengeWatchdogGeneration
        cloudflareChallengeWatchdogWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isDisposing,
                  self.cloudflareChallengeWatchdogGeneration == expected,
                  self.isCloudflareChallengeActive else { return }
            self.cloudflareChallengeLastReason = "等待超过 12 秒；保持当前网络和窗口不变"
            self.refreshCloudflareChallengeCookieStatus()
            self.updateNativeChromeStatus()
        }
        cloudflareChallengeWatchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func cancelCloudflareChallengeWatchdog() {
        cloudflareChallengeWatchdogGeneration &+= 1
        cloudflareChallengeWatchdogWorkItem?.cancel()
        cloudflareChallengeWatchdogWorkItem = nil
    }

    private func refreshCloudflareChallengeCookieStatus() {
        guard !isDisposing else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let relevantNames = Set(cookies.filter { cookie in
                let domain = cookie.domain.lowercased()
                let isOpenAIHost = domain == "chatgpt.com"
                    || domain.hasSuffix(".chatgpt.com")
                    || domain == "openai.com"
                    || domain.hasSuffix(".openai.com")
                return isOpenAIHost && (cookie.name == "cf_clearance" || cookie.name == "__cf_bm")
            }.map(\.name))
            let clearance = relevantNames.contains("cf_clearance") ? "clearance=present" : "clearance=missing"
            let bot = relevantNames.contains("__cf_bm") ? "bot=present" : "bot=missing"
            DispatchQueue.main.async {
                guard let self, !self.isDisposing else { return }
                self.cloudflareChallengeCookieStatus = "\(clearance); \(bot)"
                self.updateNativeChromeStatus()
            }
        }
    }
}
