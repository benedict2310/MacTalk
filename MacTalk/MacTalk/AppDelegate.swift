//
//  AppDelegate.swift
//  MacTalk
//
//  Created by MacTalk Development Team
//  Copyright © 2025 MacTalk. All rights reserved.
//

import AppKit

// Note: Entry point is now in main.swift (explicit initialization)
// This fixes macOS 26 initialization issues with @main attribute
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    override init() {
        // FIRST THING: Initialize debug logger
        _ = DebugLogger.shared
        DLOG("=== AppDelegate.init() START ===")

        super.init()

        DLOG("AppDelegate.init() - super.init() completed")
        NSLog("🚀 [MacTalk] AppDelegate.init() called")
        DLOG("=== AppDelegate.init() END ===")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        DLOG("=== applicationWillFinishLaunching START ===")
        NSLog("🚀 [MacTalk] applicationWillFinishLaunching called")
        DLOG("=== applicationWillFinishLaunching END ===")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DLOG("=== applicationDidFinishLaunching START ===")
        NSLog("🚀 [MacTalk] applicationDidFinishLaunching called")

        // Skip UI initialization when running tests
        if isRunningTests() {
            NSLog("🧪 [MacTalk] Running under XCTest - skipping UI initialization")
            DLOG("=== applicationDidFinishLaunching END (test mode) ===")
            return
        }

        // Note: Activation policy is now set in main.swift before app.run()
        // This ensures proper initialization order for macOS 26

        // Initialize status bar controller
        DLOG("About to create StatusBarController...")
        NSLog("🚀 [MacTalk] Creating StatusBarController...")
        statusBarController = StatusBarController()
        DLOG("StatusBarController created")

        DLOG("About to call statusBarController.show()...")
        NSLog("🚀 [MacTalk] Calling statusBarController.show()...")
        statusBarController.show()
        DLOG("statusBarController.show() completed")

        NSLog("🚀 [MacTalk] StatusBarController.show() completed")
        DLOG("=== applicationDidFinishLaunching END ===")
    }

    private func isRunningTests() -> Bool {
        // Check if running under XCTest
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
               ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil ||
               NSClassFromString("XCTest") != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up resources
        statusBarController?.cleanup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even if HUD is closed
        return false
    }

}
