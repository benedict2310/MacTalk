import Foundation

@main
struct PermissionFlowGateTests {
    static func main() {
        expectMicrophone(.granted, .proceed)
        expectMicrophone(.notDetermined, .requestPermission)
        expectMicrophone(.denied, .openSettings)
        expectMicrophone(.restricted, .openSettings)
        expectMicrophone(.unknown, .openSettings)

        expectAccessibility(isTrusted: true, hasRequestedThisSession: false, .none)
        expectAccessibility(isTrusted: false, hasRequestedThisSession: false, .showSystemPrompt)
        expectAccessibility(isTrusted: false, hasRequestedThisSession: true, .openSettings)

        print("permission flow gate tests passed")
    }

    private static func expectMicrophone(
        _ state: MicrophonePermissionState,
        _ expected: MicrophonePermissionAction
    ) {
        let actual = PermissionFlowGate.microphoneAction(for: state)
        precondition(actual == expected, "expected microphone action \(expected) for \(state), got \(actual)")
    }

    private static func expectAccessibility(
        isTrusted: Bool,
        hasRequestedThisSession: Bool,
        _ expected: AccessibilityPermissionAction
    ) {
        let actual = PermissionFlowGate.accessibilityAction(
            isTrusted: isTrusted,
            hasRequestedThisSession: hasRequestedThisSession
        )
        precondition(actual == expected, "expected accessibility action \(expected), got \(actual)")
    }
}
