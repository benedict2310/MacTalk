//
//  main.swift
//  MacTalk
//
//  Explicit entry point for MacTalk application
//  This replaces the @main attribute to ensure proper initialization on macOS 26
//

import AppKit

// Initialize debug logger FIRST (before anything else)
_ = DebugLogger.shared
DLOG("=== main.swift START ===")
NSLog("🚀 [MacTalk] main.swift executing")

// Create application instance
let app = NSApplication.shared
DLOG("NSApplication.shared created")

// CRITICAL: Set activation policy BEFORE creating delegate or running app
// This is required for menu bar apps on macOS 26 (Tahoe)
// Check showInDock preference to determine activation policy
let showInDock = UserDefaults.standard.bool(forKey: "showInDock")
let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
NSLog("🚀 [MacTalk] Setting activation policy to \(showInDock ? ".regular (show in dock)" : ".accessory (menu bar only)")")
app.setActivationPolicy(policy)
DLOG("Activation policy set to \(policy)")

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
