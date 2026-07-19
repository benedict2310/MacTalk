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
        XCTAssertFalse(second.hasOutput("ACQUIRED"))

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
        XCTAssertFalse(blockedExclusive.hasOutput("ACQUIRED"))
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
        XCTAssertFalse(blockedShared.hasOutput("ACQUIRED"))
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

    func test_wrongStoreParentPermissionsAreRejected() async throws {
        let root = try makeTemporaryStore()
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        do {
            _ = try await ParakeetStoreFileLock(storeParent: root).acquire(.exclusive)
            XCTFail("world-readable store parent was accepted")
        } catch let error as ParakeetStoreFileLock.LockError {
            XCTAssertEqual(error, .storeParentWrongPermissions(0o755))
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
    private var data = Data()

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
        print("Launching lock probe: \(executable.path) exists=\(FileManager.default.isExecutableFile(atPath: executable.path))")
        process.executableURL = executable
        process.arguments = ["--root", root.path, "--mode", mode] + (abrupt ? ["--abrupt"] : [])
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        output.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self.dataLock.lock()
            self.data.append(chunk)
            self.dataLock.unlock()
        }
        try process.run()
    }

    func write(_ value: String) { input.write(value.data(using: .utf8)!) }

    func hasOutput(_ line: String) -> Bool {
        if !process.isRunning {
            output.readabilityHandler = nil
            let remaining = output.readDataToEndOfFile()
            if !remaining.isEmpty {
                dataLock.lock()
                data.append(remaining)
                dataLock.unlock()
            }
        }
        dataLock.lock()
        let snapshot = data
        dataLock.unlock()
        return String(data: snapshot, encoding: .utf8)?.contains(line) == true
    }

    func waitFor(_ line: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if hasOutput(line) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("probe did not emit \(line); output=\(String(data: outputSnapshot(), encoding: .utf8) ?? "<invalid>")")
    }

    private func outputSnapshot() -> Data {
        dataLock.lock()
        defer { dataLock.unlock() }
        return data
    }

    func waitForExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    func terminate() -> Int32 {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        return process.terminationStatus
    }
}
