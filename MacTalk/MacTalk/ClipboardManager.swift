//
//  ClipboardManager.swift
//  MacTalk
//
//  Clipboard operations
//

import AppKit

/// Writes transcript text to the system clipboard on the main actor.
@MainActor
enum ClipboardManager {
    /// Set text to system clipboard.
    static func setClipboard(_ text: String) {
        NSLog("📋 [ClipboardManager] Setting clipboard with text length: \(text.count) characters")
        DLOG("[Clipboard] setClipboard called: chars=\(text.count)")
        let pasteboard = NSPasteboard.general
        let beforeChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)
        if success {
            NSLog("✅ [ClipboardManager] Clipboard set successfully (changeCount=\(pasteboard.changeCount))")
            DLOG("[Clipboard] setClipboard succeeded: beforeChangeCount=\(beforeChangeCount), afterChangeCount=\(pasteboard.changeCount)")
        } else {
            NSLog("❌ [ClipboardManager] Failed to set clipboard")
            DLOG("[Clipboard] setClipboard failed: beforeChangeCount=\(beforeChangeCount), afterChangeCount=\(pasteboard.changeCount)")
        }
    }
}
