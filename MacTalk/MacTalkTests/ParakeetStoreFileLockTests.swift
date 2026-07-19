import Darwin
import Foundation
import XCTest
@testable import MacTalk

final class ParakeetStoreFileLockTests: XCTestCase {
    func test_exclusiveProcessesExcludeAndAcquireAfterRelease() async throws {
        let root = try makeTemporaryStore()
        let first = try launchProbe(root: root, mode: "exclusive")
        try await first.waitFor("READY")
        first.write("GO\n")
        try await first.waitFor("WAITING")
        try await first.waitFor("ACQUIRED")

        let second = try launchProbe(root: root, mode: "exclusive")
        try await second.waitFor("READY")
        second.write("GO\n")
        try await second.waitFor("WAITING")
        try await second.waitFor("BLOCKED")

        first.write("RELEASE\n")
        try await first.waitFor("RELEASED")
        try await second.waitFor("ACQUIRED")
        second.write("RELEASE\n")
        try await second.waitFor("RELEASED")
        XCTAssertEqual(first.terminate(), 0)
        XCTAssertEqual(second.terminate(), 0)
    }

    func test_sharedProcessesCoexist() async throws {
        let root = try makeTemporaryStore()
        let first = try launchProbe(root: root, mode: "shared")
        let second = try launchProbe(root: root, mode: "shared")
        try await first.waitFor("READY")
        try await second.waitFor("READY")
        first.write("GO\n")
        second.write("GO\n")
        try await first.waitFor("WAITING")
        try await second.waitFor("WAITING")
        try await first.waitFor("ACQUIRED")
        try await second.waitFor("ACQUIRED")
        first.write("RELEASE\n")
        second.write("RELEASE\n")
        try await first.waitFor("RELEASED")
        try await second.waitFor("RELEASED")
        XCTAssertEqual(first.terminate(), 0)
        XCTAssertEqual(second.terminate(), 0)
    }

    func test_sharedBlocksExclusiveAndExclusiveBlocksShared() async throws {
        let root = try makeTemporaryStore()
        let shared = try launchProbe(root: root, mode: "shared")
        try await shared.waitFor("READY")
        shared.write("GO\n")
        try await shared.waitFor("WAITING")
        try await shared.waitFor("ACQUIRED")
        let blockedExclusive = try launchProbe(root: root, mode: "exclusive")
        try await blockedExclusive.waitFor("READY")
        blockedExclusive.write("GO\n")
        try await blockedExclusive.waitFor("WAITING")
        try await blockedExclusive.waitFor("BLOCKED")
        shared.write("RELEASE\n")
        try await shared.waitFor("RELEASED")
        try await blockedExclusive.waitFor("ACQUIRED")
        blockedExclusive.write("RELEASE\n")
        try await blockedExclusive.waitFor("RELEASED")

        let exclusive = try launchProbe(root: root, mode: "exclusive")
        try await exclusive.waitFor("READY")
        exclusive.write("GO\n")
        try await exclusive.waitFor("WAITING")
        try await exclusive.waitFor("ACQUIRED")
        let blockedShared = try launchProbe(root: root, mode: "shared")
        try await blockedShared.waitFor("READY")
        blockedShared.write("GO\n")
        try await blockedShared.waitFor("WAITING")
        try await blockedShared.waitFor("BLOCKED")
        exclusive.write("RELEASE\n")
        try await exclusive.waitFor("RELEASED")
        try await blockedShared.waitFor("ACQUIRED")
        blockedShared.write("RELEASE\n")
        try await blockedShared.waitFor("RELEASED")
        for process in [shared, blockedExclusive, exclusive, blockedShared] {
            XCTAssertEqual(process.terminate(), 0)
        }
    }

    func test_abruptProcessExitReleasesKernelLock() async throws {
        let root = try makeTemporaryStore()
        let crashing = try launchProbe(root: root, mode: "exclusive", abrupt: true)
        try await crashing.waitFor("READY")
        crashing.write("GO\n")
        try await crashing.waitFor("WAITING")
        try await crashing.waitFor("ACQUIRED")
        XCTAssertEqual(crashing.waitForExit(), 0)

        let successor = try launchProbe(root: root, mode: "exclusive")
        try await successor.waitFor("READY")
        successor.write("GO\n")
        try await successor.waitFor("WAITING")
        try await successor.waitFor("ACQUIRED")
        successor.write("RELEASE\n")
        try await successor.waitFor("RELEASED")
        XCTAssertEqual(successor.terminate(), 0)
    }

    func test_tryAcquireReportsContentionAndClosesDescriptor() async throws {
        let root = try makeTemporaryStore()
        let lock = ParakeetStoreFileLock(storeParent: root)
        let held = try XCTUnwrap(try lock.tryAcquire(.exclusive))
        XCTAssertNil(try lock.tryAcquire(.exclusive))
        held.release()
        let successor = try XCTUnwrap(try lock.tryAcquire(.exclusive))
        successor.release()
    }

