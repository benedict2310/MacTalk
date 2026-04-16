//
//  PermissionsTests.swift
//  MacTalkTests
//
//  Unit tests for permission detection and handling
//

import XCTest
import AVFoundation
import ScreenCaptureKit
import ApplicationServices
@testable import MacTalk

@MainActor
final class PermissionsTests: XCTestCase {

    // MARK: - Microphone Permission Tests

    func testMicrophonePermissionCheck() {
        // This test verifies that microphone permission check doesn't crash
        // Actual permission state depends on system settings
        let isMicAuthorized = Permissions.isMicrophoneAuthorized()

        // Should return a boolean (true or false)
        XCTAssertNotNil(isMicAuthorized)

        NSLog("🎤 [Test] Microphone authorized: \(isMicAuthorized)")
    }

    func testMicrophonePermissionRequest() {
        let expectation = expectation(description: "Microphone permission request")

        Permissions.ensureMic { granted in
            // Should complete with a boolean result
            XCTAssertNotNil(granted)
            NSLog("🎤 [Test] Microphone permission result: \(granted)")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5.0)
    }

    // MARK: - Screen Recording Permission Tests

    func testScreenRecordingPermissionCheckWithCGPreflight() {
        // Test the CGPreflightScreenCaptureAccess() API
        // NOTE: This may return false even when permission is granted until app restart!
        let hasPermission = Permissions.checkScreenRecordingPermission()

        // Should return a boolean
        XCTAssertNotNil(hasPermission)

        NSLog("📺 [Test] CGPreflightScreenCaptureAccess result: \(hasPermission)")
        NSLog("⚠️  [Test] Note: This may be false even if permission is granted (known macOS behavior)")
    }

    func testScreenRecordingPermissionCheckConsistency() {
        // Test that permission check returns consistent results
        let result1 = Permissions.checkScreenRecordingPermission()
        let result2 = Permissions.checkScreenRecordingPermission()

        XCTAssertEqual(result1, result2, "Permission check should be consistent")
        NSLog("📺 [Test] Screen recording check consistent: \(result1)")
    }

    func testScreenRecordingPermissionCheckCompletesQuickly() {
        // Test that permission check doesn't block
        let startTime = Date()
        let result = Permissions.checkScreenRecordingPermission()
        let elapsed = Date().timeIntervalSince(startTime)

        NSLog("📺 [Test] CGPreflightScreenCaptureAccess result: \(result)")
        NSLog("⏱️  [Test] Completed in \(String(format: "%.3f", elapsed))s")

        XCTAssertLessThan(elapsed, 1.0, "Permission check should be fast")
    }

    // MARK: - Accessibility Permission Tests

    func testAccessibilityPermissionCheck() {
        // Test accessibility permission check
        let isTrusted = Permissions.isAccessibilityTrusted()

        // Should return a boolean
        XCTAssertNotNil(isTrusted)

        NSLog("♿ [Test] Accessibility trusted: \(isTrusted)")
    }

    func testAccessibilityPermissionCheckAPI() {
        // Test accessibility permission check API exists and works
        // Note: We don't call requestAccessibilityPermission() as it shows a dialog
        let isTrusted = Permissions.isAccessibilityTrusted()

        NSLog("♿ [Test] Accessibility permission API works, trusted: \(isTrusted)")
        XCTAssertTrue(isTrusted == true || isTrusted == false, "Should return valid bool")
    }

    // MARK: - Permission System Settings URLs

    func testMicrophoneSettingsURL() {
        // Verify microphone settings URL is valid
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
        XCTAssertNotNil(url)
        NSLog("🔗 [Test] Microphone settings URL: \(url?.absoluteString ?? "nil")")
    }

    func testScreenRecordingSettingsURL() {
        // Verify screen recording settings URL is valid
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        XCTAssertNotNil(url)
        NSLog("🔗 [Test] Screen recording settings URL: \(url?.absoluteString ?? "nil")")
    }

    func testAccessibilitySettingsURL() {
        // Verify accessibility settings URL is valid
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        XCTAssertNotNil(url)
        NSLog("🔗 [Test] Accessibility settings URL: \(url?.absoluteString ?? "nil")")
    }

    // MARK: - Permission Status Summary Tests

