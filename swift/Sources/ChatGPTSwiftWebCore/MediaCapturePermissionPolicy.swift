import Foundation

public enum MediaDeviceAuthorizationStatus {
    case notDetermined
    case restricted
    case denied
    case authorized
}

public enum MediaCaptureKind {
    case camera
    case microphone
    case cameraAndMicrophone
}

public enum MediaCapturePermissionDecision: Equatable {
    case prompt
    case grant
    case deny
}

public enum MediaCapturePermissionPolicy {
    public static func decision(
        originScheme: String,
        originHost: String,
        kind: MediaCaptureKind,
        microphoneStatus: MediaDeviceAuthorizationStatus,
        cameraStatus: MediaDeviceAuthorizationStatus
    ) -> MediaCapturePermissionDecision {
        let normalizedHost = originHost.lowercased()
        let isTrustedOrigin = originScheme.lowercased() == "https"
            && (NavigationRules.isChatGPTHost(normalizedHost) || NavigationRules.isOpenAIFamilyHost(normalizedHost))

        guard isTrustedOrigin else {
            return .prompt
        }

        let relevantStatuses: [MediaDeviceAuthorizationStatus]
        switch kind {
        case .microphone:
            relevantStatuses = [microphoneStatus]
        case .camera:
            relevantStatuses = [cameraStatus]
        case .cameraAndMicrophone:
            relevantStatuses = [cameraStatus, microphoneStatus]
        }

        if relevantStatuses.contains(where: { $0 == .denied || $0 == .restricted }) {
            return .deny
        }
        if relevantStatuses.allSatisfy({ $0 == .authorized }) {
            return .grant
        }
        return .prompt
    }
}
