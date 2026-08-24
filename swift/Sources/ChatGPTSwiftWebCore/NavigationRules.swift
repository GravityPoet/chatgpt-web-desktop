import Foundation

public enum NavigationRules {
    public static let defaultKeepThirdPartyLinksInApp = true

    public enum NavigationType {
        case linkActivated
        case other
    }

    public static func validatedExternalURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
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
              host.contains("."),
              url.user == nil,
              url.password == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            return nil
        }
        return url
    }

    /// The only origins that may receive native privileges or native data bridges.
    /// Third-party pages can still be displayed when the user explicitly keeps them in-app,
    /// but they remain outside this trusted capability surface.
    public static func isTrustedAppOrigin(scheme: String, host: String) -> Bool {
        guard scheme.lowercased() == "https" else {
            return false
        }
        let normalizedHost = host.lowercased()
        return isChatGPTHost(normalizedHost) || isOpenAIEcosystemHost(normalizedHost)
    }

   public static func shouldBlockInsecureThirdPartyNavigation(_ url: URL, sourceURL: URL? = nil) -> Bool {
       guard url.scheme?.lowercased() == "http" else {
           return false
       }
       return !shouldOpenInsideApp(url, sourceURL: sourceURL)
   }

    /// Restricts WebKit navigation actions to web content schemes. Credentials and executable
    /// custom schemes never enter an app WebView or popup.
    public static func isAllowedWebViewNavigationURL(_ url: URL, sourceURL: URL? = nil) -> Bool {
        guard url.user == nil,
              url.password == nil,
              !url.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        switch url.scheme?.lowercased() {
        case "https":
            return url.host?.isEmpty == false
                && (url.port.map { (1 ... 65535).contains($0) } ?? true)
        case "about":
            return url.absoluteString.lowercased() == "about:blank"
        case "blob", "data":
            let sourceScheme = sourceURL?.scheme?.lowercased()
            return ["https", "blob", "data", "about"].contains(sourceScheme)
        default:
            return false
        }
    }

    /// Produces a URL safe to expose to another app or the clipboard. Authentication callbacks
    /// lose query/fragment values; all other URLs retain functional query parameters after tracking
    /// cleanup. HTTPS and credential-free URLs are the only accepted scheme.
    public static func sanitizedUserFacingURL(_ url: URL, sourceURL: URL? = nil) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              url.user == nil,
              url.password == nil,
              url.port.map({ (1 ... 65535).contains($0) }) ?? true,
              var components = URLComponents(url: cleanTrackingParameters(from: url), resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let sensitive = isAuthLikeURL(url, expanded: true)
            || isOAuthContinuationHost(url)
            || isAuthContinuationFromTrustedSource(url, sourceURL: sourceURL)
        components.fragment = nil
        if sensitive {
            components.query = nil
        }
        return components.url
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
        let host = host.lowercased()
        return host == "accounts.google.com"
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
        let pathSegments = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).lowercased() }
        var markers = [
            "oauth",
            "oauth2",
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
        if pathSegments.contains(where: { segment in
            markers.contains { marker in
                segment == marker || (marker == "oauth" && segment.hasPrefix("oauth2"))
            }
        }) {
            return true
        }

        let sensitiveQueryNames: Set<String> = [
            "access_token", "assertion", "authorization", "client_id", "code", "credential",
            "id_token", "login_hint", "nonce", "passkey", "redirect_uri", "response_type",
            "samlresponse", "scope", "state", "token", "verification_token",
        ]
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { item in
            let name = item.name.lowercased()
            return sensitiveQueryNames.contains(name)
                || (expanded && (name.hasSuffix("_token") || name.hasSuffix("_code")))
        } ?? false
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
