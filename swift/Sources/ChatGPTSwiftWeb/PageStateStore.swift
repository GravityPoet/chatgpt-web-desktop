import Foundation
import ChatGPTSwiftWebCore

struct ProfilePageState: Codable, Equatable {
    var path: String
    var scrollTop: Double = 0
    var trail: [Int] = []

    var url: URL? {
        guard BrowserWindowController.validDraftPath(path), !path.hasPrefix("//"),
              path == "/" || path.hasPrefix("/c/") || path.hasPrefix("/g/") || path.hasPrefix("/projects") else { return nil }
        return URL(string: "https://chatgpt.com" + path)
    }
}

enum ProfileSessionStore {
    private static func key(_ profileID: String) -> String { "ChatGPTSwiftWeb.PageState." + profileID }

    static func load(profileID: String, defaults: UserDefaults = .standard) -> ProfilePageState? {
        guard let data = defaults.data(forKey: key(profileID)),
              let state = try? JSONDecoder().decode(ProfilePageState.self, from: data), state.url != nil else { return nil }
        return state
    }

    static func save(_ state: ProfilePageState, profileID: String, defaults: UserDefaults = .standard) {
        guard state.url != nil, state.scrollTop.isFinite, (0...10_000_000).contains(state.scrollTop),
              state.trail.count <= 24, state.trail.allSatisfy({ (0...100_000).contains($0) }),
              let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(profileID))
    }

    static func clear(profileID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(profileID))
        defaults.removeObject(forKey: mainFrameDefaultsKey + "." + profileID)
    }
}
