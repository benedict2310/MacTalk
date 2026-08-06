//
//  DebugLogger.swift
//  MacTalk
//
//  Explicitly opt-in diagnostics logger. Sensitive values are never rendered.
//

import Foundation

protocol DebugLogSink: Sendable {
    func write(_ message: String)
}

enum DebugLogMessage: Sendable {
    case event(String)
    case transcriptCompleted(characterCount: Int)
    case clipboardUpdated(characterCount: Int)
    case error(description: String)

    var rendered: String {
        switch self {
        case .event(let message):
            return message
        case .transcriptCompleted(let characterCount):
            return "transcription.completed chars=\(characterCount)"
        case .clipboardUpdated(let characterCount):
            return "clipboard.updated chars=\(characterCount)"
        case .error:
            // Error descriptions can contain transcript or clipboard data.
            return "operation.failed"
        }
    }
}

/// Writes only explicitly enabled, non-sensitive diagnostics.
final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    private let sink: DebugLogSink
    private let diagnosticsEnabled: Bool

    init(sink: DebugLogSink? = nil, diagnosticsEnabled: Bool? = nil) {
        let enabled = diagnosticsEnabled ?? Self.environmentEnablesDiagnostics
        self.diagnosticsEnabled = enabled
        self.sink = sink ?? (enabled ? FileDebugLogSink() : NullDebugLogSink())
    }

    func log(_ message: DebugLogMessage, file: String = #file, line: Int = #line) {
        #if DEBUG
        guard diagnosticsEnabled else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        sink.write("[\(timestamp)] [\(fileName):\(line)] \(message.rendered)")
        #else
        _ = message
        _ = file
        _ = line
        #endif
    }

    private static var environmentEnablesDiagnostics: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        return environment["MACTALK_DEBUG_LOGGING"] == "1"
            || arguments.contains("--mactalk-debug-logging")
        #else
        return false
        #endif
    }
}

private final class NullDebugLogSink: DebugLogSink {
    func write(_ message: String) {
        _ = message
    }
}

private final class FileDebugLogSink: DebugLogSink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mactalk.debuglogger", qos: .utility)
    private let logURL: URL

    init() {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MacTalk", isDirectory: true)
        self.logURL = logsDirectory.appendingPathComponent("debug.log")

        try? FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
            )
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: logURL.path
        )
    }

    func write(_ message: String) {
        queue.async { [logURL] in
            guard let data = (message + "\n").data(using: .utf8) else { return }
            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

/// Legacy call sites remain source-compatible, but are compiled out of Release.
func DLOG(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    #if DEBUG
    DebugLogger.shared.log(.event(message()), file: file, line: line)
    #else
    _ = file
    _ = line
    #endif
}
