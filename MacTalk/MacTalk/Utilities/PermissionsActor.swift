//
//  PermissionsActor.swift
//  MacTalk
//
//  Thread-safe actor for accessibility permission polling and diagnostics
//

import Foundation
@preconcurrency import ApplicationServices
import Security

/// Diagnostic information about the app's code signing and permission state
struct PermissionDiagnostics: Sendable {
    let bundleIdentifier: String
    let teamIdentifier: String
    let isAdHocSigned: Bool
    let isRunningFromXcode: Bool
    let executablePath: String
    let isAccessibilityTrusted: Bool

    /// Human-readable report for diagnostics display
    var formattedReport: String {
        """
        === MacTalk Permission Diagnostics ===

        Bundle ID: \(bundleIdentifier)
        Team ID: \(teamIdentifier.isEmpty ? "(none - ad-hoc signed)" : teamIdentifier)
        Executable: \(executablePath)

        Signing Status:
          Ad-hoc signed: \(isAdHocSigned ? "Yes" : "No")
          Running from Xcode: \(isRunningFromXcode ? "Yes" : "No")

        Accessibility: \(isAccessibilityTrusted ? "Trusted" : "NOT Trusted")

        === Troubleshooting ===
        \(troubleshootingNotes)
        """
    }

    private var troubleshootingNotes: String {
        var notes: [String] = []

        if isAdHocSigned {
            notes.append("- Ad-hoc signing detected. TCC may not persist permissions across rebuilds.")
            notes.append("  Fix: Use a stable Developer ID or Team ID for signing.")
        }

        if isRunningFromXcode {
            notes.append("- Running from Xcode/DerivedData. Permissions may reset on rebuild.")
            notes.append("  Fix: Test with the signed release build (./build.sh run).")
        }

        if !isAccessibilityTrusted {
            notes.append("- Accessibility permission not granted.")
            notes.append("  Fix: System Settings > Privacy & Security > Accessibility > Enable MacTalk")
            notes.append("  Reset: tccutil reset Accessibility \(bundleIdentifier)")
        }

        if notes.isEmpty {
            notes.append("No issues detected. If problems persist, try:")
            notes.append("  tccutil reset Accessibility \(bundleIdentifier)")
            notes.append("  Then re-grant permission in System Settings.")
        }

        return notes.joined(separator: "\n")
    }
}

/// Actor that manages accessibility permission checking and polling
actor PermissionsActor {
    static let shared = PermissionsActor()

    private var pollTask: Task<Void, Never>?
    private var didRequestAccessibilityPromptThisSession = false

    private init() {}

    // MARK: - Accessibility Permission (nonisolated for synchronous access)

    /// Check if accessibility permission is currently trusted
    /// This is nonisolated because AXIsProcessTrusted() is thread-safe
    nonisolated func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Request accessibility permission, optionally showing the system prompt
    /// - Parameter showPrompt: If true, shows the system permission dialog
    /// - Returns: true if already trusted
    nonisolated func requestAccessibility(showPrompt: Bool) -> Bool {
        let options: CFDictionary
        if showPrompt {
            // IMPORTANT: Use takeUnretainedValue() to avoid memory leak
            // kAXTrustedCheckOptionPrompt is a global constant, not a created object
            options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
        } else {
            options = [:] as CFDictionary
        }
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Session State

    func hasRequestedAccessibilityPromptThisSession() -> Bool {
        didRequestAccessibilityPromptThisSession
    }

    func markAccessibilityPromptRequestedThisSession() {
        didRequestAccessibilityPromptThisSession = true
    }

    private func clearPollTask() {
        pollTask = nil
    }

    // MARK: - Polling

    /// Start polling for accessibility permission grant
    /// - Parameters:
    ///   - timeout: Maximum time to poll (seconds)
    ///   - pollInterval: Time between checks (seconds)
    ///   - onGranted: Called when permission is granted
    ///   - onTimeout: Called if timeout is reached without grant
    func startPollingForGrant(
        timeout: TimeInterval = 60,
        pollInterval: TimeInterval = 0.5,
        onGranted: @MainActor @escaping @Sendable () -> Void,
        onTimeout: @MainActor @escaping @Sendable () -> Void
    ) {
        // Cancel any existing poll task
        pollTask?.cancel()

        pollTask = Task { [self] in
            let startTime = Date()
            let timeoutDate = startTime.addingTimeInterval(timeout)

            while !Task.isCancelled {
                // Check permission
                if self.isAccessibilityTrusted() {
                    NSLog("[PermissionsActor] Accessibility permission granted after polling")
                    await MainActor.run {
                        onGranted()
                    }
                    await self.clearPollTask()
                    return
                }

                // Check timeout
                if Date() >= timeoutDate {
                    NSLog("[PermissionsActor] Polling timeout reached")
                    await MainActor.run {
                        onTimeout()
                    }
                    await self.clearPollTask()
                    return
                }

                // Wait before next check
                do {
                    try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                } catch {
                    // Task was cancelled
                    await self.clearPollTask()
                    return
                }
            }
        }
    }

    /// Stop polling for permission
    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Diagnostics

    /// Get diagnostic information about code signing and permission state
    nonisolated func getDiagnostics() -> PermissionDiagnostics {
        let bundleID = Bundle.main.bundleIdentifier ?? "(unknown)"
        let execPath = Bundle.main.executablePath ?? "(unknown)"

        // Get code signing info using Security framework
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: execPath) as CFURL,
            [],
            &code
        )

        var teamID = ""
        var isAdHoc = false

        if createStatus == errSecSuccess, let code = code {
            var info: CFDictionary?
            let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)

            if infoStatus == errSecSuccess, let info = info as? [String: Any] {
                // Get Team ID using the official key
                if let team = info[kSecCodeInfoTeamIdentifier as String] as? String {
                    teamID = team
                }

                // Check for ad-hoc signing using flags
                if let flags = info[kSecCodeInfoFlags as String] as? UInt32 {
                    // kSecCodeSignatureAdhoc = 0x0002
                    isAdHoc = (flags & 0x0002) != 0
                }
            }
        }

        // Check if running from Xcode (DerivedData path)
        let isXcodeRun = execPath.contains("DerivedData") ||
                         execPath.contains("Xcode") ||
                         execPath.contains(".app/Contents/MacOS") == false

        return PermissionDiagnostics(
            bundleIdentifier: bundleID,
            teamIdentifier: teamID,
            isAdHocSigned: isAdHoc,
            isRunningFromXcode: isXcodeRun,
            executablePath: execPath,
            isAccessibilityTrusted: isAccessibilityTrusted()
        )
    }
}
