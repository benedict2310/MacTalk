import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacTalk

final class ParakeetSourceSnapshotTests: XCTestCase {
    func test_canonicalSourcePathsKeepJointAtSourceRoot() throws {
        let fixture = try SourceFixture()
        let entries = fixture.entries
        XCTAssertEqual(entries.filter { $0.component == "JointDecisionv3" }.map(\.path), [
            "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
        ])
    }

    func test_completeSourceReturnsAllOwnedAssetsAndHoldsOneSharedLeaseDuringReads() async throws {
        let fixture = try SourceFixture()
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let hook = XCTestExpectation(description: "shared lock held while reading")
        let provider = VerifiedParakeetSourceSnapshotProvider(
            store: fixture.store,
            beforeArtifactRead: {
                XCTAssertNil(try? lock.tryAcquire(.exclusive))
                hook.fulfill()
            }
        )
        let snapshot = try await provider.makeVerifiedSnapshot()
        await fulfillment(of: [hook], timeout: 2)
        XCTAssertEqual(snapshot.assets.count, 4)
        XCTAssertEqual(snapshot.vocabulary.data, fixture.data(for: fixture.entries.last!))
        XCTAssertTrue(snapshot.assets.values.allSatisfy { !$0.specification.data.isEmpty && !$0.weights.data.isEmpty })
        let successor = try await lock.acquire(.exclusive)
        successor.release()
    }

