import CryptoKit
import Darwin
import Foundation
import os
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

    func test_canonicalSourcePathsKeepJointAtSourceRootAndRejectLegacyMlpackagesPath() async throws {
        let fixture = try SourcePreparationFixture()
        let expectedJointPaths = [
            "JointDecisionv3.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin"
        ]
        XCTAssertEqual(fixture.entries.filter { $0.component == "JointDecisionv3" }.map(\.path), expectedJointPaths)

        let legacyEntries = fixture.entries.map { entry in
            guard entry.component == "JointDecisionv3" else { return entry }
            return GeneratedParakeetManifestEntry(
                path: "mlpackages/\(entry.path)", size: entry.size, sha256: entry.sha256,
                component: entry.component, role: entry.role)
        }
        let legacyStore = ParakeetSourceStore(parent: fixture.parent, sourceDirectoryName: fixture.store.sourceDirectoryName,
                                               entries: legacyEntries, identity: fixture.store.identity)
        let legacyBytes = Dictionary(uniqueKeysWithValues: zip(legacyEntries, fixture.entries).map { ($0.0.path, fixture.bytes[$0.1.path]!) })
        do {
            _ = try await ParakeetSourcePreparer(store: legacyStore, materializer: TinySourceMaterializer(bytes: legacyBytes)).prepareIfNeeded()
            XCTFail("legacy all-under-mlpackages paths were accepted")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .invalidManifest)
        }
    }

    func test_tinyMaterializerActivatesExactTreeAndMarker() async throws {
        let fixture = try SourcePreparationFixture()
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer)
        let activated = try await preparer.prepareIfNeeded()
        XCTAssertEqual(activated.lastPathComponent, fixture.store.sourceDirectoryName)
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
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
        XCTAssertEqual(try mode(of: activated.appendingPathComponent(ParakeetSourceStore.identityMarkerName)), 0o600)
        XCTAssertTrue(fixture.entries.allSatisfy { entry in
            let attrs = try? FileManager.default.attributesOfItem(atPath: activated.appendingPathComponent(entry.path).path)
            return (attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600
        })
        for directory in ["mlpackages", "mlpackages/Preprocessor.mlpackage", "mlpackages/Preprocessor.mlpackage/Data", "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML", "JointDecisionv3.mlpackage", "JointDecisionv3.mlpackage/Data", "JointDecisionv3.mlpackage/Data/com.apple.CoreML"] {
            XCTAssertEqual(try mode(of: activated.appendingPathComponent(directory)), 0o700)
        }
    }

    func test_asyncYieldingMaterializerIsAwaitedInsideLease() async throws {
        let fixture = try SourcePreparationFixture()
        let materializer = YieldingSourceMaterializer(bytes: fixture.bytes)
        _ = try await ParakeetSourcePreparer(store: fixture.store, materializer: materializer).prepareIfNeeded()
        XCTAssertEqual(materializer.calls, fixture.entries.count)
    }

    func test_invalidSourceNamesFailBeforeLockOrFilesystemMutation() async throws {
        let fixture = try SourcePreparationFixture()
        for name in ["../victim", "/absolute", ".", "..", ParakeetModelDownloader.folderName,
                     ParakeetSourceStore.stagingPrefix + "x", ParakeetSourceStore.backupPrefix + "x"] {
            let parent = fixture.parent.appendingPathComponent(UUID().uuidString)
            let compiled = parent.appendingPathComponent(ParakeetModelDownloader.folderName)
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: compiled.appendingPathComponent("sentinel"))
            let store = ParakeetSourceStore(parent: parent, sourceDirectoryName: name, entries: fixture.entries, identity: fixture.store.identity)
            let preparer = ParakeetSourcePreparer(store: store, materializer: fixture.materializer)
            do { _ = try await preparer.prepareIfNeeded(); XCTFail("accepted unsafe source name \(name)") } catch { }
            XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".mactalk-store.lock").path), "validation must precede lock mutation")
            try? FileManager.default.removeItem(at: parent)
        }
    }

    func test_cancellationBeforeActivationPreservesCompiledSentinelAndCleansStaging() async throws {
        let fixture = try SourcePreparationFixture()
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer, beforeActivation: {
            entered.signal()
            release.wait()
        })
        let task = Task.detached { try await preparer.prepareIfNeeded() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("cancelled preparation unexpectedly activated")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_sourceCollisionAfterValidationFailsClosedAndPreservesSentinels() async throws {
        let fixture = try SourcePreparationFixture()
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
        let collision = fixture.sourceURL
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer, beforeActivation: {
            try? FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
            try? Data("collision-sentinel".utf8).write(to: collision.appendingPathComponent("sentinel"))
        })
        do {
            _ = try await preparer.prepareIfNeeded()
            XCTFail("source collision unexpectedly activated")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .collision(fixture.store.sourceDirectoryName))
        }
        XCTAssertEqual(try Data(contentsOf: collision.appendingPathComponent("sentinel")), Data("collision-sentinel".utf8))
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: collision.appendingPathComponent("parakeet_vocab.json").path))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    private func mode(of url: URL) throws -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        return Int(info.st_mode & 0o777)
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

    func test_existingInvalidSourceFailsClosedBeforeStagingMutation() async throws {
        let fixture = try SourcePreparationFixture()
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
        try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.sourceURL, withIntermediateDirectories: true)
        try Data("prior".utf8).write(to: fixture.sourceURL.appendingPathComponent("prior-sentinel"))
        XCTAssertEqual(chmod(fixture.parent.path, 0o700), 0)
        XCTAssertEqual(chmod(fixture.sourceURL.path, 0o700), 0)
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer)
        do {
            _ = try await preparer.prepareIfNeeded()
            XCTFail("invalid source unexpectedly activated")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .collision(fixture.store.sourceDirectoryName))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL.appendingPathComponent("prior-sentinel")), Data("prior".utf8))
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_invalidStagingSymlinkFailsBeforeActivation() async throws {
        let fixture = try SourcePreparationFixture()
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
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
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_cancellationAtMaterializerBarrierCleansOwnedStaging() async throws {
        let fixture = try SourcePreparationFixture()
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
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
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
        XCTAssertFalse((try FileManager.default.fileExists(atPath: fixture.parent.path) ? FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil) : []).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_stagingTamperedDirectoryMarkerAndArtifactModesFailBeforeActivation() async throws {
        let tamperPaths = [
            "mlpackages/Preprocessor.mlpackage/Data",
            ParakeetSourceStore.identityMarkerName,
            fixtureArtifactPath
        ]
        for relativePath in tamperPaths {
            let fixture = try SourcePreparationFixture()
            let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
            let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer, beforeValidation: {
                let staging = (try? FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
                if let staging { XCTAssertEqual(chmod(staging.appendingPathComponent(relativePath).path, 0o755), 0, relativePath) }
            })
            do {
                _ = try await preparer.prepareIfNeeded()
                XCTFail("tampered staging mode unexpectedly activated: \(relativePath)")
            } catch let error as ParakeetSourcePreparationError {
                XCTAssertEqual(error, .validationFailed)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path), relativePath)
            XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
            XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
        }
    }

    func test_postMkdirStagingFailureRemovesEmptyDirectory() async throws {
        let fixture = try SourcePreparationFixture()
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer, afterStagingDirectoryCreated: {
            guard let staging = (try? FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil))?.first(where: { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) }) else { return }
            _ = chmod(staging.path, 0o755)
        })
        do {
            _ = try await preparer.prepareIfNeeded()
            XCTFail("post-mkdir staging corruption unexpectedly succeeded")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .invalidTree)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_cancellationWhileValidatingExistingSourceMapsToTypedCancellation() async throws {
        let fixture = try SourcePreparationFixture()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        _ = try await ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer).prepareIfNeeded()
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer, beforeExistingValidationCompletion: {
            entered.signal()
            release.wait()
        })
        let task = Task.detached { try await preparer.prepareIfNeeded() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        XCTAssertNil(try lock.tryAcquire(.exclusive), "preparer must retain its exclusive lease while validation is blocked")
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("cancelled existing validation unexpectedly succeeded")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL.appendingPathComponent("parakeet_vocab.json")), Data("vocabulary".utf8))
        let successor = try lock.tryAcquire(.exclusive)
        XCTAssertNotNil(successor)
        successor?.release()
    }

    func test_cancellationWhileValidatingStagingMapsToTypedCancellationAndCleansStaging() async throws {
        let fixture = try SourcePreparationFixture()
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer, beforeStagingValidationCompletion: {
            entered.signal()
            release.wait()
        })
        let task = Task.detached { try await preparer.prepareIfNeeded() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertNil(try ParakeetStoreFileLock(storeParent: fixture.parent).tryAcquire(.exclusive))
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("cancelled staging validation unexpectedly succeeded")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(at: fixture.parent, includingPropertiesForKeys: nil)).contains { $0.lastPathComponent.hasPrefix(ParakeetSourceStore.stagingPrefix) })
    }

    func test_lateMaterializerWriteAfterFinishSeesClosedSink() async throws {
        let fixture = try SourcePreparationFixture()
        let materializer = LateWritingSourceMaterializer(bytes: fixture.bytes)
        _ = try await ParakeetSourcePreparer(store: fixture.store, materializer: materializer).prepareIfNeeded()
        materializer.releaseLateWrite()
        let result = await materializer.lateWriteResult()
        XCTAssertEqual(result, .sinkClosed)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL.appendingPathComponent("parakeet_vocab.json")), Data("vocabulary".utf8))
    }

    private var fixtureArtifactPath: String { "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/model.mlmodel" }

    func test_weightReuseSkipsMaterializerForSuccessfulWeightsAndDownloadsRemainder() async throws {
        let fixture = try SourcePreparationFixture()
        try fixture.installCompiledWeights(mode: 0o600)
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))

        let recording = RecordingSourceMaterializer(bytes: fixture.bytes)
        let reuser = try fixture.makeWeightReuser()
        let preparer = ParakeetSourcePreparer(store: fixture.store, materializer: recording, weightReuser: reuser)
        let activated = try await preparer.prepareIfNeeded()

        let downloaded = recording.materializedPaths
        XCTAssertEqual(downloaded.count, 5, "four reused weights leave five downloads")
        XCTAssertFalse(downloaded.contains { $0.contains("weights/weight.bin") })
        XCTAssertTrue(downloaded.contains("parakeet_vocab.json"))
        XCTAssertEqual(recording.beginCalls.count, 1)
        XCTAssertEqual(recording.beginCalls[0].map(\.path), downloaded)

        for entry in fixture.entries where entry.role == "weights" {
            XCTAssertEqual(try Data(contentsOf: activated.appendingPathComponent(entry.path)), fixture.bytes[entry.path]!)
        }
        XCTAssertEqual(try Data(contentsOf: activated.appendingPathComponent("parakeet_vocab.json")), Data("vocabulary".utf8))
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
    }

    func test_unavailableCompiledWeightFallsBackToMaterializerDownload() async throws {
        let fixture = try SourcePreparationFixture()
        try fixture.installCompiledWeights(mode: 0o600)
        // Corrupt one compiled weight so reuse is unavailable for that component only.
        let bad = fixture.parent
            .appendingPathComponent(ParakeetModelDownloader.folderName)
            .appendingPathComponent("Encoder.mlmodelc/weights/weight.bin")
        try Data("not-encoder-weight".utf8).write(to: bad)
        XCTAssertEqual(chmod(bad.path, 0o600), 0)

        let recording = RecordingSourceMaterializer(bytes: fixture.bytes)
        let reuser = try fixture.makeWeightReuser()
        _ = try await ParakeetSourcePreparer(store: fixture.store, materializer: recording, weightReuser: reuser).prepareIfNeeded()

        let downloaded = recording.materializedPaths
        XCTAssertEqual(downloaded.count, 6)
        XCTAssertTrue(downloaded.contains { $0.contains("Encoder") && $0.contains("weights/weight.bin") })
        XCTAssertEqual(downloaded.filter { $0.contains("weights/weight.bin") }.count, 1)
        XCTAssertEqual(recording.beginCalls[0].count, 6)
    }

    func test_recoversValidatedOwnedBackupOnlyWhenActiveSourceIsAbsent() async throws {
        let fixture = try SourcePreparationFixture()
        _ = try await ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer).prepareIfNeeded()
        let backupName = ParakeetSourceStore.backupPrefix + UUID().uuidString
        try FileManager.default.moveItem(
            at: fixture.sourceURL,
            to: fixture.parent.appendingPathComponent(backupName, isDirectory: true)
        )
        let recording = RecordingSourceMaterializer(bytes: fixture.bytes)
        let recovered = try await ParakeetSourcePreparer(store: fixture.store, materializer: recording).prepareIfNeeded()

        XCTAssertEqual(recovered, fixture.sourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.appendingPathComponent("parakeet_vocab.json").path))
        XCTAssertTrue(recording.materializedPaths.isEmpty, "unexpected downloads: \(recording.materializedPaths)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(backupName).path), "backup survived recovery")
    }

    func test_ownedStaleArtifactsAreRemovedWithoutTouchingCompiledGeneration() async throws {
        let fixture = try SourcePreparationFixture()
        try fixture.installCompiledWeights(mode: 0o600)
        let compiled = fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName)
        try Data("compiled-sentinel".utf8).write(to: compiled.appendingPathComponent("sentinel"))
        let staleNames = [
            ParakeetSourceStore.stagingPrefix + UUID().uuidString,
            ParakeetSourceStore.backupPrefix + UUID().uuidString
        ]
        for name in staleNames {
            let stale = fixture.parent.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: stale.appendingPathComponent("sentinel"))
        }

        _ = try await ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer).prepareIfNeeded()

        for name in staleNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(name).path), "owned stale artifact survived: \(name)")
        }
        XCTAssertEqual(try Data(contentsOf: compiled.appendingPathComponent("sentinel")), Data("compiled-sentinel".utf8))
    }

    func test_interruptedBackupPromotionLeavesRecoverableValidatedBackup() async throws {
        let fixture = try SourcePreparationFixture()
        let collisionCreated = OSAllocatedUnfairLock(initialState: false)
        let preparer = ParakeetSourcePreparer(
            store: fixture.store,
            materializer: fixture.materializer,
            beforeBackupPromotion: {
                collisionCreated.withLock { didCreate in
                    guard !didCreate else { return }
                    didCreate = true
                    try? FileManager.default.createDirectory(at: fixture.sourceURL, withIntermediateDirectories: false)
                }
            }
        )
        do {
            _ = try await preparer.prepareIfNeeded()
            XCTFail("promotion collision unexpectedly succeeded")
        } catch let error as ParakeetSourcePreparationError {
            XCTAssertEqual(error, .collision(fixture.store.sourceDirectoryName))
        }
        XCTAssertTrue(collisionCreated.withLock { $0 })
        try FileManager.default.removeItem(at: fixture.sourceURL)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path)
            .filter { $0.hasPrefix(ParakeetSourceStore.backupPrefix) }
        XCTAssertEqual(backupNames.count, 1)

        let recovered = try await ParakeetSourcePreparer(store: fixture.store, materializer: fixture.materializer).prepareIfNeeded()
        XCTAssertEqual(recovered, fixture.sourceURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(backupNames[0]).path), "backup survived successful recovery")
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
                let packagePath = component == "JointDecisionv3" ? "\(component).mlpackage" : "mlpackages/\(component).mlpackage"
                let path = "\(packagePath)/Data/com.apple.CoreML/\(suffix)"
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

    func installCompiledWeights(mode: mode_t) throws {
        let root = parent.appendingPathComponent(ParakeetModelDownloader.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        for entry in entries where entry.role == "weights" {
            let compiledPath = "\(entry.component).mlmodelc/weights/weight.bin"
            let url = root.appendingPathComponent(compiledPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes[entry.path]!.write(to: url)
            XCTAssertEqual(chmod(url.path, mode), 0)
        }
    }

    func makeWeightReuser() throws -> ParakeetCompiledWeightReuser {
        let compiledEntries = entries.compactMap { entry -> GeneratedParakeetManifestEntry? in
            guard entry.role == "weights" else { return nil }
            return GeneratedParakeetManifestEntry(
                path: "\(entry.component).mlmodelc/weights/weight.bin",
                size: entry.size,
                sha256: entry.sha256,
                component: entry.component,
                role: "compiled"
            )
        }
        return try ParakeetCompiledWeightReuser(
            store: store,
            sourceEntries: entries.filter { $0.role == "weights" },
            compiledEntries: compiledEntries
        )
    }

    deinit { try? FileManager.default.removeItem(at: parent) }
}

private final class RecordingSourceMaterializer: ParakeetSourceArtifactMaterializing, @unchecked Sendable {
    let bytes: [String: Data]
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var paths: [String] = []
        var beginCalls: [[GeneratedParakeetManifestEntry]] = []
    }

    init(bytes: [String: Data]) { self.bytes = bytes }

    var materializedPaths: [String] { state.withLock { $0.paths } }
    var beginCalls: [[GeneratedParakeetManifestEntry]] { state.withLock { $0.beginCalls } }

    func beginPreparation(operationID: UUID, remainingEntries: [GeneratedParakeetManifestEntry]) throws {
        state.withLock { $0.beginCalls.append(remainingEntries) }
    }

    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) async throws {
        state.withLock { $0.paths.append(entry.path) }
        try sink.write(bytes[entry.path]!)
    }
}

