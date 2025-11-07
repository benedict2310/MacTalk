#!/usr/bin/env swift
import AppKit

class SimpleApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("===== SIMPLE TEST APP LAUNCHING =====")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        NSLog("Status item created: \(statusItem!)")

        if let button = statusItem.button {
            NSLog("Got button: \(button)")
            button.title = "TEST"
            button.toolTip = "Test App"
            NSLog("Button configured")
        } else {
            NSLog("ERROR: No button!")
        }

        NSLog("===== SIMPLE TEST APP LAUNCHED =====")
    }
}

let app = NSApplication.shared
let delegate = SimpleApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