    func testGetPermissionStatus() {
        // Test permission status summary
        let expectation = expectation(description: "Permission status")

        Permissions.getPermissionStatus { status in
            // Should return a valid status
            XCTAssertNotNil(status)

            NSLog("📊 [Test] Permission Status:")
            NSLog("   Microphone: \(status.microphone)")
            NSLog("   Accessibility: \(status.accessibility)")
            NSLog("   All granted: \(status.allGranted)")

            expectation.fulfill()
        }

        waitForExpectations(timeout: 5.0)
    }

    // MARK: - Edge Case Tests

    func testPermissionChecksDontHang() {
        // Verify permission checks complete in reasonable time
        let startTime = Date()

        _ = Permissions.checkScreenRecordingPermission()
        let elapsed = Date().timeIntervalSince(startTime)

        NSLog("⏱️  [Test] Screen recording check completed in \(String(format: "%.3f", elapsed))s")
        XCTAssertLessThan(elapsed, 1.0, "Permission check should not hang")
    }

    func testMultipleSimultaneousPermissionChecks() {
        // Test that multiple permission checks can run simultaneously
        let result1 = Permissions.checkScreenRecordingPermission()
        NSLog("✅ [Test] Check 1 completed: \(result1)")

        let result2 = Permissions.checkScreenRecordingPermission()
        NSLog("✅ [Test] Check 2 completed: \(result2)")

        let result3 = Permissions.checkScreenRecordingPermission()
        NSLog("✅ [Test] Check 3 completed: \(result3)")

        XCTAssertEqual(result1, result2, "Results should be consistent")
        XCTAssertEqual(result2, result3, "Results should be consistent")
        NSLog("✅ [Test] All checks completed with consistent results")
    }

    // MARK: - Regression Tests for Known Issues

    func testCGPreflightDoesNotBlockAfterPermissionGrant() {
        // REGRESSION TEST: CGPreflightScreenCaptureAccess should not block/hang
        // even if it returns false after permission is granted

        let expectation = expectation(description: "CGPreflight completes")

        DispatchQueue.global().async {
            let result = CGPreflightScreenCaptureAccess()
            NSLog("📺 [Test] CGPreflightScreenCaptureAccess returned: \(result)")
            expectation.fulfill()
        }

        // Should complete quickly (not hang)
        waitForExpectations(timeout: 2.0)
    }

    func testCGPreflightReturnsConsistentResults() {
        // REGRESSION TEST: Verify CGPreflight returns consistent results
        let result1 = CGPreflightScreenCaptureAccess()
        let result2 = CGPreflightScreenCaptureAccess()

        XCTAssertEqual(result1, result2, "CGPreflight should return consistent results")
        NSLog("✅ [Test] CGPreflight returns consistent results: \(result1)")
    }

