//
//  AppDelegate.swift
//  MacTalk
//
//  Created by MacTalk Development Team
//  Copyright © 2025 MacTalk. All rights reserved.
//

import AppKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize status bar controller (menu bar app)
        statusBarController = StatusBarController()
        statusBarController.show()

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
