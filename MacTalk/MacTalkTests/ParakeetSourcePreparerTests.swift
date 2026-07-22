import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacTalk

final class ParakeetSourcePreparerTests: XCTestCase {
    func test_canonicalConstructionIsPassiveAndExplicit() {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ParakeetSourceStore.canonical(parent: parent)
        XCTAssertEqual(store.sourceDirectoryName, "parakeet-tdt-0.6b-v3-source")
        XCTAssertEqual(store.entries, GeneratedModelProvenance.parakeetSource)
        XCTAssertEqual(store.identity, .production)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        XCTAssertNotEqual(ParakeetSourceStore.stagingPrefix, ".staging-")
        XCTAssertNotEqual(ParakeetSourceStore.backupPrefix, ".backup-")
    }

    func test_tinyMaterializerActivatesExactTreeAndMarker() async throws {
        let fixture = try SourcePreparationFixture()
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer)
        let activated = try await preparer.prepareIfNeeded()
        XCTAssertEqual(activated.lastPathComponent, fixture.store.sourceDirectoryName)
        XCTAssertEqual(try Data(contentsOf: activated.appendingPathComponent("parakeet_vocab.json")), Data("vocabulary".utf8))
        let marker = try Data(contentsOf: activated.appendingPathComponent(ParakeetSourceStore.identityMarkerName))
        XCTAssertLessThanOrEqual(marker.count, 16 * 1024)
        let markerObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: marker) as? [String: Any])
        XCTAssertEqual(markerObject["formatVersion"] as? Int, 1)
        XCTAssertEqual(markerObject["repository"] as? String, fixture.store.identity.repository)
        XCTAssertEqual(markerObject["revision"] as? String, fixture.store.identity.revision)
        XCTAssertEqual(markerObject["fluidAudioRevision"] as? String, fixture.store.identity.fluidAudioRevision)
        XCTAssertEqual(markerObject["canonicalProvenanceSHA256"] as? String, fixture.store.identity.canonicalProvenanceSHA256)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: activated.path)[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertTrue(fixture.entries.allSatisfy { entry in
            let attrs = try? FileManager.default.attributesOfItem(atPath: activated.appendingPathComponent(entry.path).path)
            return (attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600
        })
    }

    func test_exclusiveLeaseIsHeldThroughMaterialization() async throws {
        let fixture = try SourcePreparationFixture()
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let materializer = LeaseObservingSourceMaterializer(bytes: fixture.bytes, lock: lock)
        _ = try await ParakeetSourcePreparer(store: fixture.store, materializer: materializer).prepareIfNeeded()
        XCTAssertEqual(materializer.blockedAcquisitions, fixture.entries.count * 2)
    }

    func test_borrowedSnapshotValidationDoesNotReleaseExclusiveLease() async throws {
        let fixture = try SourcePreparationFixture()
        _ = try await ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer).prepareIfNeeded()
        let lease = try await ParakeetStoreFileLock(storeParent: fixture.parent).acquire(.exclusive)
        let snapshot = try await VerifiedParakeetSourceSnapshotProvider(store: fixture.store).makeVerifiedSnapshot(holding: lease)
        XCTAssertEqual(snapshot.identity, fixture.store.identity)
        XCTAssertNil(try ParakeetStoreFileLock(storeParent: fixture.parent).tryAcquire(.exclusive), "borrowed validation must retain caller's lease")
        lease.release()
    }

    func test_invalidStagingExtraPreservesPriorSource() async throws {
        let fixture = try SourcePreparationFixture()
        try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.sourceURL, withIntermediateDirectories: true)
        try Data("prior".utf8).write(to: fixture.sourceURL.appendingPathComponent("prior-sentinel"))
        XCTAssertEqual(chmod(fixture.parent.path, 0o700), 0)
        XCTAssertEqual(chmod(fixture.sourceURL.path, 0o700), 0)
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer, beforeValidation: {
            guard let staging = (try? FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) }) else { return }
            try? Data("extra".utf8).write(to: staging.appendingPathComponent("extra"))
        })
        do {
            _ = try await preparer.prepareIfNeeded()
            XCTFail("invalid staging unexpectedly activated")
        } catch {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL.appendingPathComponent("prior-sentinel")), Data("prior".utf8))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_invalidStagingSymlinkFailsBeforeActivation() async throws {
        let fixture = try SourcePreparationFixture()
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer, beforeValidation: {
            guard let staging = (try? FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) }) else { return }
            let target = staging.appendingPathComponent(fixture.entries[0].path)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.createSymbolicLink(at: target, withDestinationURL: staging.appendingPathComponent("parakeet_vocab.json"))
        })
        do {
            _ = try await preparer.prepareIfNeeded()
            XCTFail("symlink staging unexpectedly activated")
        } catch {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_cancellationAtMaterializerBarrierCleansOwnedStaging() async throws {
        let fixture = try SourcePreparationFixture()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let materializer = StickySourceMaterializer(bytes: fixture.bytes, started: started, release: release)
        let task = Task.detached { try await ParakeetSourcePreparer(store: fixture.store, materializer: materializer).prepareIfNeeded() }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("cancelled preparation unexpectedly activated")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertFalse((try FileManager.default.fileExists(atPath: fixture.parent.path) ? FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil) : []).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_bootstrapDoesNotReferenceInactiveSourcePreparation() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacTalk/Whisper/ParakeetBootstrap.swift")
        let source = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(source.contains("ParakeetSourcePreparer"))
        XCTAssertFalse(source.contains("parakeetSource"))
    }
}