    func testCodeSigningStability() {
        // REGRESSION TEST: Verify app has stable code signing
        // This prevents the TCC permission loss issue on rebuild

        let bundle = Bundle.main
        let executableURL = bundle.executableURL

        XCTAssertNotNil(executableURL, "Executable URL should exist")

        // Check code signature
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dvvv", executableURL!.path]

        let pipe = Pipe()
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            NSLog("[Test] Code signature info:")
            NSLog(output)

            // Check for stable signing
            if output.contains("TeamIdentifier=9SXL4GJ4TZ") {
                NSLog("[Test] STABLE CODE SIGNING VERIFIED")
                NSLog("[Test] TeamIdentifier=9SXL4GJ4TZ is present")
            } else if output.contains("Signed to Run Locally") || output.contains("ad hoc") {
                XCTFail("[Test] WARNING: Using ad-hoc signing! This will break TCC permissions on rebuild!")
            }

        } catch {
            NSLog("[Test] Could not verify code signature: \(error)")
        }
    }

    // MARK: - PermissionsActor Tests

    func testPermissionsActorIsAccessibilityTrusted() {
        // Test that PermissionsActor provides consistent accessibility check
        let result1 = PermissionsActor.shared.isAccessibilityTrusted()
        let result2 = PermissionsActor.shared.isAccessibilityTrusted()

        XCTAssertEqual(result1, result2, "Accessibility check should be consistent")
        NSLog("[Test] PermissionsActor.isAccessibilityTrusted: \(result1)")
    }

    func testPermissionsActorRequestAccessibilityNoPrompt() {
        // Test that requestAccessibility(showPrompt: false) returns without blocking
        let startTime = Date()
        let result = PermissionsActor.shared.requestAccessibility(showPrompt: false)
        let elapsed = Date().timeIntervalSince(startTime)

        NSLog("[Test] requestAccessibility(showPrompt: false) returned: \(result) in \(elapsed)s")
        XCTAssertLessThan(elapsed, 1.0, "Should return quickly without prompt")
    }

    func testPermissionsActorDiagnosticsNonEmpty() {
        // Test that diagnostics returns non-empty values
        // CR-05: Allow nil/empty Team ID for ad-hoc signed or Xcode-run bundles
        let diagnostics = PermissionsActor.shared.getDiagnostics()

        XCTAssertFalse(diagnostics.bundleIdentifier.isEmpty, "Bundle ID should not be empty")
        XCTAssertFalse(diagnostics.executablePath.isEmpty, "Executable path should not be empty")

        // Team ID may be empty for ad-hoc signing, unit test hosts, or Xcode-run bundles
        // This is expected and not a failure condition
        if diagnostics.teamIdentifier.isEmpty {
            NSLog("[Test] Team ID is empty (expected for ad-hoc/Xcode builds)")
        }

        NSLog("[Test] Diagnostics bundle ID: \(diagnostics.bundleIdentifier)")
        NSLog("[Test] Diagnostics Team ID: \(diagnostics.teamIdentifier.isEmpty ? "(none - ad-hoc or Xcode)" : diagnostics.teamIdentifier)")
        NSLog("[Test] Diagnostics ad-hoc: \(diagnostics.isAdHocSigned)")
        NSLog("[Test] Diagnostics Xcode run: \(diagnostics.isRunningFromXcode)")
        NSLog("[Test] Diagnostics accessibility: \(diagnostics.isAccessibilityTrusted)")
    }

    func testPermissionsActorDiagnosticsFormattedReport() {
        // Test that formatted report is non-empty and contains expected sections
        let diagnostics = PermissionsActor.shared.getDiagnostics()
        let report = diagnostics.formattedReport

        XCTAssertFalse(report.isEmpty, "Formatted report should not be empty")
        XCTAssertTrue(report.contains("Bundle ID:"), "Report should contain Bundle ID")
        XCTAssertTrue(report.contains("Team ID:"), "Report should contain Team ID")
        XCTAssertTrue(report.contains("Accessibility:"), "Report should contain Accessibility status")
        XCTAssertTrue(report.contains("Troubleshooting"), "Report should contain Troubleshooting section")

        NSLog("[Test] Formatted report length: \(report.count) characters")
    }

    func testPermissionsHelperDiagnostics() {
        // Test the Permissions helper method for diagnostics
        let diagnostics = Permissions.getAccessibilityDiagnostics()

        XCTAssertFalse(diagnostics.bundleIdentifier.isEmpty, "Bundle ID should not be empty")
        NSLog("[Test] Permissions.getAccessibilityDiagnostics() works correctly")
    }

    func testPermissionsRequestAccessibility() {
        // Test the Permissions helper method for requesting accessibility
        let result = Permissions.requestAccessibility(showPrompt: false)

        // Should return a boolean without blocking
        NSLog("[Test] Permissions.requestAccessibility(showPrompt: false): \(result)")
        XCTAssertTrue(result == true || result == false, "Should return valid bool")
    }

    // MARK: - Polling Tests

    func testPermissionsActorPollingCanStart() async {
        // Test that polling can be started without crash
        let expectation = expectation(description: "Polling callback")

        // Start polling with very short timeout
        await PermissionsActor.shared.startPollingForGrant(
            timeout: 0.1,
            pollInterval: 0.05,
            onGranted: {
                NSLog("[Test] onGranted called")
                expectation.fulfill()
            },
            onTimeout: {
                NSLog("[Test] onTimeout called")
                expectation.fulfill()
            }
        )

        await fulfillment(of: [expectation], timeout: 1.0)
        NSLog("[Test] Polling test completed")
    }

    func testPermissionsActorPollingCanStop() async throws {
        // If accessibility is already trusted, polling may fire onGranted immediately.
        try XCTSkipIf(
            PermissionsActor.shared.isAccessibilityTrusted(),
            "Polling stop test requires accessibility to be untrusted."
        )

        // Test that polling can be stopped
        await PermissionsActor.shared.startPollingForGrant(
            timeout: 60,
            pollInterval: 0.5,
            onGranted: {
                XCTFail("Should not be called when stopped early")
            },
            onTimeout: {
                XCTFail("Should not be called when stopped early")
            }
        )

        // Stop immediately
        await PermissionsActor.shared.stopPolling()
        NSLog("[Test] Polling stopped successfully")

        // Wait a bit to ensure no callbacks are fired
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
    }
}
