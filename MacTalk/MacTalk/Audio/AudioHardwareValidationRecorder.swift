//
//  AudioHardwareValidationRecorder.swift
//  MacTalk
//
//  Opt-in capture-only diagnostics for signed hardware validation.
//

import Foundation

/// Records only timestamp/capture health data when explicitly enabled through
/// MACTALK_AUDIO_HARDWARE_VALIDATION_LOG. It never records samples or
/// transcript text and is inert in normal app launches.
final class AudioHardwareValidationRecorder: @unchecked Sendable {
    private let fileURL: URL?
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    init(fileURL: URL?) {
        self.fileURL = fileURL
        self.formatter = ISO8601DateFormatter()
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                let header = "event,wall_time,arrival_uptime_ns,media_host_ns,pts_value,pts_timescale,samples,result\n"
                try header.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Audio hardware validation log unavailable: \(error.localizedDescription)")
        }
    }

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AudioHardwareValidationRecorder {
        let path = environment["MACTALK_AUDIO_HARDWARE_VALIDATION_LOG"]
        return AudioHardwareValidationRecorder(fileURL: path.map(URL.init(fileURLWithPath:)))
    }

    func recordMicrophone(
        sessionID: UUID,
        hostNanoseconds: Int64,
        sampleCount: Int
    ) {
        append(
            event: "microphone",
            sessionID: sessionID,
            arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            mediaHostNanoseconds: hostNanoseconds,
            ptsValue: nil,
            ptsTimescale: nil,
            sampleCount: sampleCount,
            result: "received"
        )
    }

    func recordApplication(
        sessionID: UUID,
        ptsValue: Int64,
        ptsTimescale: Int32,
        mappedHostNanoseconds: Int64,
        sampleCount: Int
    ) {
        append(
            event: "application",
            sessionID: sessionID,
            arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            mediaHostNanoseconds: mappedHostNanoseconds,
            ptsValue: ptsValue,
            ptsTimescale: ptsTimescale,
            sampleCount: sampleCount,
            result: "received"
        )
    }

    func recordApplicationLoss(sessionID: UUID, error: String) {
        append(
            event: "application_loss",
            sessionID: sessionID,
            arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            mediaHostNanoseconds: nil,
            ptsValue: nil,
            ptsTimescale: nil,
            sampleCount: 0,
            result: error.replacingOccurrences(of: ",", with: ";")
        )
    }

    private func append(
        event: String,
        sessionID: UUID,
        arrivalUptimeNanoseconds: UInt64,
        mediaHostNanoseconds: Int64?,
        ptsValue: Int64?,
        ptsTimescale: Int32?,
        sampleCount: Int,
        result: String
    ) {
        guard let fileURL else { return }
        lock.lock(); defer { lock.unlock() }
        let mediaHostField = mediaHostNanoseconds.map { String($0) } ?? ""
        let ptsValueField = ptsValue.map { String($0) } ?? ""
        let ptsTimescaleField = ptsTimescale.map { String($0) } ?? ""
        let wallTime = formatter.string(from: Date())
        let sessionResult = sessionID.uuidString + ":" + result
        let fields: [String] = [
            event,
            wallTime,
            String(arrivalUptimeNanoseconds),
            mediaHostField,
            ptsValueField,
            ptsTimescaleField,
            String(sampleCount),
            sessionResult
        ]
        let line = fields.joined(separator: ",") + "\n"
        guard let data = line.data(using: String.Encoding.utf8) else { return }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics must never affect an audio callback or its delivery.
        }
    }
}