    func test_cancellationWhileWaitingDoesNotLeakOrAcquireLater() async throws {
        let root = try makeTemporaryStore()
        let lock = ParakeetStoreFileLock(storeParent: root)
        let held = try await lock.acquire(.exclusive)
        let waiting = Task {
            try await lock.acquire(.exclusive)
        }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("cancelled lock acquisition unexpectedly succeeded")
        } catch is CancellationError {
            // expected
        }
        held.release()
        let acquired = try await lock.acquire(.exclusive)
        acquired.release()
    }

    func test_openBindsLockToValidatedParentDescriptorAcrossReplacement() async throws {
        let root = try makeTemporaryStore()
        let renamed = root.deletingLastPathComponent().appendingPathComponent("renamed-\(UUID().uuidString)", isDirectory: true)
        let replacement = root
        let lock = ParakeetStoreFileLock(storeParent: root, afterParentValidation: {
            precondition(rename(root.path, renamed.path) == 0)
            precondition(mkdir(replacement.path, 0o700) == 0)
        })
        let lease = try await lock.acquire(.exclusive)
        defer { lease.release() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.appendingPathComponent(".mactalk-store.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.appendingPathComponent(".mactalk-store.lock").path))
        try? FileManager.default.removeItem(at: renamed)
        try? FileManager.default.removeItem(at: replacement)
    }

    func test_createsMissingStoreParentWithExactPrivateModeUnderNormalUmask() async throws {
        let base = try makeTemporaryStore()
        let root = base.appendingPathComponent("missing/intermediate/leaf", isDirectory: true)
        let previousUmask = umask(0o022)
        defer { _ = umask(previousUmask) }
        let lease = try await ParakeetStoreFileLock(storeParent: root).acquire(.shared)
        lease.release()
        XCTAssertEqual(try fileMode(root), 0o700)
        XCTAssertEqual(try fileMode(root.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try fileMode(root.appendingPathComponent(".mactalk-store.lock")), 0o600)
    }

    func test_existingCurrentUserStoreParentIsTightenedThroughDescriptor() async throws {
        let base = try makeTemporaryStore()
        let root = base.appendingPathComponent("leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        let lease = try await ParakeetStoreFileLock(storeParent: root).acquire(.shared)
        lease.release()
        XCTAssertEqual(try fileMode(root), 0o700)
    }

    func test_intermediateReplacementUsesAlreadyOpenedDescriptor() async throws {
        let base = try makeTemporaryStore()
        let segment = base.appendingPathComponent("segment", isDirectory: true)
        let root = segment.appendingPathComponent("leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(segment.path, 0o700), 0)
        let renamed = base.appendingPathComponent("renamed", isDirectory: true)
        let replacement = base.appendingPathComponent("segment-replacement", isDirectory: true)
        let lock = ParakeetStoreFileLock(storeParent: root, afterParentValidation: nil, afterComponentOpened: { component in
            guard component == "segment" else { return }
            precondition(rename(segment.path, renamed.path) == 0)
            precondition(mkdir(replacement.path, 0o700) == 0)
            precondition(mkdir(replacement.appendingPathComponent("leaf").path, 0o700) == 0)
            precondition(rename(replacement.path, segment.path) == 0)
        })
        let lease = try await lock.acquire(.exclusive)
        lease.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.appendingPathComponent("leaf/.mactalk-store.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: segment.appendingPathComponent("leaf/.mactalk-store.lock").path))
    }

    func test_rootAndLockModesArePrivate() async throws {
        let root = try makeTemporaryStore()
        let lock = ParakeetStoreFileLock(storeParent: root)
        let lease = try await lock.acquire(.shared)
        lease.release()
        XCTAssertEqual(try fileMode(root), 0o700)
        XCTAssertEqual(try fileMode(root.appendingPathComponent(".mactalk-store.lock")), 0o600)
        XCTAssertFalse(root.path.contains("Application Support/MacTalk"))
    }

    func test_symlinkedStoreParentAndIntermediateAreRejected() async throws {
        let root = try makeTemporaryStore()
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(target.path, 0o700), 0)

        let directSymlink = root.appendingPathComponent("direct", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directSymlink, withDestinationURL: target)
        do {
            _ = try await ParakeetStoreFileLock(storeParent: directSymlink).acquire(.exclusive)
            XCTFail("symlinked store parent was accepted")
        } catch {
            // expected
        }

        let intermediateSymlink = root.appendingPathComponent("intermediate", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: intermediateSymlink, withDestinationURL: target)
        let escaped = intermediateSymlink.appendingPathComponent("child", isDirectory: true)
        do {
            _ = try await ParakeetStoreFileLock(storeParent: escaped).acquire(.exclusive)
            XCTFail("symlinked intermediate store parent was accepted")
        } catch {
            // expected
        }
    }


    func test_existingLockPermissionsAreRejected() async throws {
        let root = try makeTemporaryStore()
        let lockPath = root.appendingPathComponent(".mactalk-store.lock")
        FileManager.default.createFile(atPath: lockPath.path, contents: nil)
        XCTAssertEqual(chmod(lockPath.path, 0o644), 0)
        do {
            _ = try await ParakeetStoreFileLock(storeParent: root).acquire(.exclusive)
            XCTFail("world-readable lock file was accepted")
        } catch let error as ParakeetStoreFileLock.LockError {
            XCTAssertEqual(error, .lockPathWrongPermissions(0o644))
        }
    }

    func test_symlinkAndNonRegularLockAreRejected() async throws {
        let symlinkRoot = try makeTemporaryStore()
        let symlinkPath = symlinkRoot.appendingPathComponent(".mactalk-store.lock")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: symlinkRoot.appendingPathComponent("target"))
        do {
            _ = try await ParakeetStoreFileLock(storeParent: symlinkRoot).acquire(.exclusive)
            XCTFail("symlink lock path was accepted")
        } catch {
            // expected
        }

        let fifoRoot = try makeTemporaryStore()
        let fifoPath = fifoRoot.appendingPathComponent(".mactalk-store.lock")
        XCTAssertEqual(mkfifo(fifoPath.path, 0o600), 0)
        do {
            _ = try await ParakeetStoreFileLock(storeParent: fifoRoot).acquire(.exclusive)
            XCTFail("non-regular lock path was accepted")
        } catch {
            // expected
        }
    }

    private func makeTemporaryStore() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactalk-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func fileMode(_ url: URL) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        return Int(info.st_mode & S_IFMT == S_IFREG ? info.st_mode & 0o777 : info.st_mode & 0o777)
    }

    private func launchProbe(root: URL, mode: String, abrupt: Bool = false) throws -> LockProbeProcess {
        try LockProbeProcess(root: root, mode: mode, abrupt: abrupt)
    }
}

private final class LockProbeProcess: @unchecked Sendable {
    private let process: Process
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private let input: FileHandle
    private let output: FileHandle
    private let dataLock = NSLock()
    private let readerQueue = DispatchQueue(label: "mactalk.lock-probe.stdout-reader")
    private var lines = [String]()
    private var partialLine = ""

    init(root: URL, mode: String, abrupt: Bool) throws {
        process = Process()
        inputPipe = Pipe()
        outputPipe = Pipe()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        let executable = Bundle(for: ParakeetStoreFileLockTests.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ParakeetStoreLockProbe")
        process.executableURL = executable
        process.arguments = ["--root", root.path, "--mode", mode] + (abrupt ? ["--abrupt"] : [])
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        try process.run()
        readerQueue.async { [weak self] in self?.readOutputUntilEOF() }
    }

    deinit { _ = terminate() }

    func write(_ value: String) { input.write(value.data(using: .utf8)!) }

    func hasOutput(_ line: String) -> Bool {
        dataLock.lock()
        defer { dataLock.unlock() }
        return lines.contains(where: { $0.contains(line) }) || partialLine.contains(line)
    }

    func waitFor(_ line: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if hasOutput(line) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("probe did not emit \(line); output=\(String(data: outputSnapshot(), encoding: .utf8) ?? "<invalid>")")
    }

    private func readOutputUntilEOF() {
        while true {
            let chunk = output.availableData
            guard !chunk.isEmpty else { return }
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            dataLock.lock()
            partialLine.append(text)
            let parts = partialLine.split(separator: "\n", omittingEmptySubsequences: false)
            if partialLine.hasSuffix("\n") {
                lines.append(contentsOf: parts.dropLast().map(String.init))
                partialLine = ""
            } else if let last = parts.last {
                lines.append(contentsOf: parts.dropLast().map(String.init))
                partialLine = String(last)
            }
            dataLock.unlock()
        }
    }

    private func outputSnapshot() -> Data {
        dataLock.lock()
        defer { dataLock.unlock() }
        return (lines + [partialLine]).joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    func waitForExit() -> Int32 { finishProcess(sendTermination: false) }

    func terminate() -> Int32 { finishProcess(sendTermination: true) }

    private func finishProcess(sendTermination: Bool) -> Int32 {
        if process.isRunning && sendTermination { process.terminate() }
        if process.isRunning { waitUntilExit(deadline: Date().addingTimeInterval(2)) }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            waitUntilExit(deadline: Date().addingTimeInterval(2))
        }
        try? input.close()
        return process.terminationStatus
    }

    private func waitUntilExit(deadline: Date) {
        while process.isRunning && Date() < deadline { usleep(10_000) }
    }
}
