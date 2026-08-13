//
//  AudioHardwareValidationRecorder.swift
//  MacTalk
//
//  Opt-in capture-only diagnostics for signed hardware validation.
//

import Darwin
import Foundation

enum AudioHardwareValidationResult: String, Sendable {
    case received
    case streamError = "stream_error"
}

struct AudioHardwareValidationRecord: Sendable, Equatable {
    let event: String
    let sessionID: UUID
    let arrivalUptimeNanoseconds: UInt64
    let mediaHostNanoseconds: Int64?
    let ptsValue: Int64?
    let ptsTimescale: Int32?
    let sampleCount: Int
    let result: AudioHardwareValidationResult
}

protocol AudioHardwareValidationSinking: Sendable {
    func append(_ record: AudioHardwareValidationRecord) throws
}

enum AudioHardwareValidationSinkError: Error {
    case insecureParent
    case invalidFile
    case openFailed
    case writeFailed
}

/// Records only bounded timestamp/capture health data when explicitly enabled
/// through MACTALK_AUDIO_HARDWARE_VALIDATION_LOG. It never records samples,
/// transcript text, errors, or application identity.
final class AudioHardwareValidationRecorder: @unchecked Sendable {
    private struct State {
        var pending = 0
        var dropped: UInt64 = 0
    }

    private static let defaultScheduleQueue = DispatchQueue(
        label: "com.mactalk.audio.hardware-validation",
        qos: .utility
    )
    private static let defaultSchedule: @Sendable (@escaping @Sendable () -> Void) -> Void = { job in
        AudioHardwareValidationRecorder.defaultScheduleQueue.async(execute: job)
    }

    private let sink: any AudioHardwareValidationSinking
    private let enabled: Bool
    private let maximumPendingRecords: Int
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let stateLock = NSLock()
    private var state = State()

    init(
        sink: any AudioHardwareValidationSinking,
        maximumPendingRecords: Int = 128,
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = AudioHardwareValidationRecorder.defaultSchedule,
        enabled: Bool = true
    ) {
        self.sink = sink
        self.enabled = enabled
        self.maximumPendingRecords = max(0, maximumPendingRecords)
        self.schedule = schedule
    }

    convenience init(fileURL: URL?) {
        guard let fileURL, let sink = try? FileHardwareValidationSink(fileURL: fileURL) else {
            self.init(sink: NullHardwareValidationSink(), enabled: false)
            return
        }
        self.init(sink: sink)
    }

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = AudioHardwareValidationRecorder.defaultSchedule
    ) -> AudioHardwareValidationRecorder {
        guard let path = environment["MACTALK_AUDIO_HARDWARE_VALIDATION_LOG"],
              let sink = try? FileHardwareValidationSink(fileURL: URL(fileURLWithPath: path)) else {
            return AudioHardwareValidationRecorder(sink: NullHardwareValidationSink(), schedule: schedule, enabled: false)
        }
        return AudioHardwareValidationRecorder(sink: sink, schedule: schedule)
    }

    var droppedRecordCount: UInt64 {
        stateLock.withLock { state.dropped }
    }

    func recordMicrophone(sessionID: UUID, hostNanoseconds: Int64, sampleCount: Int) {
        guard enabled else { return }
        enqueue(AudioHardwareValidationRecord(
            event: "microphone",
            sessionID: sessionID,
            arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            mediaHostNanoseconds: hostNanoseconds,
            ptsValue: nil,
            ptsTimescale: nil,
            sampleCount: sampleCount,
            result: .received
        ))
    }

    func recordApplication(
        sessionID: UUID,
        ptsValue: Int64,
        ptsTimescale: Int32,
        mappedHostNanoseconds: Int64,
        sampleCount: Int
    ) {
        guard enabled else { return }
        enqueue(AudioHardwareValidationRecord(
            event: "application",
            sessionID: sessionID,
            arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            mediaHostNanoseconds: mappedHostNanoseconds,
            ptsValue: ptsValue,
            ptsTimescale: ptsTimescale,
            sampleCount: sampleCount,
            result: .received
        ))
    }

    func recordApplicationLoss(sessionID: UUID) {
        guard enabled else { return }
        enqueue(AudioHardwareValidationRecord(
            event: "application_loss",
            sessionID: sessionID,
            arrivalUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            mediaHostNanoseconds: nil,
            ptsValue: nil,
            ptsTimescale: nil,
            sampleCount: 0,
            result: .streamError
        ))
    }

    private func enqueue(_ record: AudioHardwareValidationRecord) {
        let accepted = stateLock.withLock { () -> Bool in
            guard state.pending < maximumPendingRecords else {
                state.dropped &+= 1
                return false
            }
            state.pending += 1
            return true
        }
        guard accepted else { return }
        schedule { [weak self] in
            guard let self else { return }
            defer { self.stateLock.withLock { self.state.pending -= 1 } }
            try? self.sink.append(record)
        }
    }
}

private final class NullHardwareValidationSink: AudioHardwareValidationSinking {
    func append(_ record: AudioHardwareValidationRecord) throws {
        _ = record
    }
}

