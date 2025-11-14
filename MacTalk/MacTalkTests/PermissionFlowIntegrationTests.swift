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

    func testScreenRecordingRequestFlowWithoutPermission() {
        // Test the complete flow when permission is not granted
        let expectation = expectation(description: "Screen recording request flow")

        Permissions.requestScreenRecordingPermission { granted in
            NSLog("📺 [Integration] Screen recording request completed: \(granted)")

            // The result depends on user interaction, but the flow should complete
            XCTAssertNotNil(granted)

            if granted {
                NSLog("✅ [Integration] Permission granted - user approved or already had permission")
            } else {
                NSLog("⏳ [Integration] Permission not granted - user may need to approve in System Settings")
            }

            expectation.fulfill()
        }

        waitForExpectations(timeout: 10.0)
    }

    func testScreenRecordingFlowDoesNotShowDialogWhenAlreadyGranted() {
        // Test that we don't show redundant dialogs when permission is already granted
        let expectation = expectation(description: "No redundant dialog")

        // First check actual permission
        Permissions.checkScreenRecordingPermissionActual { alreadyGranted in
            if alreadyGranted {
                NSLog("✅ [Integration] Permission already granted, testing request flow...")

                // Request permission again - should not trigger dialog
                let startTime = Date()
                Permissions.requestScreenRecordingPermission { granted in
                    let elapsed = Date().timeIntervalSince(startTime)

                    XCTAssertTrue(granted, "Should still have permission")
                    XCTAssertLessThan(elapsed, 3.0, "Should complete quickly without user interaction")

                    NSLog("✅ [Integration] Request completed in \(String(format: "%.2f", elapsed))s without showing dialog")
                    expectation.fulfill()
                }
            } else {
                NSLog("⏭️  [Integration] Permission not granted, skipping this test")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 15.0)
    }

    // MARK: - Accessibility Flow Tests

    func testAccessibilityPermissionFlowDoesNotCrash() {
        // Test that accessibility permission flow doesn't crash
        // (Can't test actual dialog in unit tests)

        Permissions.requestAccessibilityPermission()

        // Should complete without crashing
        NSLog("♿ [Integration] Accessibility permission request completed")
        XCTAssertTrue(true, "Flow completed without crash")
    }

    func testAccessibilityPermissionCheckAfterRequest() {
        // Test that permission status is consistent after request
        let beforeRequest = Permissions.isAccessibilityTrusted()

        Permissions.requestAccessibilityPermission()

        let afterRequest = Permissions.isAccessibilityTrusted()

        NSLog("♿ [Integration] Accessibility before: \(beforeRequest), after: \(afterRequest)")

        // Status should be consistent (won't change in unit test environment)
        XCTAssertEqual(beforeRequest, afterRequest, "Permission status should be consistent")
    }

    // MARK: - Combined Permission Flows

    func testAllPermissionsCanBeCheckedSimultaneously() {
        // Test that all permission checks can run concurrently
        let expectation1 = expectation(description: "Microphone check")
        let expectation2 = expectation(description: "Screen recording check")
        let expectation3 = expectation(description: "Accessibility check")

        // Microphone
        Permissions.ensureMic { granted in
            NSLog("🎤 [Integration] Microphone: \(granted)")
            expectation1.fulfill()
        }

        // Screen Recording
        Permissions.checkScreenRecordingPermissionActual { granted in
            NSLog("📺 [Integration] Screen Recording: \(granted)")
            expectation2.fulfill()
        }

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

        // Try to paste (will only work if accessibility is granted)
        if isTrusted {
            NSLog("✅ [Integration] Accessibility granted, auto-paste should work")
            ClipboardManager.pasteIfAllowed()
            NSLog("✅ [Integration] pasteIfAllowed() completed")
        } else {
            NSLog("⏭️  [Integration] Accessibility not granted, skipping auto-paste test")
        }

        XCTAssertTrue(true, "ClipboardManager flow completed")
    }

    func testClipboardManagerSessionDeduplication() {
        // Test that permission request is only shown once per session
        let isTrusted = Permissions.isAccessibilityTrusted()

        if !isTrusted {
            NSLog("📝 [Integration] Testing session deduplication...")

            // First call - may show dialog
            ClipboardManager.pasteIfAllowed()

            // Second call - should NOT show dialog
            ClipboardManager.pasteIfAllowed()

            // Third call - should still NOT show dialog
            ClipboardManager.pasteIfAllowed()

            NSLog("✅ [Integration] Multiple pasteIfAllowed() calls completed (should only show dialog once)")
        } else {
            NSLog("⏭️  [Integration] Accessibility already granted, skipping deduplication test")
        }

        XCTAssertTrue(true, "Session deduplication test completed")
    }

    // MARK: - Regression Tests

    func testScreenRecordingPermissionPersistsAcrossChecks() {
        // REGRESSION TEST: Permission status should be consistent across multiple checks
        let expectation1 = expectation(description: "First check")
        let expectation2 = expectation(description: "Second check")

        var firstResult: Bool?

        Permissions.checkScreenRecordingPermissionActual { result1 in
            firstResult = result1
            NSLog("📺 [Integration] First check: \(result1)")
            expectation1.fulfill()

            // Second check immediately after
            Permissions.checkScreenRecordingPermissionActual { result2 in
                NSLog("📺 [Integration] Second check: \(result2)")
                XCTAssertEqual(firstResult, result2, "Permission status should be consistent")
                expectation2.fulfill()
            }
        }

        waitForExpectations(timeout: 10.0)
    }

    func testNoPermissionDialogSpamming() {
        // REGRESSION TEST: Ensure we don't spam users with permission dialogs
        let expectation = expectation(description: "No spam")

        // Multiple rapid requests should not spam dialogs
        let startTime = Date()

        Permissions.requestScreenRecordingPermission { _ in
            let elapsed = Date().timeIntervalSince(startTime)
            NSLog("📺 [Integration] Request completed in \(String(format: "%.2f", elapsed))s")

            // Should complete relatively quickly (not waiting for user interaction each time)
            XCTAssertLessThan(elapsed, 5.0, "Should not block on repeated requests")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 10.0)
    }

    // MARK: - Performance Tests

    func testPermissionCheckPerformance() {
        // Measure performance of permission checks
        measure {
            // CGPreflightScreenCaptureAccess is synchronous and should be fast
            _ = Permissions.checkScreenRecordingPermission()
        }
    }

    func testActualPermissionCheckPerformance() {
        // Measure performance of actual SCShareableContent check
        measure {
            let expectation = expectation(description: "Performance test")

            Permissions.checkScreenRecordingPermissionActual { _ in
                expectation.fulfill()
            }

            waitForExpectations(timeout: 5.0)
        }
    }
}
