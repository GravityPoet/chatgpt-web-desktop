import Foundation
import WebKit

enum CookieConsentSettings {
    static let defaultsKey = "ChatGPTSwiftWeb.RejectNonEssentialCookies"
    static let rejectionCookieNames = [
        "oai-allow-ne",
        "oai_consent_analytics",
        "oai_consent_marketing",
        "oai_consent_personalization",
    ]

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: defaultsKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }

    static func rejectionCookies(now: Date = Date()) -> [HTTPCookie] {
        let expiration = Calendar(identifier: .gregorian).date(byAdding: .month, value: 6, to: now)
            ?? now.addingTimeInterval(180 * 24 * 60 * 60)

        return rejectionCookieNames.compactMap { name in
            HTTPCookie(properties: [
                .domain: ".chatgpt.com",
                .expires: expiration,
                .name: name,
                .path: "/",
                .secure: "TRUE",
                .value: "false",
                .version: "0",
                HTTPCookiePropertyKey("SameSite"): "Lax",
            ])
        }
    }

    static func rejectionIsApplied(in cookies: [HTTPCookie]) -> Bool {
        rejectionCookieNames.allSatisfy { expectedName in
            cookies.contains { cookie in
                cookie.name == expectedName
                    && cookie.value.lowercased() == "false"
                    && cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "chatgpt.com"
            }
        }
    }

    static func applyIfEnabled(
        to dataStore: WKWebsiteDataStore,
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        completion: @escaping () -> Void
    ) {
        guard isEnabled(defaults: defaults) else {
            completion()
            return
        }

        let cookies = rejectionCookies(now: now)
        guard !cookies.isEmpty else {
            completion()
            return
        }

        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            dataStore.httpCookieStore.setCookie(cookie) {
                group.leave()
            }
        }
        group.notify(queue: .main, execute: completion)
    }
}
