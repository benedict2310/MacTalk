import Darwin
import XCTest
@testable import MacTalk

final class ParakeetSourceAvailabilityTests: XCTestCase {
    func test_identityMarkedCanonicalSourceIsAvailableWithoutCompiledDirectory() throws {
        let fixture = try makeFixture(identity: testIdentity)
        defer { try? FileManager.default.removeItem(at: fixture.parent) }

        XCTAssertTrue(ParakeetSourceAvailability(store: fixture.store).isAvailable())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parent.appendingPathComponent(ParakeetModelDownloader.folderName).path))
    }

    func test_wrongIdentityAndSymlinkMarkerAreUnavailable() throws {
        let wrong = try makeFixture(identity: ParakeetSourceIdentity(
            formatVersion: testIdentity.formatVersion,
            repository: "wrong",
            revision: testIdentity.revision,
            fluidAudioRevision: testIdentity.fluidAudioRevision,
            canonicalProvenanceSHA256: testIdentity.canonicalProvenanceSHA256
        ))
        defer { try? FileManager.default.removeItem(at: wrong.parent) }
        XCTAssertFalse(ParakeetSourceAvailability(store: wrong.store).isAvailable())

        try FileManager.default.removeItem(at: wrong.source.appendingPathComponent(ParakeetSourceStore.identityMarkerName))
        try Data("outside".utf8).write(to: wrong.source.appendingPathComponent("outside"))
        XCTAssertEqual(symlink("outside", wrong.source.appendingPathComponent(ParakeetSourceStore.identityMarkerName).path), 0)
        XCTAssertFalse(ParakeetSourceAvailability(store: wrong.store).isAvailable())
    }

    private var testIdentity: ParakeetSourceIdentity {
        ParakeetSourceIdentity(formatVersion: 1, repository: "repo", revision: "revision", fluidAudioRevision: "fluid", canonicalProvenanceSHA256: String(repeating: "a", count: 64))
    }

    private func makeFixture(identity: ParakeetSourceIdentity) throws -> (parent: URL, source: URL, store: ParakeetSourceStore) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("source-availability-\(UUID().uuidString)")
        let store = ParakeetSourceStore(parent: parent, sourceDirectoryName: ParakeetSourceStore.canonicalDirectoryName, entries: [], identity: testIdentity)
        let source = parent.appendingPathComponent(store.sourceDirectoryName)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let marker = source.appendingPathComponent(ParakeetSourceStore.identityMarkerName)
        try JSONEncoder().encode(identity).write(to: marker)
        XCTAssertEqual(chmod(marker.path, 0o600), 0)
        return (parent, source, store)
    }
}
