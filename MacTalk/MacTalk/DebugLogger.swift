//
//  DebugLogger.swift
//  MacTalk
//
//  Emergency debug logger that writes to file
//

import Foundation

class DebugLogger {
    static let shared = DebugLogger()
    private let logFile = "/tmp/mactalk_debug.log"

    init() {
        // Clear log file on init
        try? "=== MacTalk Debug Log Started ===\n".write(toFile: logFile, atomically: true, encoding: .utf8)
        log("DebugLogger initialized")
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let timestamp = Date()
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        if let handle = FileHandle(forWritingAtPath: logFile) {
            handle.seekToEndOfFile()
            if let data = logMessage.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        } else {
            try? logMessage.write(toFile: logFile, atomically: false, encoding: .utf8)
        }

        // Also print to stderr
        fputs(logMessage, stderr)
    }
}

// Convenience global function
func DLOG(_ message: String, file: String = #file, line: Int = #line) {
    DebugLogger.shared.log(message, file: file, line: line)
}
