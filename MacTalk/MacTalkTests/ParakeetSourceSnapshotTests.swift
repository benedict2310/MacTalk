import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacTalk

final class ParakeetSourceSnapshotTests: XCTestCase {
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
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("cancelled snapshot unexpectedly succeeded")
        } catch { }
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let successor = try await lock.acquire(.exclusive)
        successor.release()
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
        do {
            _ = try await VerifiedParakeetSourceSnapshotProvider(store: fixture.store).makeVerifiedSnapshot()
            XCTFail("duplicate marker key accepted")
        } catch let error as ParakeetSourceSnapshotError {
            XCTAssertEqual(error, .markerDuplicateKey("formatVersion"))
        }
    }

    func testExtraSymlinkAndWrongStructuralRoleFailClosed() async throws {
        let extra = try SourceFixture()
        try Data("extra".utf8).write(to: extra.source.appendingPathComponent("unexpected.bin"))
        do {
            _ = try await VerifiedParakeetSourceSnapshotProvider(store: extra.store).makeVerifiedSnapshot()
            XCTFail("extra file accepted")
        } catch { }

        let symlink = try SourceFixture()
        let target = symlink.source.appendingPathComponent(symlink.entries[0].path)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: symlink.source.appendingPathComponent("parakeet_vocab.json"))
        do {
            _ = try await VerifiedParakeetSourceSnapshotProvider(store: symlink.store).makeVerifiedSnapshot()
            XCTFail("symlink accepted")
        } catch { }

        let wrongRole = try SourceFixture()
        var entries = wrongRole.entries
        entries[0] = GeneratedParakeetManifestEntry(path: entries[0].path, size: entries[0].size, sha256: entries[0].sha256, component: entries[0].component, role: "weights")
        let alteredStore = ParakeetSourceStore(parent: wrongRole.parent, sourceDirectoryName: wrongRole.sourceName, entries: entries, identity: wrongRole.identity)
        do {
            _ = try await VerifiedParakeetSourceSnapshotProvider(store: alteredStore).makeVerifiedSnapshot()
            XCTFail("wrong structural role accepted")
        } catch { }
    }

    func test_identityMismatchAndIncompleteSetsFailClosed() async throws {
        let fixture = try SourceFixture()
        let badIdentity = ParakeetSourceIdentity(formatVersion: 1, repository: "wrong", revision: fixture.identity.revision, fluidAudioRevision: fixture.identity.fluidAudioRevision, canonicalProvenanceSHA256: fixture.identity.canonicalProvenanceSHA256)
        let badStore = ParakeetSourceStore(parent: fixture.parent, sourceDirectoryName: fixture.sourceName, entries: fixture.entries, identity: badIdentity)
        do {
            _ = try await VerifiedParakeetSourceSnapshotProvider(store: badStore).makeVerifiedSnapshot()
            XCTFail("identity mismatch accepted")
        } catch { }
        try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("parakeet_vocab.json"))
        do {
            _ = try await VerifiedParakeetSourceSnapshotProvider(store: fixture.store).makeVerifiedSnapshot()
            XCTFail("incomplete source accepted")
        } catch { }
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
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data(for: entry).write(to: url)
        }
        let marker = try JSONEncoder().encode(identity)
        try marker.write(to: source.appendingPathComponent(ParakeetSourceStore.identityMarkerName))
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
                let path = "mlpackages/\(component).mlpackage/Data/com.apple.CoreML/\(suffix)"
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
