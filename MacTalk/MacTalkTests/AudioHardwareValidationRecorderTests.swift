import Darwin
import Foundation
import XCTest
@testable import MacTalk

final class AudioHardwareValidationRecorderTests: XCTestCase {
    func test_missingEnvironmentDoesNotScheduleJobs() {
        let scheduler = ManualHardwareScheduler()
        let recorder = AudioHardwareValidationRecorder.fromEnvironment([:], schedule: scheduler.schedule)

        recorder.recordMicrophone(sessionID: UUID(), hostNanoseconds: 10, sampleCount: 160)
        recorder.recordApplicationLoss(sessionID: UUID())

        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    func test_recordMicrophoneNeverWritesOnCaller() {
        let sink = RecordingHardwareSink()
        let scheduler = ManualHardwareScheduler()
        let recorder = AudioHardwareValidationRecorder(
            sink: sink,
            maximumPendingRecords: 2,
            schedule: scheduler.schedule
        )

        recorder.recordMicrophone(sessionID: UUID(), hostNanoseconds: 10, sampleCount: 160)
        XCTAssertTrue(sink.records.isEmpty)
        scheduler.runAll()
        XCTAssertEqual(sink.records.count, 1)
    }

    func test_pendingRecordsAreBounded() {
        let sink = RecordingHardwareSink()
        let scheduler = ManualHardwareScheduler()
        let recorder = AudioHardwareValidationRecorder(
            sink: sink,
            maximumPendingRecords: 2,
            schedule: scheduler.schedule
        )
        let sessionID = UUID()

        recorder.recordMicrophone(sessionID: sessionID, hostNanoseconds: 1, sampleCount: 160)
        recorder.recordMicrophone(sessionID: sessionID, hostNanoseconds: 2, sampleCount: 160)
        recorder.recordMicrophone(sessionID: sessionID, hostNanoseconds: 3, sampleCount: 160)

        XCTAssertEqual(recorder.droppedRecordCount, 1)
        scheduler.runAll()
        XCTAssertEqual(sink.records.count, 2)
    }

    func test_applicationLossUsesTypedStreamError() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hardware.csv")
        let recorder = AudioHardwareValidationRecorder(fileURL: fileURL)

        recorder.recordApplicationLoss(sessionID: UUID())
        let deadline = Date().addingTimeInterval(2)
        var output = ""
        repeat {
            output = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            if output.contains("stream_error") { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        XCTAssertTrue(output.contains("stream_error"))
    }

    func test_fileSinkRejectsSymlinkWithoutTouchingTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.csv")
        try Data("sentinel".utf8).write(to: target)
        let link = directory.appendingPathComponent("link.csv")
        XCTAssertEqual(symlink(target.path, link.path), 0)

        let recorder = AudioHardwareValidationRecorder(fileURL: link)
        recorder.recordMicrophone(sessionID: UUID(), hostNanoseconds: 1, sampleCount: 1)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel")
    }

    func test_fileSinkRejectsFIFOWithoutBlocking() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("hardware.csv")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let finished = expectation(description: "FIFO validation finishes")
        DispatchQueue.global().async {
            _ = AudioHardwareValidationRecorder(fileURL: fifo)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)

        var stat = Darwin.stat()
        XCTAssertEqual(lstat(fifo.path, &stat), 0)
        XCTAssertTrue((stat.st_mode & S_IFMT) == S_IFIFO)
    }

    func test_fileSinkRejectsSymlinkedParentWithoutTouchingTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = directory.appendingPathComponent("link", isDirectory: true)
        XCTAssertEqual(symlink(target.path, link.path), 0)

        _ = AudioHardwareValidationRecorder(fileURL: link.appendingPathComponent("hardware.csv"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("hardware.csv").path))
    }

    func test_fileSinkRejectsExistingFileWithSpecialModeBits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hardware.csv")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
        XCTAssertEqual(chmod(fileURL.path, 0o4600), 0)

        _ = AudioHardwareValidationRecorder(fileURL: fileURL)

        var fileStat = Darwin.stat()
        XCTAssertEqual(lstat(fileURL.path, &fileStat), 0)
        XCTAssertEqual(fileStat.st_mode & 0o7777, 0o4600)
        XCTAssertEqual(fileStat.st_size, 0)
    }

    func test_fileSinkRejectsWorldWritableExistingParentWithoutChangingMode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("insecure", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(parent.path, 0o777), 0)

        _ = AudioHardwareValidationRecorder(fileURL: parent.appendingPathComponent("hardware.csv"))

        var parentStat = Darwin.stat()
        XCTAssertEqual(lstat(parent.path, &parentStat), 0)
        XCTAssertEqual(parentStat.st_mode & 0o777, 0o777)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("hardware.csv").path))
    }

    func test_fileSinkCreatesPrivateFileAndPreservesExistingParentMode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(parent.path, 0o750), 0)
        let fileURL = parent.appendingPathComponent("hardware.csv")

        let recorder = AudioHardwareValidationRecorder(fileURL: fileURL)
        recorder.recordMicrophone(sessionID: UUID(), hostNanoseconds: 1, sampleCount: 1)

        var parentStat = Darwin.stat()
        var fileStat = Darwin.stat()
        XCTAssertEqual(lstat(parent.path, &parentStat), 0)
        XCTAssertEqual(lstat(fileURL.path, &fileStat), 0)
        XCTAssertEqual(parentStat.st_mode & 0o777, 0o750)
        XCTAssertEqual(fileStat.st_mode & 0o777, 0o600)
    }

    func test_concurrentCreatorsShareOnePrivateFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hardware.csv")
        let group = DispatchGroup()
        let recorders = RecorderCollection()

        for index in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                let recorder = AudioHardwareValidationRecorder(fileURL: fileURL)
                recorder.recordMicrophone(sessionID: UUID(), hostNanoseconds: Int64(index), sampleCount: 1)
                recorders.append(recorder)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)

        var fileStat = Darwin.stat()
        XCTAssertEqual(lstat(fileURL.path, &fileStat), 0)
        XCTAssertEqual(fileStat.st_mode & 0o777, 0o600)
        let deadline = Date().addingTimeInterval(2)
        var lines: [Substring] = []
        repeat {
            lines = (try? String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")) ?? []
            if lines.count == 17 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        XCTAssertEqual(lines.count, 17)
        XCTAssertEqual(lines.filter { $0.hasPrefix("event,session_id,") }.count, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("MacTalk-AudioHardwareValidationRecorder-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class RecorderCollection: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AudioHardwareValidationRecorder] = []

    func append(_ recorder: AudioHardwareValidationRecorder) {
        lock.withLock { values.append(recorder) }
    }
}

private final class RecordingHardwareSink: AudioHardwareValidationSinking, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [AudioHardwareValidationRecord] = []

    func append(_ record: AudioHardwareValidationRecord) throws {
        lock.withLock { records.append(record) }
    }
}

private final class ManualHardwareScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []

    var scheduledCount: Int {
        lock.withLock { jobs.count }
    }

    func schedule(_ job: @escaping @Sendable () -> Void) {
        lock.withLock { jobs.append(job) }
    }

    func runAll() {
        let pending = lock.withLock { defer { jobs.removeAll() }; return jobs }
        pending.forEach { $0() }
    }
}