private struct TinySourceMaterializer: ParakeetSourceArtifactMaterializing {
    let bytes: [String: Data]
    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) async throws {
        try sink.write(bytes[entry.path]!)
    }
}

private final class YieldingSourceMaterializer: ParakeetSourceArtifactMaterializing, @unchecked Sendable {
    let bytes: [String: Data]
    private(set) var calls = 0
    init(bytes: [String: Data]) { self.bytes = bytes }
    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) async throws {
        await Task.yield()
        calls += 1
        try sink.write(bytes[entry.path]!)
    }
}

private final class StickySourceMaterializer: ParakeetSourceArtifactMaterializing, @unchecked Sendable {
    let bytes: [String: Data]
    let started: DispatchSemaphore
    let release: DispatchSemaphore
    private var first = true
    init(bytes: [String: Data], started: DispatchSemaphore, release: DispatchSemaphore) { self.bytes = bytes; self.started = started; self.release = release }
    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) async throws {
        if first {
            first = false
            started.signal()
            let release = self.release
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    release.wait()
                    continuation.resume()
                }
            }
        }
        try sink.write(bytes[entry.path]!)
    }
}

private final class LateWritingSourceMaterializer: ParakeetSourceArtifactMaterializing, @unchecked Sendable {
    let bytes: [String: Data]
    private let release = DispatchSemaphore(value: 0)
    private let started = DispatchSemaphore(value: 0)
    private let completed = DispatchSemaphore(value: 0)
    private let resultLock = NSLock()
    private var result: ParakeetSourcePreparationError?
    private var writerStarted = false

