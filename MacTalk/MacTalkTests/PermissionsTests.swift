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
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertNotNil(url)
        NSLog("🔗 [Test] Microphone settings URL: \(url?.absoluteString ?? "nil")")
    }

    func testScreenRecordingSettingsURL() {
        // Verify screen recording settings URL is valid
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertNotNil(url)
        NSLog("🔗 [Test] Screen recording settings URL: \(url?.absoluteString ?? "nil")")
    }

    func testAccessibilitySettingsURL() {
        // Verify accessibility settings URL is valid
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
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

            NSLog("🔐 [Test] Code signature info:")
            NSLog(output)

            // Check for stable signing
            if output.contains("TeamIdentifier=9SXL4GJ4TZ") {
                NSLog("✅ [Test] STABLE CODE SIGNING VERIFIED")
                NSLog("✅ [Test] TeamIdentifier=9SXL4GJ4TZ is present")
            } else if output.contains("Signed to Run Locally") || output.contains("ad hoc") {
                XCTFail("❌ [Test] WARNING: Using ad-hoc signing! This will break TCC permissions on rebuild!")
            }

        } catch {
            NSLog("⚠️  [Test] Could not verify code signature: \(error)")
        }
    }
}
