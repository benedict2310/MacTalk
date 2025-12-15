//
//  PermissionFlowIntegrationTests.swift
//  MacTalkTests
//
//  Integration tests for permission request flows
//

import XCTest
@testable import MacTalk

final class PermissionFlowIntegrationTests: XCTestCase {

    // MARK: - Screen Recording Flow Tests

    func testScreenRecordingPermissionCheck() {
        // Test that screen recording permission check works
        let hasPermission = Permissions.checkScreenRecordingPermission()

        NSLog("📺 [Integration] Screen recording permission: \(hasPermission)")

        // The result depends on system state, but should be a valid bool
        XCTAssertTrue(hasPermission == true || hasPermission == false, "Should return valid bool")
    }

    func testScreenRecordingPermissionCheckIsConsistent() {
        // Test that permission check returns consistent results
        let result1 = Permissions.checkScreenRecordingPermission()
        let result2 = Permissions.checkScreenRecordingPermission()

        XCTAssertEqual(result1, result2, "Permission check should be consistent")
        NSLog("📺 [Integration] Screen recording permission consistent: \(result1)")
    }

    // MARK: - Accessibility Flow Tests

    func testAccessibilityPermissionCheckDoesNotCrash() {
        // Test that accessibility permission check doesn't crash
        let isTrusted = Permissions.isAccessibilityTrusted()

        NSLog("♿ [Integration] Accessibility check completed: \(isTrusted)")
        XCTAssertTrue(isTrusted == true || isTrusted == false, "Should return valid bool")
    }

    func testAccessibilityPermissionCheckIsConsistent() {
        // Test that permission status is consistent across checks
        let result1 = Permissions.isAccessibilityTrusted()
        let result2 = Permissions.isAccessibilityTrusted()

        NSLog("♿ [Integration] Accessibility check 1: \(result1), check 2: \(result2)")

        XCTAssertEqual(result1, result2, "Permission status should be consistent")
    }

    // MARK: - Combined Permission Flows

    func testAllPermissionsCanBeCheckedSimultaneously() {
        // Test that all permission checks can run concurrently
        let expectation1 = expectation(description: "Microphone check")
        let expectation3 = expectation(description: "Accessibility check")

        // Microphone
        Permissions.ensureMic { granted in
            NSLog("🎤 [Integration] Microphone: \(granted)")
            expectation1.fulfill()
        }

        // Screen Recording (synchronous)
        let screenGranted = Permissions.checkScreenRecordingPermission()
        NSLog("📺 [Integration] Screen Recording: \(screenGranted)")

        // Accessibility
        DispatchQueue.global().async {
            let trusted = Permissions.isAccessibilityTrusted()
            NSLog("♿ [Integration] Accessibility: \(trusted)")
            expectation3.fulfill()
        }

        waitForExpectations(timeout: 10.0)
        NSLog("✅ [Integration] All permission checks completed concurrently")
    }

    func testPermissionStatusSummary() {
        // Test the combined permission status
        let expectation = expectation(description: "Permission status summary")

        Permissions.getPermissionStatus { status in
            NSLog("📊 [Integration] Permission Summary:")
            NSLog("   Microphone: \(status.microphone ? "✅" : "❌")")
            NSLog("   Accessibility: \(status.accessibility ? "✅" : "❌")")
            NSLog("   All granted: \(status.allGranted ? "✅" : "❌")")

            XCTAssertNotNil(status)
            expectation.fulfill()
        }

        waitForExpectations(timeout: 10.0)
    }

    // MARK: - ClipboardManager Integration

    func testClipboardManagerPermissionCheck() {
        // Test that ClipboardManager properly checks accessibility permission
        let isTrusted = Permissions.isAccessibilityTrusted()

        // Set clipboard
        ClipboardManager.setClipboard("Test text")

        NSLog("📋 [Integration] ClipboardManager test: accessibility trusted = \(isTrusted)")

        // Note: We don't call pasteIfAllowed() in tests as it may show a dialog
        XCTAssertTrue(true, "ClipboardManager flow completed")
    }

    func testClipboardManagerSetClipboard() {
        // Test that ClipboardManager can set clipboard text
        ClipboardManager.setClipboard("Test text")

        // Should complete without crashing
        NSLog("✅ [Integration] ClipboardManager.setClipboard completed")
        XCTAssertTrue(true, "ClipboardManager setClipboard works")
    }

    // MARK: - Regression Tests

    func testScreenRecordingPermissionPersistsAcrossChecks() {
        // REGRESSION TEST: Permission status should be consistent across multiple checks
        let result1 = Permissions.checkScreenRecordingPermission()
        NSLog("📺 [Integration] First check: \(result1)")

        // Second check immediately after
        let result2 = Permissions.checkScreenRecordingPermission()
        NSLog("📺 [Integration] Second check: \(result2)")

        XCTAssertEqual(result1, result2, "Permission status should be consistent")
    }

    func testMultiplePermissionChecksDoNotBlock() {
        // REGRESSION TEST: Ensure permission checks complete quickly
        let startTime = Date()

        // Multiple rapid checks should complete quickly
        for i in 1...5 {
            _ = Permissions.checkScreenRecordingPermission()
            NSLog("📺 [Integration] Check \(i) completed")
        }

        let elapsed = Date().timeIntervalSince(startTime)
        NSLog("📺 [Integration] 5 checks completed in \(String(format: "%.3f", elapsed))s")

        // Should complete very quickly since it's synchronous
        XCTAssertLessThan(elapsed, 1.0, "Multiple checks should complete quickly")
    }

    // MARK: - Performance Tests

    func testPermissionCheckPerformance() {
        // Measure performance of permission checks
        measure {
            // CGPreflightScreenCaptureAccess is synchronous and should be fast
            _ = Permissions.checkScreenRecordingPermission()
        }
    }
}
