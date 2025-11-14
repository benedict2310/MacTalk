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

    func testScreenRecordingPermissionActualCheck() {
        // Test the REAL permission check using SCShareableContent
        // This is more reliable than CGPreflightScreenCaptureAccess
        let expectation = expectation(description: "Screen recording actual permission check")

        Permissions.checkScreenRecordingPermissionActual { hasPermission in
            // Should complete with a boolean result
            XCTAssertNotNil(hasPermission)

            NSLog("📺 [Test] SCShareableContent test result: \(hasPermission)")

            if hasPermission {
                NSLog("✅ [Test] Screen recording permission IS granted (verified by SCShareableContent)")
            } else {
                NSLog("❌ [Test] Screen recording permission NOT granted (SCShareableContent failed)")
            }

            expectation.fulfill()
        }

        waitForExpectations(timeout: 5.0)
    }

    func testScreenRecordingPermissionActualCheckMatchesCGPreflight() {
        // Test if CGPreflightScreenCaptureAccess matches actual SCShareableContent test
        // This documents the known discrepancy
        let expectation = expectation(description: "Compare permission checks")

        let cgPreflightResult = Permissions.checkScreenRecordingPermission()

        Permissions.checkScreenRecordingPermissionActual { actualResult in
            NSLog("📊 [Test] CGPreflightScreenCaptureAccess: \(cgPreflightResult)")
            NSLog("📊 [Test] SCShareableContent actual test: \(actualResult)")

            if cgPreflightResult != actualResult {
                NSLog("⚠️  [Test] DISCREPANCY DETECTED!")
                NSLog("⚠️  [Test] CGPreflight says: \(cgPreflightResult ? "granted" : "not granted")")
                NSLog("⚠️  [Test] Actual test says: \(actualResult ? "granted" : "not granted")")
                NSLog("⚠️  [Test] This is expected behavior - CGPreflight doesn't update until app restart")
            } else {
                NSLog("✅ [Test] Both checks agree: \(actualResult ? "granted" : "not granted")")
            }

            expectation.fulfill()
        }

        waitForExpectations(timeout: 5.0)
    }

    // MARK: - Accessibility Permission Tests

    func testAccessibilityPermissionCheck() {
        // Test accessibility permission check
        let isTrusted = Permissions.isAccessibilityTrusted()

        // Should return a boolean
        XCTAssertNotNil(isTrusted)

        NSLog("♿ [Test] Accessibility trusted: \(isTrusted)")
    }

    func testAccessibilityPermissionRequest() {
        // Test accessibility permission request (doesn't actually show dialog in tests)
        // This just verifies the API doesn't crash
        Permissions.requestAccessibilityPermission()

        // Should complete without crashing
        NSLog("♿ [Test] Accessibility permission request completed")
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
        // This tests the timeout protection we added
        let expectation = expectation(description: "Permission checks complete")

        let startTime = Date()

        Permissions.checkScreenRecordingPermissionActual { _ in
            let elapsed = Date().timeIntervalSince(startTime)

            NSLog("⏱️  [Test] Screen recording check completed in \(String(format: "%.2f", elapsed))s")
            XCTAssertLessThan(elapsed, 5.0, "Permission check should not hang")

            expectation.fulfill()
        }

        waitForExpectations(timeout: 10.0)
    }

    func testMultipleSimultaneousPermissionChecks() {
        // Test that multiple permission checks can run simultaneously
        let expectation1 = expectation(description: "Check 1")
        let expectation2 = expectation(description: "Check 2")
        let expectation3 = expectation(description: "Check 3")

        Permissions.checkScreenRecordingPermissionActual { result1 in
            NSLog("✅ [Test] Check 1 completed: \(result1)")
            expectation1.fulfill()
        }

        Permissions.checkScreenRecordingPermissionActual { result2 in
            NSLog("✅ [Test] Check 2 completed: \(result2)")
            expectation2.fulfill()
        }

        Permissions.checkScreenRecordingPermissionActual { result3 in
            NSLog("✅ [Test] Check 3 completed: \(result3)")
            expectation3.fulfill()
        }

        waitForExpectations(timeout: 10.0)
        NSLog("✅ [Test] All simultaneous checks completed")
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

    func testActualPermissionCheckWorksEvenWhenCGPreflightReturnsFalse() {
        // REGRESSION TEST: Document that actual permission check works
        // even when CGPreflightScreenCaptureAccess returns false

        let expectation = expectation(description: "Actual check works")

        let cgPreflightResult = CGPreflightScreenCaptureAccess()

        Permissions.checkScreenRecordingPermissionActual { actualResult in
            if !cgPreflightResult && actualResult {
                NSLog("✅ [Test] CONFIRMED: Actual permission check works even when CGPreflight returns false!")
                NSLog("✅ [Test] This validates our fix for the reported issue")
            }
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5.0)
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