    init(bytes: [String: Data]) { self.bytes = bytes }

    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) async throws {
        try sink.write(bytes[entry.path]!)
        if !writerStarted {
            writerStarted = true
            let release = self.release
            let started = self.started
            let completed = self.completed
            DispatchQueue.global().async {
                started.signal()
                release.wait()
                do {
                    try sink.write(Data("late-write".utf8))
                } catch let error as ParakeetSourcePreparationError {
                    self.resultLock.lock()
                    self.result = error
                    self.resultLock.unlock()
                } catch {
                    self.resultLock.lock()
                    self.result = .activationFailed
                    self.resultLock.unlock()
                }
                completed.signal()
            }
        }
    }

    func releaseLateWrite() {
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        release.signal()
    }

    func lateWriteResult() async -> ParakeetSourcePreparationError? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.completed.wait()
                self.resultLock.lock()
                let result = self.result
                self.resultLock.unlock()
                continuation.resume(returning: result)
            }
        }
    }
}

private final class LeaseObservingSourceMaterializer: ParakeetSourceArtifactMaterializing, @unchecked Sendable {
    let bytes: [String: Data]
    let lock: ParakeetStoreFileLock
    private(set) var blockedAcquisitions = 0
    init(bytes: [String: Data], lock: ParakeetStoreFileLock) { self.bytes = bytes; self.lock = lock }
    func materialize(entry: GeneratedParakeetManifestEntry, sink: ParakeetSourceArtifactSink) async throws {
        if let lease = try lock.tryAcquire(.shared) { lease.release() } else { blockedAcquisitions += 1 }
        if let lease = try lock.tryAcquire(.exclusive) { lease.release() } else { blockedAcquisitions += 1 }
        try sink.write(bytes[entry.path]!)
    }
}