    func test_sourceReplacementAfterOpenCannotRedirectSnapshot() async throws {
        let fixture = try SourceFixture()
        let renamed = fixture.parent.appendingPathComponent("renamed-source", isDirectory: true)
        let replacement = fixture.parent.appendingPathComponent(fixture.sourceName, isDirectory: true)
        let provider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store, beforeArtifactRead: {
            if !FileManager.default.fileExists(atPath: renamed.path) {
                XCTAssertEqual(rename(fixture.source.path, renamed.path), 0)
                XCTAssertEqual(mkdir(replacement.path, 0o700), 0)
                try? Data("attacker".utf8).write(to: replacement.appendingPathComponent("parakeet_vocab.json"))
            }
        })
        let snapshot = try await provider.makeVerifiedSnapshot()
        XCTAssertEqual(snapshot.vocabulary.data, fixture.data(for: fixture.entries.last!))
        try? FileManager.default.removeItem(at: renamed)
        try? FileManager.default.removeItem(at: replacement)
    }

    func test_cancellationReleasesSharedLeaseBeforeBlockedQueueRuns() async throws {
        let fixture = try SourceFixture()
        let queue = DispatchQueue(label: "mactalk.snapshot.blocked-cancellation")
        let barrierStarted = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        queue.async {
            barrierStarted.signal()
            unblock.wait()
        }
        XCTAssertEqual(barrierStarted.wait(timeout: .now() + 2), .success)

        let provider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store, queue: queue)
        let task = Task { try await provider.makeVerifiedSnapshot() }
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let deadline = Date().addingTimeInterval(2)
        var sharedLeaseConfirmed = false
        while Date() < deadline {
            if let exclusive = try lock.tryAcquire(.exclusive) {
                exclusive.release()
                try await Task.sleep(for: .milliseconds(5))
                continue
            }
            sharedLeaseConfirmed = true
            break
        }
        XCTAssertTrue(sharedLeaseConfirmed, "snapshot never acquired its shared lease")

        task.cancel()
        let successor = try lock.tryAcquire(.exclusive)
        XCTAssertNotNil(successor, "cancellation must release the lease while the queue remains blocked")
        successor?.release()

        unblock.signal()
        do {
            _ = try await task.value
            XCTFail("cancelled snapshot unexpectedly succeeded")
        } catch let error as ParakeetSourceSnapshotError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func test_cancellationBeforeCompletionLinearizationReturnsCancelledWithoutSnapshot() async throws {
        let fixture = try SourceFixture()
        let completionReady = DispatchSemaphore(value: 0)
        let releaseCompletion = DispatchSemaphore(value: 0)
        let provider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store, beforeCompletion: {
            completionReady.signal()
            releaseCompletion.wait()
        })
        let task = Task { () -> Result<VerifiedParakeetSourceSnapshot, Error> in
            do {
                return .success(try await provider.makeVerifiedSnapshot())
            } catch {
                return .failure(error)
            }
        }

        XCTAssertEqual(completionReady.wait(timeout: .now() + 2), .success)
        task.cancel()
        releaseCompletion.signal()

        let result = await task.value
        guard case let .failure(error) = result else {
            return XCTFail("cancellation before completion must not publish a snapshot")
        }
        XCTAssertEqual(error as? ParakeetSourceSnapshotError, .cancelled)

        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let successor = try lock.tryAcquire(.exclusive)
        XCTAssertNotNil(successor, "completion cancellation must release the shared lease")
        successor?.release()
    }

    func test_cancellationReturnsWhileActiveSnapshotReadIsBlocked() async throws {
        let fixture = try SourceFixture()
        let started = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        let provider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store, beforeArtifactRead: {
            started.signal()
            releaseRead.wait()
        })
        let task = Task { try await provider.makeVerifiedSnapshot() }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            task.cancel()
            cancelReturned.signal()
        }
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.25), .success, "Task.cancel must not wait for an active snapshot read")
        releaseRead.signal()

        do {
            _ = try await task.value
            XCTFail("cancelled snapshot unexpectedly succeeded")
        } catch let error as ParakeetSourceSnapshotError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected cancellation error: \\(error)")
        }
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let successor = try lock.tryAcquire(.exclusive)
        XCTAssertNotNil(successor)
        successor?.release()
    }

    func test_cancellationReleasesSharedLeaseWithoutPartialSnapshot() async throws {
        let fixture = try SourceFixture()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let provider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store, beforeArtifactRead: {
            started.signal()
            release.wait()
        })
        let task = Task { try await provider.makeVerifiedSnapshot() }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            release.signal()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled snapshot unexpectedly succeeded")
        } catch let error as ParakeetSourceSnapshotError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected cancellation error: \\(error)")
        }
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let successor = try await lock.acquire(.exclusive)
        successor.release()
    }

    func test_cancellationWhileWaitingForSharedLeaseReturnsTypedErrorAndNoLateSnapshot() async throws {
        let fixture = try SourceFixture()
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let holder = try await lock.acquire(.exclusive)
        defer { holder.release() }

        let result = Task { () -> Result<VerifiedParakeetSourceSnapshot, Error> in
            do {
                return .success(try await VerifiedParakeetSourceSnapshotProvider(store: fixture.store).makeVerifiedSnapshot())
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(try lock.tryAcquire(.shared), "exclusive holder must keep the snapshot waiting")

        result.cancel()
        let completed = await result.value
        guard case let .failure(error) = completed else {
            return XCTFail("cancelled snapshot unexpectedly produced a snapshot")
        }
        XCTAssertEqual(error as? ParakeetSourceSnapshotError, .cancelled)

        holder.release()
        let successor = try lock.tryAcquire(.exclusive)
        XCTAssertNotNil(successor, "cancelled snapshot must not acquire a late shared lease")
        successor?.release()
    }

    func test_fdopendirFailureReleasesDuplicatedDescriptorAndLease() async throws {
        let fixture = try SourceFixture()
        let provider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store, forceFdopendirFailure: true)
        let before = FileDescriptorCensus.count()
        for _ in 0..<100 {
            do {
                _ = try await provider.makeVerifiedSnapshot()
                XCTFail("forced fdopendir failure unexpectedly succeeded")
            } catch let error as ParakeetSourceSnapshotError {
                XCTAssertEqual(error, .sourceNotDirectory)
            }
        }
        XCTAssertEqual(FileDescriptorCensus.count(), before, "forced fdopendir failures must not leak duplicated directory descriptors")
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let successor = try lock.tryAcquire(.exclusive)
        XCTAssertNotNil(successor, "fdopendir failure must release the lease")
        successor?.release()
    }

    func test_blockingSnapshotRunsOnInjectedSerialQueue() async throws {
        let fixture = try SourceFixture()
        let key = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "mactalk.snapshot.test")
        queue.setSpecific(key: key, value: "snapshot")
        let observed = XCTestExpectation(description: "blocking queue observed")
        let provider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store, queue: queue, beforeArtifactRead: {
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), "snapshot")
            observed.fulfill()
        })
        _ = try await provider.makeVerifiedSnapshot()
        await fulfillment(of: [observed], timeout: 2)
    }

    func test_duplicateMarkerKeyFailsClosed() async throws {
        let fixture = try SourceFixture()
        let marker = fixture.source.appendingPathComponent(ParakeetSourceStore.identityMarkerName)
        let identity = fixture.identity
        let json = "{\"formatVersion\":1,\"formatVersion\":1,\"repository\":\"\(identity.repository)\",\"revision\":\"\(identity.revision)\",\"fluidAudioRevision\":\"\(identity.fluidAudioRevision)\",\"canonicalProvenanceSHA256\":\"\(identity.canonicalProvenanceSHA256)\"}"
        try Data(json.utf8).write(to: marker)
        let provider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store)
        do {
            _ = try await provider.makeVerifiedSnapshot()
            XCTFail("duplicate marker key accepted")
        } catch let error as ParakeetSourceSnapshotError {
            XCTAssertEqual(error, .markerDuplicateKey("formatVersion"))
        }
        try assertFailureReleased(parent: fixture.parent)
    }

    func testExtraSymlinkAndWrongStructuralRoleFailClosed() async throws {
        let extra = try SourceFixture()
        try Data("extra".utf8).write(to: extra.source.appendingPathComponent("unexpected.bin"))
        let extraProvider = VerifiedParakeetSourceSnapshotProvider(store: extra.store)
        do {
            _ = try await extraProvider.makeVerifiedSnapshot()
            XCTFail("extra file accepted")
        } catch { }
        try assertFailureReleased(parent: extra.parent)

        let symlink = try SourceFixture()
        let target = symlink.source.appendingPathComponent(symlink.entries[0].path)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: symlink.source.appendingPathComponent("parakeet_vocab.json"))
        let symlinkProvider = VerifiedParakeetSourceSnapshotProvider(store: symlink.store)
        do {
            _ = try await symlinkProvider.makeVerifiedSnapshot()
            XCTFail("symlink accepted")
        } catch { }
        try assertFailureReleased(parent: symlink.parent)

        let wrongRole = try SourceFixture()
        var entries = wrongRole.entries
        entries[0] = GeneratedParakeetManifestEntry(path: entries[0].path, size: entries[0].size, sha256: entries[0].sha256, component: entries[0].component, role: "weights")
        let alteredStore = ParakeetSourceStore(parent: wrongRole.parent, sourceDirectoryName: wrongRole.sourceName, entries: entries, identity: wrongRole.identity)
        let roleProvider = VerifiedParakeetSourceSnapshotProvider(store: alteredStore)
        do {
            _ = try await roleProvider.makeVerifiedSnapshot()
            XCTFail("wrong structural role accepted")
        } catch { }
        try assertFailureReleased(parent: wrongRole.parent)
    }

    func test_identityMismatchAndIncompleteSetsFailClosed() async throws {
        let fixture = try SourceFixture()
        let badIdentity = ParakeetSourceIdentity(formatVersion: 1, repository: "wrong", revision: fixture.identity.revision, fluidAudioRevision: fixture.identity.fluidAudioRevision, canonicalProvenanceSHA256: fixture.identity.canonicalProvenanceSHA256)
        let badStore = ParakeetSourceStore(parent: fixture.parent, sourceDirectoryName: fixture.sourceName, entries: fixture.entries, identity: badIdentity)
        let identityProvider = VerifiedParakeetSourceSnapshotProvider(store: badStore)
        do {
            _ = try await identityProvider.makeVerifiedSnapshot()
            XCTFail("identity mismatch accepted")
        } catch { }
        try assertFailureReleased(parent: fixture.parent)
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("parakeet_vocab.json"))
        let incompleteProvider = VerifiedParakeetSourceSnapshotProvider(store: fixture.store)
        do {
            _ = try await incompleteProvider.makeVerifiedSnapshot()
            XCTFail("incomplete source accepted")
        } catch { }
        try assertFailureReleased(parent: fixture.parent)
    }

    private func assertFailureReleased(parent: URL) throws {
        let lock = ParakeetStoreFileLock(storeParent: parent)
        let successor = try lock.tryAcquire(.exclusive)
        XCTAssertNotNil(successor, "failed snapshot must release its shared lease")
        successor?.release()
    }
}

