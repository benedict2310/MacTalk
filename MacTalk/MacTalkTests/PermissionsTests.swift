//
//  PermissionsTests.swift
//  MacTalkTests
//
//  Pure permission-policy and diagnostics-formatting tests. TCC/system behavior
//  belongs in an explicitly provisioned integration suite.
//

import XCTest
@testable import MacTalk

final class PermissionsTests: XCTestCase {
    func test_effectiveAutoPasteRequiresPreferenceAndCurrentTrust() {
        XCTAssertTrue(AutoPastePermissionPolicy.effectiveAutoPaste(
            storedPreference: true,
            accessibilityTrusted: true
        ))
        XCTAssertFalse(AutoPastePermissionPolicy.effectiveAutoPaste(
            storedPreference: true,
            accessibilityTrusted: false
        ))
        XCTAssertFalse(AutoPastePermissionPolicy.effectiveAutoPaste(
            storedPreference: false,
            accessibilityTrusted: true
        ))
        XCTAssertFalse(AutoPastePermissionPolicy.effectiveAutoPaste(
            storedPreference: false,
            accessibilityTrusted: false
        ))
    }

    func test_staleApprovalResetIsLimitedToUntrustedLocalBuilds() {
        XCTAssertTrue(AutoPastePermissionPolicy.shouldResetStaleAccessibilityApproval(
            accessibilityTrusted: false,
            isAdHocSigned: true,
            isRunningFromXcode: false
        ))
        XCTAssertTrue(AutoPastePermissionPolicy.shouldResetStaleAccessibilityApproval(
            accessibilityTrusted: false,
            isAdHocSigned: false,
            isRunningFromXcode: true
        ))
        XCTAssertFalse(AutoPastePermissionPolicy.shouldResetStaleAccessibilityApproval(
            accessibilityTrusted: true,
            isAdHocSigned: true,
            isRunningFromXcode: true
        ))
        XCTAssertFalse(AutoPastePermissionPolicy.shouldResetStaleAccessibilityApproval(
            accessibilityTrusted: false,
            isAdHocSigned: false,
            isRunningFromXcode: false
        ))
    }

    func test_diagnosticsReportIncludesIdentityAndPermissionState() {
        let diagnostics = PermissionDiagnostics(
            bundleIdentifier: "com.example.MacTalk",
            teamIdentifier: "TEAM123",
            isAdHocSigned: false,
            isRunningFromXcode: false,
            executablePath: "/Applications/MacTalk.app/Contents/MacOS/MacTalk",
            isAccessibilityTrusted: true
        )

        let report = diagnostics.formattedReport

        XCTAssertTrue(report.contains("Bundle ID: com.example.MacTalk"))
        XCTAssertTrue(report.contains("Team ID: TEAM123"))
        XCTAssertTrue(report.contains("Accessibility: Trusted"))
        XCTAssertTrue(report.contains("No issues detected"))
    }

    func test_diagnosticsReportExplainsUntrustedAdHocBuild() {
        let diagnostics = PermissionDiagnostics(
            bundleIdentifier: "com.example.MacTalk",
            teamIdentifier: "",
            isAdHocSigned: true,
            isRunningFromXcode: true,
            executablePath: "/tmp/MacTalk",
            isAccessibilityTrusted: false
        )

        let report = diagnostics.formattedReport

        XCTAssertTrue(report.contains("Team ID: (none - ad-hoc signed)"))
        XCTAssertTrue(report.contains("Ad-hoc signing detected"))
        XCTAssertTrue(report.contains("Running from Xcode/DerivedData"))
        XCTAssertTrue(report.contains("Accessibility permission not granted"))
    }
}
