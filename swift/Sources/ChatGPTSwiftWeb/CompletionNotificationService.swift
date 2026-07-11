import Foundation
import UserNotifications

enum CompletionNotificationAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var canSchedule: Bool {
        self == .authorized || self == .provisional
    }
}

struct CompletionNotificationRequest: Equatable {
    let identifier: String
    let title: String
    let body: String
}

protocol CompletionNotificationScheduling {
    func authorizationStatus(completion: @escaping (CompletionNotificationAuthorization) -> Void)
    func add(_ request: CompletionNotificationRequest, completion: @escaping (Error?) -> Void)
}

enum CompletionNotificationOutcome: Equatable {
    case disabled
    case notAuthorized(CompletionNotificationAuthorization)
    case scheduled
    case failed(String)
}

struct CompletionNotificationService {
    let scheduler: CompletionNotificationScheduling
    var makeIdentifier: () -> String = {
        "chatgpt-swift-completion-\(UUID().uuidString)"
    }

    func postIfAuthorized(
        enabled: Bool,
        context: String,
        completion: @escaping (CompletionNotificationOutcome) -> Void
    ) {
        guard enabled else {
            completion(.disabled)
            return
        }

        scheduler.authorizationStatus { status in
            guard status.canSchedule else {
                completion(.notAuthorized(status))
                return
            }

            let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = CompletionNotificationRequest(
                identifier: makeIdentifier(),
                title: "ChatGPT 回复完成",
                body: trimmedContext.isEmpty ? "ChatGPT" : trimmedContext
            )
            scheduler.add(request) { error in
                if let error {
                    completion(.failed(error.localizedDescription))
                } else {
                    completion(.scheduled)
                }
            }
        }
    }
}

final class SystemCompletionNotificationScheduler: CompletionNotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus(completion: @escaping (CompletionNotificationAuthorization) -> Void) {
        center.getNotificationSettings { settings in
            completion(Self.authorization(from: settings.authorizationStatus))
        }
    }

    func add(_ request: CompletionNotificationRequest, completion: @escaping (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        center.add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil),
            withCompletionHandler: completion
        )
    }

    private static func authorization(from status: UNAuthorizationStatus) -> CompletionNotificationAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }
}
