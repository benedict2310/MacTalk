//
//  main.swift
//  MacTalk
//
//  Explicit entry point for MacTalk application
//  This replaces the @main attribute to ensure proper initialization on macOS 26
//

import AppKit

// IMPORTANT: Don't run main app when unit tests are running
// XCTest injects XCTestCase classes, so we check for their presence
let isRunningTests = NSClassFromString("XCTestCase") != nil

if !isRunningTests {
    // Initialize debug logger FIRST (before anything else)
    _ = DebugLogger.shared
    DLOG("=== main.swift START ===")
    NSLog("🚀 [MacTalk] main.swift executing")

    // Create application instance
    let app = NSApplication.shared
    DLOG("NSApplication.shared created")

    // CRITICAL: Set activation policy BEFORE creating delegate or running app
    // This is required for menu bar apps on macOS 26 (Tahoe)
    NSLog("🚀 [MacTalk] Setting activation policy to .accessory")
    app.setActivationPolicy(.accessory)
    DLOG("Activation policy set to .accessory")

    // Create and assign delegate
    NSLog("🚀 [MacTalk] Creating AppDelegate")
    let delegate = AppDelegate()
    app.delegate = delegate
    DLOG("AppDelegate created and assigned")

    // Start the app event loop
    NSLog("🚀 [MacTalk] Starting NSApplicationMain")
    DLOG("About to call app.run()")
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    DLOG("=== main.swift END (app terminated) ===")
} else {
    NSLog("🧪 [MacTalk] Unit tests detected - skipping main app initialization")
}