private final class SourcePreparationFixture: @unchecked Sendable {
    let parent: URL
    let store: ParakeetSourceStore
    let entries: [GeneratedParakeetManifestEntry]
    let bytes: [String: Data]

    init() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("mactalk-preparer-\(UUID().uuidString)", isDirectory: true)
        let identity = ParakeetSourceIdentity(formatVersion: 1, repository: "fixture/repo", revision: String(repeating: "a", count: 40), fluidAudioRevision: String(repeating: "b", count: 40), canonicalProvenanceSHA256: String(repeating: "c", count: 64))
        var values: [(String, String, String, Data)] = []
        for component in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            for (role, suffix) in [("specification", "model.mlmodel"), ("weights", "weights/weight.bin")] {
                let path = "mlpackages/\(component).mlpackage/Data/com.apple.CoreML/\(suffix)"
                values.append((path, component, role, Data("\(component)-\(role)".utf8)))
            }
        }
        values.append(("parakeet_vocab.json", "Vocabulary", "vocabulary", Data("vocabulary".utf8)))
        entries = values.map { path, component, role, data in GeneratedParakeetManifestEntry(path: path, size: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), component: component, role: role) }
        bytes = Dictionary(uniqueKeysWithValues: zip(entries, values).map { ($0.0.path, $0.1.3) })
        store = ParakeetSourceStore(parent: parent, sourceDirectoryName: "source-generation", entries: entries, identity: identity)
    }

    var sourceURL: URL { parent.appendingPathComponent(store.sourceDirectoryName, isDirectory: true) }
    var materializer: TinySourceMaterializer { TinySourceMaterializer(bytes: bytes) }

    deinit { try? FileManager.default.removeItem(at: parent) }
}

private struct TinySourceMaterializer: ParakeetSourceArtifactMaterializing {
    let bytes: [String: Data]
    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) throws {
        try sink.write(bytes[entry.path]!)
    }
}

private final class StickySourceMaterializer: ParakeetSourceArtifactMaterializing, @unchecked Sendable {
    let bytes: [String: Data]
    let started: DispatchSemaphore
    let release: DispatchSemaphore
    private var first = true
    init(bytes: [String: Data], started: DispatchSemaphore, release: DispatchSemaphore) { self.bytes = bytes; self.started = started; self.release = release }
    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) throws {
        if first {
            first = false
            started.signal()
            release.wait()
        }
        try sink.write(bytes[entry.path]!)
    }
}

private final class LeaseObservingSourceMaterializer: ParakeetSourceArtifactMaterializing, @unchecked Sendable {
    let bytes: [String: Data]
    let lock: ParakeetStoreFileLock
    private(set) var blockedAcquisitions = 0
    init(bytes: [String: Data], lock: ParakeetStoreFileLock) { self.bytes = bytes; self.lock = lock }
    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) throws {
        if let lease = try lock.tryAcquire(.shared) { lease.release() } else { blockedAcquisitions += 1 }
        if let lease = try lock.tryAcquire(.exclusive) { lease.release() } else { blockedAcquisitions += 1 }
        try sink.write(bytes[entry.path]!)
    }
}
