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

        // Request microphone permission on first launch
        Permissions.ensureMic { granted in
            if !granted {
                DispatchQueue.main.async {
                    self.showPermissionAlert(type: "Microphone")
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up resources
        statusBarController?.cleanup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even if HUD is closed
        return false
    }

    private func showPermissionAlert(type: String) {
        let alert = NSAlert()
        alert.messageText = "\(type) Permission Required"
        alert.informativeText = "MacTalk needs \(type) access to function. Please grant permission in System Settings > Privacy & Security > \(type)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
        } else {
            NSApp.terminate(nil)
        }
    }
}
