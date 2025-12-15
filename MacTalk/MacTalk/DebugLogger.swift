//
//  DebugLogger.swift
//  MacTalk
//
//  Emergency debug logger that writes to file
//

import Foundation

/// Thread-safe debug logger using a serial dispatch queue
/// Marked @unchecked Sendable because we manage thread safety internally
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()
    private let logFile = "/tmp/mactalk_debug.log"
    private let queue = DispatchQueue(label: "com.mactalk.debuglogger", qos: .utility)

    init() {
        // Clear log file on init
        queue.async { [logFile] in
            try? "=== MacTalk Debug Log Started ===\n".write(toFile: logFile, atomically: true, encoding: .utf8)
        }
        log("DebugLogger initialized")
    }

    func log(_ message: String, file: String = #file, line: Int = #line) {
        let timestamp = Date()
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(timestamp)] [\(fileName):\(line)] \(message)\n"

        // Write to file on serial queue for thread safety
        queue.async { [logFile] in
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try? logMessage.write(toFile: logFile, atomically: false, encoding: .utf8)
            }
        }

        // Also print to stderr (thread-safe)
        fputs(logMessage, stderr)
    }
}

// Convenience global function
func DLOG(_ message: String, file: String = #file, line: Int = #line) {
    DebugLogger.shared.log(message, file: file, line: line)
}
