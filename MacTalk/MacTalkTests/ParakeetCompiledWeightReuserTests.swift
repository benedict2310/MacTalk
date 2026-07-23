import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacTalk

final class ParakeetCompiledWeightReuserTests: XCTestCase {
    func test_configurationAcceptsCanonicalFourWeightMappingIncludingRootJoint() throws {
        let entries = fixtureEntries()
        let reuser = try ParakeetCompiledWeightReuser(
            store: fixtureStore(entries: entries.source),
            sourceEntries: entries.source,
            compiledEntries: entries.compiled
        )
        XCTAssertEqual(reuser.mappings.count, 4)
        XCTAssertEqual(reuser.mappings.first(where: { $0.component == .joint })?.sourcePath,
                       "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
    }

    func test_configurationAcceptsFullGeneratedManifestsBySelectingExactWeightEntries() throws {
        let reuser = try ParakeetCompiledWeightReuser(
            store: .canonical(parent: temporaryParent()),
            sourceEntries: GeneratedModelProvenance.parakeetSource,
            compiledEntries: GeneratedModelProvenance.parakeetCompiled
        )
        XCTAssertEqual(reuser.mappings.map(\.component), ParakeetSourceComponent.allCases)
    }

    func test_configurationRejectsAlternateCompiledRootBeforeFilesystemMutation() throws {
        let parent = temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let entries = fixtureEntries()
        XCTAssertThrowsError(try ParakeetCompiledWeightReuser(
            store: fixtureStore(entries: entries.source, parent: parent),
            sourceEntries: entries.source,
            compiledEntries: entries.compiled,
            compiledDirectoryName: "alternate-root"
        )) { error in
            XCTAssertEqual(error as? ParakeetCompiledWeightReuseConfigurationError, .invalidCompiledDirectoryName)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".mactalk-store.lock").path))
    }

    func test_configurationRejectsPathRoleTupleAndDuplicateBeforeFilesystemMutation() throws {
        let parent = temporaryParent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let entries = fixtureEntries()
        let bad = GeneratedParakeetManifestEntry(
            path: entries.source[0].path, size: entries.source[0].size,
            sha256: entries.source[0].sha256, component: entries.source[0].component, role: "specification"
        )
        XCTAssertThrowsError(try ParakeetCompiledWeightReuser(
            store: fixtureStore(entries: entries.source, parent: parent),
            sourceEntries: [bad] + entries.source.dropFirst(), compiledEntries: entries.compiled
        )) { error in
            XCTAssertTrue(error is ParakeetCompiledWeightReuseConfigurationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(".mactalk-store.lock").path))
    }

    func test_reusesVerifiedWeightWithHardLinkAndCallerOwnership() async throws {
        let fixture = try ReuseFixture()
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let lease = try await lock.acquire(.exclusive)
        let staging = try openStaging(fixture.staging)
        defer { close(staging); lease.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        let reuser = try fixture.reuser()
        let result = try reuser.reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)
        guard case .reused(.hardLink) = result else { return XCTFail("expected hard link, got \(result)") }
        let destination = fixture.destination
        var sourceInfo = stat(); var destinationInfo = stat()
        XCTAssertEqual(stat(fixture.compiled.path, &sourceInfo), 0)
        XCTAssertEqual(stat(destination.path, &destinationInfo), 0)
        XCTAssertEqual(sourceInfo.st_dev, destinationInfo.st_dev)
        XCTAssertEqual(sourceInfo.st_ino, destinationInfo.st_ino)
        XCTAssertEqual(sourceInfo.st_mode & 0o777, 0o600)
        XCTAssertEqual(destinationInfo.st_mode & 0o777, 0o600)
        var stagingInfo = stat()
        XCTAssertEqual(fstat(staging, &stagingInfo), 0, "caller-owned staging FD remains usable")
    }

    func test_copyFallbackPreservesSourceAndUses0600Destination() async throws {
        let fixture = try ReuseFixture(sourceMode: 0o644)
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let lease = try await lock.acquire(.exclusive)
        let staging = try openStaging(fixture.staging)
        defer { close(staging); lease.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        let result = try fixture.reuser().reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)
        guard case .reused(.copy) = result else { return XCTFail("expected copy") }
        var info = stat(); XCTAssertEqual(stat(fixture.compiled.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o644)
        let destinationData = try Data(contentsOf: fixture.destination)
        XCTAssertEqual(destinationData, fixture.data)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.destination.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_legacyShortAndOversizedArtifactsAreUnavailableWithoutDestination() async throws {
        for artifact in [Data("short".utf8), Data(repeating: 0x41, count: 16)] {
            let fixture = try ReuseFixture()
            try artifact.write(to: fixture.compiled)
            let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
            let lease = try await lock.acquire(.exclusive)
            let staging = try openStaging(fixture.staging)
            let result = try fixture.reuser().reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)
            guard case .unavailable(.sizeMismatch) = result else { XCTFail("expected size mismatch, got \(result)"); continue }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            close(staging); lease.release()
        }
    }

    func test_invalidLegacyArtifactIsUnavailableWithoutDestination() async throws {
        let fixture = try ReuseFixture()
        try FileManager.default.removeItem(at: fixture.compiled)
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let lease = try await lock.acquire(.exclusive)
        let staging = try openStaging(fixture.staging)
        defer { close(staging); lease.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        let result = try fixture.reuser().reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)
        guard case .unavailable = result else { return XCTFail("expected unavailable") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func test_destinationCollisionIsTypedAndPreserved() async throws {
        let fixture = try ReuseFixture()
        try FileManager.default.createDirectory(at: fixture.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var directory = fixture.destination.deletingLastPathComponent()
        while directory.path != fixture.staging.path && directory.path.hasPrefix(fixture.staging.path + "/") {
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
            directory.deleteLastPathComponent()
        }
        try Data("existing".utf8).write(to: fixture.destination)
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let lease = try await lock.acquire(.exclusive)
        let staging = try openStaging(fixture.staging)
        defer { close(staging); lease.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        XCTAssertThrowsError(try fixture.reuser().reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)) { error in
            XCTAssertEqual(error as? ParakeetCompiledWeightReuseError, .destinationCollision)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("existing".utf8))
    }

    func test_sameSizeCorruptSymlinkDirectoryAndFIFOAreUnavailableWithoutLeaf() async throws {
        for kind in ["corrupt", "symlink", "directory", "fifo"] {
            let fixture = try ReuseFixture()
            switch kind {
            case "corrupt":
                try Data(repeating: 0x41, count: fixture.data.count).write(to: fixture.compiled)
            case "symlink":
                try FileManager.default.removeItem(at: fixture.compiled)
                XCTAssertEqual(symlink("attacker", fixture.compiled.path), 0)
            case "directory":
                try FileManager.default.removeItem(at: fixture.compiled)
                try FileManager.default.createDirectory(at: fixture.compiled, withIntermediateDirectories: false)
            default:
                try FileManager.default.removeItem(at: fixture.compiled)
                XCTAssertEqual(mkfifo(fixture.compiled.path, 0o600), 0)
            }
            let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
            let lease = try await lock.acquire(.exclusive)
            let staging = try openStaging(fixture.staging)
            let result = try fixture.reuser().reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)
            if case .reused = result { XCTFail("\(kind) unexpectedly reused") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            close(staging); lease.release()
        }
    }

    func test_corruptComponentDoesNotPreventIndependentValidComponent() async throws {
        let fixture = try ReuseFixture()
        let other = fixture.parent.appendingPathComponent("parakeet-tdt-0.6b-v3/Decoder.mlmodelc/weights/weight.bin")
        try Data(repeating: 0x42, count: 7).write(to: other)
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let lease = try await lock.acquire(.exclusive)
        let staging = try openStaging(fixture.staging)
        defer { close(staging); lease.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        let result = try fixture.reuser().reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)
        guard case .reused = result else { return XCTFail("valid Encoder must not be blocked by Decoder") }
    }

    func test_compiledLeafSwapToSymlinkFallsBackWithoutLeavingSymlink() async throws {
        let fixture = try ReuseFixture()
        let old = fixture.compiled.deletingLastPathComponent().appendingPathComponent("old-weight.bin")
        let reuser = try fixture.reuser(hooks: .init(afterSourceVerification: {
            XCTAssertEqual(rename(fixture.compiled.path, old.path), 0)
            XCTAssertEqual(symlink("attacker", fixture.compiled.path), 0)
        }))
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let lease = try await lock.acquire(.exclusive)
        let staging = try openStaging(fixture.staging)
        defer { close(staging); lease.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        let result = try reuser.reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)
        guard case .reused(.copy) = result else { return XCTFail("symlink swap must use retained FD copy, got \(result)") }
        var destinationInfo = stat()
        XCTAssertEqual(lstat(fixture.destination.path, &destinationInfo), 0)
        XCTAssertEqual(destinationInfo.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.data)
        var compiledInfo = stat()
        XCTAssertEqual(lstat(fixture.compiled.path, &compiledInfo), 0)
        XCTAssertEqual(compiledInfo.st_mode & S_IFMT, S_IFLNK)
    }

    func test_sourceLeafSwapFallsBackToRetainedVerifiedFD() async throws {
        let fixture = try ReuseFixture()
        let old = fixture.compiled.deletingLastPathComponent().appendingPathComponent("old-weight.bin")
        let reuser = try fixture.reuser(hooks: .init(afterSourceVerification: {
            XCTAssertEqual(rename(fixture.compiled.path, old.path), 0)
            try? Data("attacker-bytes".utf8).write(to: fixture.compiled)
            _ = chmod(fixture.compiled.path, 0o600)
        }))
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let lease = try await lock.acquire(.exclusive)
        let staging = try openStaging(fixture.staging)
        defer { close(staging); lease.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        let result = try reuser.reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)
        guard case .reused(.copy) = result else { return XCTFail("swapped leaf must use retained FD copy") }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.data)
    }

    func test_destinationTamperIsReverifiedAndCleaned() async throws {
        let fixture = try ReuseFixture(sourceMode: 0o644)
        let reuser = try fixture.reuser(hooks: .init(beforeDestinationVerification: {
            try? Data("tampered".utf8).write(to: fixture.destination)
        }))
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let lease = try await lock.acquire(.exclusive)
        let staging = try openStaging(fixture.staging)
        defer { close(staging); lease.release(); try? FileManager.default.removeItem(at: fixture.parent) }
        XCTAssertThrowsError(try reuser.reuse(sourceEntry: fixture.sourceEntry, holding: lease, stagingRootFD: staging)) { error in
            XCTAssertEqual(error as? ParakeetCompiledWeightReuseError, .destinationVerificationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func test_sharedReleasedAndCancelledLeasesAreTypedAndCleanup() async throws {
        let fixture = try ReuseFixture()
        let lock = ParakeetStoreFileLock(storeParent: fixture.parent)
        let shared = try await lock.acquire(.shared)
        let staging = try openStaging(fixture.staging)
        XCTAssertThrowsError(try fixture.reuser().reuse(sourceEntry: fixture.sourceEntry, holding: shared, stagingRootFD: staging)) { error in
            XCTAssertEqual(error as? ParakeetCompiledWeightReuseError, .leaseNotExclusive)
        }
        shared.release()
        let exclusive = try await lock.acquire(.exclusive)
        exclusive.release()
        XCTAssertThrowsError(try fixture.reuser().reuse(sourceEntry: fixture.sourceEntry, holding: exclusive, stagingRootFD: staging)) { error in
            XCTAssertEqual(error as? ParakeetCompiledWeightReuseError, .leaseUnavailable)
        }
        close(staging); try? FileManager.default.removeItem(at: fixture.parent)

        let cancelledFixture = try ReuseFixture(sourceMode: 0o644)
        let cancelledLock = ParakeetStoreFileLock(storeParent: cancelledFixture.parent)
        let cancelledLease = try await cancelledLock.acquire(.exclusive)
        let cancelledStaging = try openStaging(cancelledFixture.staging)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cancelledReuser = try cancelledFixture.reuser(hooks: .init(afterSourceVerification: {
            entered.signal(); release.wait()
        }))
        let task = Task<ParakeetCompiledWeightReuseResult, Error> { @Sendable in
            try cancelledReuser.reuse(sourceEntry: cancelledFixture.sourceEntry, holding: cancelledLease, stagingRootFD: cancelledStaging)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel(); release.signal()
        do { _ = try await task.value; XCTFail("cancellation unexpectedly succeeded") }
        catch let error as ParakeetCompiledWeightReuseError { XCTAssertEqual(error, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledFixture.destination.path))
        var info = stat(); XCTAssertEqual(fstat(cancelledStaging, &info), 0)
        close(cancelledStaging); cancelledLease.release(); try? FileManager.default.removeItem(at: cancelledFixture.parent)
    }

    private func fixtureEntries() -> (source: [GeneratedParakeetManifestEntry], compiled: [GeneratedParakeetManifestEntry]) {
        let values: [(String, String, String)] = [
            ("Preprocessor", "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "pre"),
            ("Encoder", "mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "enc"),
            ("Decoder", "mlpackages/Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "dec"),
            ("JointDecisionv3", "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "joint")
        ]
        let source = values.map { component, path, value in
            let data = Data(value.utf8)
            return GeneratedParakeetManifestEntry(path: path, size: Int64(data.count), sha256: digest(data), component: component, role: "weights")
        }
        let compiled = zip(values, source).map { (value, source) in
            GeneratedParakeetManifestEntry(path: value.0 == "JointDecisionv3" ? "JointDecisionv3.mlmodelc/weights/weight.bin" : "\(value.0).mlmodelc/weights/weight.bin", size: source.size, sha256: source.sha256, component: value.0, role: "compiled")
        }
        return (source, compiled)
    }

    private func fixtureStore(entries: [GeneratedParakeetManifestEntry], parent: URL? = nil) -> ParakeetSourceStore {
        ParakeetSourceStore(parent: parent ?? temporaryParent(), sourceDirectoryName: "source", entries: entries, identity: .production)
    }
    private func temporaryParent() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("reuse-config-\(UUID().uuidString)") }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func openStaging(_ url: URL) throws -> Int32 { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); XCTAssertEqual(chmod(url.path, 0o700), 0); let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0); return fd }
}

private final class ReuseFixture: @unchecked Sendable {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("reuse-\(UUID().uuidString)")
    let staging: URL
    let compiled: URL
    let destination: URL
    let sourceEntry: GeneratedParakeetManifestEntry
    let sourceEntries: [GeneratedParakeetManifestEntry]
    let compiledEntries: [GeneratedParakeetManifestEntry]
    let data: Data
    let sourceMode: mode_t

    init(sourceMode: mode_t = 0o600) throws {
        self.sourceMode = sourceMode
        staging = parent.appendingPathComponent("staging", isDirectory: true)
        let values = [("Preprocessor", "mlpackages/Preprocessor.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "Preprocessor"),
                      ("Encoder", "mlpackages/Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "verified-weight"),
                      ("Decoder", "mlpackages/Decoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "Decoder"),
                      ("JointDecisionv3", "JointDecisionv3.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "JointDecisionv3")]
        sourceEntries = values.map { component, path, value in
            let bytes = Data(value.utf8)
            return GeneratedParakeetManifestEntry(path: path, size: Int64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), component: component, role: "weights")
        }
        sourceEntry = sourceEntries[1]
        data = Data("verified-weight".utf8)
        compiledEntries = sourceEntries.map { entry in
            GeneratedParakeetManifestEntry(path: "\(entry.component).mlmodelc/weights/weight.bin", size: entry.size, sha256: entry.sha256, component: entry.component, role: "compiled")
        }
        compiled = parent.appendingPathComponent("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/weights/weight.bin")
        destination = staging.appendingPathComponent(sourceEntry.path)
        try FileManager.default.createDirectory(at: compiled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for entry in compiledEntries {
            let url = parent.appendingPathComponent("parakeet-tdt-0.6b-v3").appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = entry.component == "Encoder" ? data : Data(entry.component.utf8)
            try bytes.write(to: url)
            XCTAssertEqual(chmod(url.path, sourceMode), 0)
        }
        XCTAssertEqual(chmod(parent.path, 0o700), 0)
        XCTAssertEqual(chmod(staging.path, 0o700), 0)
    }
    deinit { try? FileManager.default.removeItem(at: parent) }
    func reuser(hooks: ParakeetCompiledWeightReuser.TestHooks = .init()) throws -> ParakeetCompiledWeightReuser {
        return try ParakeetCompiledWeightReuser(store: ParakeetSourceStore(parent: parent, sourceDirectoryName: "source", entries: sourceEntries, identity: .production), sourceEntries: sourceEntries, compiledEntries: compiledEntries, hooks: hooks)
    }
}

private func zip<A, B>(_ lhs: [A], _ rhs: [B]) -> [(A, B)] { Array(Swift.zip(lhs, rhs)) }
