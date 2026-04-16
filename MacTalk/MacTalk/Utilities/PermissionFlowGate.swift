//
//  PermissionFlowGate.swift
//  MacTalk
//
//  Pure permission-flow decisions for TDD-friendly UX gating
//

import Foundation

enum MicrophonePermissionState: Equatable {
    case granted
    case notDetermined
    case denied
    case restricted
    case unknown
}

enum MicrophonePermissionAction: Equatable {
    case proceed
    case requestPermission
    case openSettings
}

enum AccessibilityPermissionAction: Equatable {
    case none
    case showSystemPrompt
    case openSettings
}

enum PermissionFlowGate {
    static func microphoneAction(for state: MicrophonePermissionState) -> MicrophonePermissionAction {
        switch state {
        case .granted:
            return .proceed
        case .notDetermined:
            return .requestPermission
        case .denied, .restricted, .unknown:
            return .openSettings
        }
    }

    static func accessibilityAction(
        isTrusted: Bool,
        hasRequestedThisSession: Bool
    ) -> AccessibilityPermissionAction {
        if isTrusted {
            return .none
        }
        return hasRequestedThisSession ? .openSettings : .showSystemPrompt
    }
}
