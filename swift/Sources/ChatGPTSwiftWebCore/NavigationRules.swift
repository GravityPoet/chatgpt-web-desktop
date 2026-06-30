import Foundation

public enum NavigationRules {
    public enum NavigationType {
        case linkActivated
        case other
    }

    public static func validatedExternalURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") {
            return nil
        }
        let candidate: String
        if lower.hasPrefix("https://") {
            candidate = trimmed
        } else if lower.contains("://") {
            return nil
        } else {
            candidate = "https://" + trimmed
        }
        guard let url = URL(string: candidate),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              host.contains(".") else {
            return nil
        }
        return url
    }

    public static func shouldOpenInsideApp(_ url: URL, sourceURL: URL? = nil) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        if ["about", "blob", "data"].contains(scheme) {
            return true
        }

        guard scheme == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }

        return isChatGPTHost(host)
            || isOpenAIEcosystemHost(host)
            || isOpenAIAuthHost(host)
            || isOpenAISentinelHost(host)
            || isCloudflareChallengeURL(url)
            || isOAuthContinuationHost(url)
            || isAuthContinuationFromTrustedSource(url, sourceURL: sourceURL)
    }

    public static func shouldOpenInSystemBrowser(
        _ url: URL,
        sourceURL: URL? = nil,
        navigationType: NavigationType,
        keepThirdPartyLinksInApp: Bool
    ) -> Bool {
        if keepThirdPartyLinksInApp {
            return false
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        if shouldOpenInsideApp(url, sourceURL: sourceURL) {
            return false
        }
        return navigationType == .linkActivated
    }

    public static func shouldOpenNewWindowInSystemBrowser(
        _ url: URL,
        sourceURL: URL? = nil,
        keepThirdPartyLinksInApp: Bool
    ) -> Bool {
        if keepThirdPartyLinksInApp {
            return false
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return false
        }
        return !shouldOpenInsideApp(url, sourceURL: sourceURL)
    }

    public static func cleanTrackingParameters(from url: URL) -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else {
            return url
        }

        let filteredItems = queryItems.filter { !isTrackingQueryParameter($0.name) }
        if filteredItems.count == queryItems.count {
            return url
        }

        components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        return components.url ?? url
    }

    public static func isTrackingQueryParameter(_ name: String) -> Bool {
        let normalized = name.lowercased()
        if normalized.hasPrefix("utm_") {
            return true
        }

        let knownTrackingParameters: Set<String> = [
            "_hsenc",
            "_hsmi",
            "dclid",
            "fbclid",
            "gbraid",
            "gclid",
            "igshid",
            "li_fat_id",
            "mc_cid",
            "mc_eid",
            "mkt_tok",
            "msclkid",
            "oly_anon_id",
            "oly_enc_id",
            "rb_clickid",
            "scid",
            "ttclid",
            "twclid",
            "vero_id",
            "wbraid",
            "yclid",
        ]
        return knownTrackingParameters.contains(normalized)
    }

    public static func isChatGPTHost(_ host: String) -> Bool {
        host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") || host == "chat.openai.com" || host.hasSuffix(".chat.openai.com")
    }

    public static func isOpenAIAuthHost(_ host: String) -> Bool {
        host == "auth.openai.com" || host.hasSuffix(".auth.openai.com")
            || host == "auth0.openai.com" || host.hasSuffix(".auth0.openai.com")
            || host == "login.openai.com" || host.hasSuffix(".login.openai.com")
    }

    public static func isOpenAISentinelHost(_ host: String) -> Bool {
        host == "sentinel.openai.com"
    }

    public static func isOpenAIFamilyHost(_ host: String) -> Bool {
        host == "openai.com" || host.hasSuffix(".openai.com")
    }

    public static func isOpenAIEcosystemHost(_ host: String) -> Bool {
        isOpenAIFamilyHost(host)
            || host == "oaistatic.com" || host.hasSuffix(".oaistatic.com")
            || host == "oaiusercontent.com" || host.hasSuffix(".oaiusercontent.com")
            || host == "sora.com" || host.hasSuffix(".sora.com")
    }

    public static func isOAuthProviderHost(_ host: String) -> Bool {
        host == "accounts.google.com"
            || host.hasPrefix("accounts.google.")
            || host == "appleid.apple.com"
            || host == "login.microsoftonline.com"
            || host == "login.live.com"
            || host == "github.com"
            || host == "facebook.com"
            || host.hasSuffix(".facebook.com")
            || host == "twitter.com"
            || host == "x.com"
    }

    public static func isAuthLikeURL(_ url: URL, expanded: Bool = false) -> Bool {
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        let combined = path + "?" + query
        var markers = [
            "oauth",
            "auth",
            "authorize",
            "signin",
            "login",
            "account",
        ]
        if expanded {
            markers.append(contentsOf: [
                "callback",
                "continue",
                "credential",
                "passkey",
                "webauthn",
                "challenge",
                "verify",
                "mfa",
                "sso",
            ])
        }
        return markers.contains { combined.contains($0) }
    }

    public static func isOAuthContinuationHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        guard isOAuthProviderHost(host) else {
            return false
        }
        return isAuthLikeURL(url)
    }

    public static func isAuthContinuationFromTrustedSource(_ url: URL, sourceURL: URL?) -> Bool {
        guard let host = url.host?.lowercased(),
              let sourceHost = sourceURL?.host?.lowercased(),
              isTrustedAuthSourceHost(sourceHost),
              isAuthLikeURL(url, expanded: true)
        else {
            return false
        }

        return isOpenAIFamilyHost(host) || isOAuthProviderHost(host)
    }

    private static func isCloudflareChallengeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }
        return host == "challenges.cloudflare.com"
    }

    private static func isTrustedAuthSourceHost(_ host: String) -> Bool {
        isChatGPTHost(host)
            || isOpenAIAuthHost(host)
            || isOpenAIFamilyHost(host)
            || isOAuthProviderHost(host)
    }
}
