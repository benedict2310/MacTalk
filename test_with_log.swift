#!/usr/bin/env swift
import AppKit
import Foundation

let logFile = "/tmp/test_statusbar_debug.log"

func TESTLOG(_ msg: String) {
    let log = "[\(Date())] \(msg)\n"
    try? log.appendToFile(at: logFile)
    print(log, terminator: "")
}

extension String {
    func appendToFile(at path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            handle.seekToEndOfFile()
            handle.write(data(using: .utf8)!)
            handle.closeFile()
        } else {
            try write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

TESTLOG("=== TEST APP STARTING ===")

class SimpleApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        TESTLOG("applicationDidFinishLaunching called")

        NSApplication.shared.setActivationPolicy(.accessory)
        TESTLOG("Set activation policy")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        TESTLOG("Status item created")

        if let button = statusItem.button {
            button.title = "LOG-TEST"
            TESTLOG("Button configured with LOG-TEST")
        }
    }
}

let app = NSApplication.shared
let delegate = SimpleApp()
app.delegate = delegate
TESTLOG("About to call app.run()")
app.run()