private final class FileHardwareValidationSink: AudioHardwareValidationSinking, @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()

    init(fileURL: URL) throws {
        let parentDescriptor = try Self.openValidatedParent(fileURL.deletingLastPathComponent())
        defer { close(parentDescriptor) }

        let leaf = fileURL.lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != ".." else {
            throw AudioHardwareValidationSinkError.invalidFile
        }
        let openedLeaf = try Self.openLeaf(parentDescriptor, name: leaf)
        let descriptor = openedLeaf.descriptor
        var fileStat = Darwin.stat()
        guard fstat(descriptor, &fileStat) == 0 else {
            close(descriptor)
            throw AudioHardwareValidationSinkError.invalidFile
        }
        let valid = (fileStat.st_mode & S_IFMT) == S_IFREG
            && fileStat.st_uid == uid_t(getuid())
            && (fileStat.st_mode & 0o7777) == 0o600
        guard valid else {
            if openedLeaf.created && Self.createdLeafNeedsRemoval(parentDescriptor, name: leaf, stat: fileStat) {
                unlinkat(parentDescriptor, leaf, 0)
            }
            close(descriptor)
            throw AudioHardwareValidationSinkError.invalidFile
        }

        self.descriptor = descriptor
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            throw AudioHardwareValidationSinkError.writeFailed
        }
        defer { flock(descriptor, LOCK_UN) }
        var currentStat = Darwin.stat()
        guard fstat(descriptor, &currentStat) == 0 else {
            close(descriptor)
            throw AudioHardwareValidationSinkError.invalidFile
        }
        if currentStat.st_size == 0 {
            let header = "event,session_id,wall_time,arrival_uptime_ns,media_host_ns,pts_value,pts_timescale,samples,result\n"
            try Self.write(Data(header.utf8), to: descriptor)
        }
    }

    deinit {
        close(descriptor)
    }

    func append(_ record: AudioHardwareValidationRecord) throws {
        let mediaHost = record.mediaHostNanoseconds.map(String.init) ?? ""
        let ptsValue = record.ptsValue.map(String.init) ?? ""
        let ptsTimescale = record.ptsTimescale.map(String.init) ?? ""
        let fields = [
            record.event,
            record.sessionID.uuidString,
            ISO8601DateFormatter().string(from: Date()),
            String(record.arrivalUptimeNanoseconds),
            mediaHost,
            ptsValue,
            ptsTimescale,
            String(record.sampleCount),
            record.result.rawValue
        ]
        try write(Data((fields.joined(separator: ",") + "\n").utf8))
    }

    private func write(_ data: Data) throws {
        try lock.withLock {
            try Self.write(data, to: descriptor)
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        var remaining = data
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress, bytes.count)
            }
            guard count > 0 else { throw AudioHardwareValidationSinkError.writeFailed }
            remaining = remaining.dropFirst(count)
        }
    }

    private static func openValidatedParent(_ parent: URL) throws -> Int32 {
        let path = parent.path
        guard path.hasPrefix("/") else { throw AudioHardwareValidationSinkError.insecureParent }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let root = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw AudioHardwareValidationSinkError.openFailed }
        var current = root
        do {
            for component in components {
                let name = String(component)
                guard name != ".", name != ".." else {
                    throw AudioHardwareValidationSinkError.insecureParent
                }
                var next = Self.openDirectory(at: current, name: name)
                if next < 0, errno == ENOENT {
                    if mkdirat(current, name, 0o700) < 0, errno != EEXIST {
                        throw AudioHardwareValidationSinkError.insecureParent
                    }
                    next = Self.openDirectory(at: current, name: name)
                }
                guard next >= 0 else { throw AudioHardwareValidationSinkError.insecureParent }
                close(current)
                current = next
            }
            var parentStat = Darwin.stat()
            guard fstat(current, &parentStat) == 0,
                  (parentStat.st_mode & S_IFMT) == S_IFDIR,
                  parentStat.st_uid == uid_t(getuid()),
                  (parentStat.st_mode & 0o22) == 0 else {
                throw AudioHardwareValidationSinkError.insecureParent
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private static func openDirectory(at descriptor: Int32, name: String) -> Int32 {
        name.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    }

    private static func openLeaf(_ parent: Int32, name: String) throws -> (descriptor: Int32, created: Bool) {
        for _ in 0..<8 {
            let created = name.withCString {
                openat(parent, $0, O_APPEND | O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            }
            if created >= 0 { return (created, true) }
            guard errno == EEXIST else { throw AudioHardwareValidationSinkError.openFailed }
            let existing = name.withCString {
                openat(parent, $0, O_APPEND | O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            if existing >= 0 { return (existing, false) }
            guard errno == ENOENT else { throw AudioHardwareValidationSinkError.openFailed }
        }
        throw AudioHardwareValidationSinkError.openFailed
    }

    private static func createdLeafNeedsRemoval(_ parent: Int32, name: String, stat: Darwin.stat) -> Bool {
        var current = Darwin.stat()
        guard name.withCString({ fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }) == 0 else { return false }
        return current.st_dev == stat.st_dev && current.st_ino == stat.st_ino
    }
}