private final class SourceFixture: @unchecked Sendable {
    let parent: URL
    let source: URL
    let sourceName = "source-generation"
    let identity = ParakeetSourceIdentity(formatVersion: 1, repository: "fixture/repo", revision: String(repeating: "a", count: 40), fluidAudioRevision: String(repeating: "b", count: 40), canonicalProvenanceSHA256: String(repeating: "c", count: 64))
    let entries: [GeneratedParakeetManifestEntry]

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("mactalk-source-parent-\(UUID().uuidString)", isDirectory: true)
        source = parent.appendingPathComponent(sourceName, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        XCTAssertEqual(chmod(source.path, 0o700), 0)
        entries = Self.makeEntries()
        for entry in entries {
            let url = source.appendingPathComponent(entry.path)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var current = directory
            while current.path != source.path && current.path.hasPrefix(source.path + "/") {
                XCTAssertEqual(chmod(current.path, 0o700), 0)
                current.deleteLastPathComponent()
            }
            try data(for: entry).write(to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
        }
        let marker = try JSONEncoder().encode(identity)
        let markerURL = source.appendingPathComponent(ParakeetSourceStore.identityMarkerName)
        try marker.write(to: markerURL)
        XCTAssertEqual(chmod(markerURL.path, 0o600), 0)
    }

    deinit { try? FileManager.default.removeItem(at: parent) }

    var store: ParakeetSourceStore { ParakeetSourceStore(parent: parent, sourceDirectoryName: sourceName, entries: entries, identity: identity) }

    func data(for entry: GeneratedParakeetManifestEntry) -> Data {
        Data("fixture:\(entry.component):\(entry.role)".utf8)
    }

    private static func makeEntries() -> [GeneratedParakeetManifestEntry] {
        let components = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
        var result = components.flatMap { component in
            ["model.mlmodel", "weights/weight.bin"].map { suffix in
                let role = suffix == "model.mlmodel" ? "specification" : "weights"
                let packagePath = component == "JointDecisionv3" ? "\(component).mlpackage" : "mlpackages/\(component).mlpackage"
                let path = "\(packagePath)/Data/com.apple.CoreML/\(suffix)"
                let data = Data("fixture:\(component):\(role)".utf8)
                return GeneratedParakeetManifestEntry(path: path, size: Int64(data.count), sha256: SHA256.hash(data: data).hexString, component: component, role: role)
            }
        }
        let vocab = Data("fixture:Vocabulary:vocabulary".utf8)
        result.append(GeneratedParakeetManifestEntry(path: "parakeet_vocab.json", size: Int64(vocab.count), sha256: SHA256.hash(data: vocab).hexString, component: "Vocabulary", role: "vocabulary"))
        return result
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
