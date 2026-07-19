import CryptoKit
import Darwin
import XCTest
@testable import MacTalk

final class VerifiedArtifactReaderTests: XCTestCase {
    private var rootURL: URL!
    private var rootFD: Int32 = -1

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacTalkVerifiedReader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(rootFD, 0)
    }

    override func tearDownWithError() throws {
        if rootFD >= 0 { _ = close(rootFD); rootFD = -1 }
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
    }

    func test_readsExactOwnedBytesAndLeavesRootUsable() throws {
        let payload = Data("verified fixture".utf8)
        let file = rootURL.appendingPathComponent("fixture.bin")
        try payload.write(to: file)

        let result = try VerifiedArtifactReader(rootFD: rootFD).read(entry(for: "fixture.bin", data: payload))

        XCTAssertEqual(result.data, payload)
        var info = stat()
        XCTAssertEqual(fstat(rootFD, &info), 0)
        let reopened = openat(rootFD, "fixture.bin", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(reopened, 0)
        _ = close(reopened)
    }

    func test_rejectsMalformedDigestAndInvalidSizeBeforeOpening() throws {
        let payload = Data("fixture".utf8)
        try payload.write(to: rootURL.appendingPathComponent("fixture.bin"))
        let malformed = GeneratedParakeetManifestEntry(path: "fixture.bin", size: Int64(payload.count), sha256: "ABC")
        XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: rootFD).read(malformed)) { error in
            XCTAssertEqual(error as? VerifiedArtifactReaderError, .invalidDigest)
        }

        for size in [Int64(0), Int64(-1), Int64(536_870_913), Int64.max] {
            let entry = GeneratedParakeetManifestEntry(path: "fixture.bin", size: size, sha256: digest(payload))
            XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: rootFD).read(entry)) { error in
                switch error as? VerifiedArtifactReaderError {
                case .invalidSize, .sizeTooLarge, .sizeOverflow:
                    break
                default:
                    XCTFail("unexpected error for size \(size): \(error)")
                }
            }
        }
    }

    func test_rejectsAbsoluteEmptyDotDotAndNulPaths() throws {
        let payload = Data("fixture".utf8)
        let paths = ["/fixture.bin", "", "fixture//bin", "./fixture.bin", "dir/../fixture.bin", "fixture\0.bin"]
        for path in paths {
            let entry = GeneratedParakeetManifestEntry(path: path, size: Int64(payload.count), sha256: digest(payload))
            XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: rootFD).read(entry)) { error in
                guard case .invalidPath = error as? VerifiedArtifactReaderError else {
                    return XCTFail("unexpected error for path \(path.debugDescription): \(error)")
                }
            }
        }
    }

    func test_rejectsRootThatIsNotDirectory() throws {
        let file = rootURL.appendingPathComponent("root-file")
        try Data("root".utf8).write(to: file)
        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = close(fd) }
        let entry = GeneratedParakeetManifestEntry(path: "fixture.bin", size: 1, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: fd).read(entry)) { error in
            XCTAssertEqual(error as? VerifiedArtifactReaderError, .rootNotDirectory)
        }
    }

    func test_rejectsSymlinkIntermediateAndFinal() throws {
        let payload = Data("fixture".utf8)
        let realDirectory = rootURL.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try payload.write(to: realDirectory.appendingPathComponent("fixture.bin"))
        try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("alias", isDirectory: true), withDestinationURL: realDirectory)
        try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("link.bin"), withDestinationURL: realDirectory.appendingPathComponent("fixture.bin"))

        for path in ["alias/fixture.bin", "link.bin"] {
            let entry = GeneratedParakeetManifestEntry(path: path, size: Int64(payload.count), sha256: digest(payload))
            XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: rootFD).read(entry)) { error in
                guard case .openFailed = error as? VerifiedArtifactReaderError else {
                    return XCTFail("unexpected error for symlink \(path): \(error)")
                }
            }
        }
    }

    func test_rejectsFinalDirectoryAndFIFOWithoutBlocking() throws {
        let directoryEntry = GeneratedParakeetManifestEntry(path: "nested", size: 1, sha256: String(repeating: "0", count: 64))
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("nested"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: rootFD).read(directoryEntry)) { error in
            XCTAssertEqual(error as? VerifiedArtifactReaderError, .notRegularFile)
        }

        let fifo = rootURL.appendingPathComponent("fixture.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let fifoEntry = GeneratedParakeetManifestEntry(path: "fixture.fifo", size: 1, sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: rootFD).read(fifoEntry)) { error in
            XCTAssertEqual(error as? VerifiedArtifactReaderError, .notRegularFile)
        }
    }

    func test_rejectsShortAndWrongDigest() throws {
        let payload = Data("short".utf8)
        try payload.write(to: rootURL.appendingPathComponent("fixture.bin"))
        let shortEntry = GeneratedParakeetManifestEntry(path: "fixture.bin", size: Int64(payload.count + 1), sha256: digest(payload))
        XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: rootFD).read(shortEntry)) { error in
            guard case .sizeMismatch = error as? VerifiedArtifactReaderError else {
                return XCTFail("unexpected short error: \(error)")
            }
        }
        let wrongEntry = GeneratedParakeetManifestEntry(path: "fixture.bin", size: Int64(payload.count), sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try VerifiedArtifactReader(rootFD: rootFD).read(wrongEntry)) { error in
            guard case .checksumMismatch = error as? VerifiedArtifactReaderError else {
                return XCTFail("unexpected digest error: \(error)")
            }
        }
    }

    func test_appendAfterStatIsRejectedByTrailingProbe() throws {
        let payload = Data("fixture".utf8)
        let file = rootURL.appendingPathComponent("fixture.bin")
        try payload.write(to: file)
        let entry = self.entry(for: "fixture.bin", data: payload)
        let reader = VerifiedArtifactReader(rootFD: rootFD, hooks: .init(afterStat: {
            if let handle = try? FileHandle(forWritingTo: file) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("x".utf8))
                try? handle.close()
            }
        }))
        XCTAssertThrowsError(try reader.read(entry)) { error in
            XCTAssertEqual(error as? VerifiedArtifactReaderError, .unexpectedTrailingByte)
        }
    }

    func test_truncateAtReadBarrierIsRejected() throws {
        let payload = Data(repeating: 7, count: 4096)
        let file = rootURL.appendingPathComponent("fixture.bin")
        try payload.write(to: file)
        let reader = VerifiedArtifactReader(rootFD: rootFD, hooks: .init(beforeRead: {
            try? FileHandle(forWritingTo: file).truncate(atOffset: 1)
        }))
        XCTAssertThrowsError(try reader.read(entry(for: "fixture.bin", data: payload))) { error in
            guard case .shortRead = error as? VerifiedArtifactReaderError else {
                return XCTFail("unexpected truncate error: \(error)")
            }
        }
    }

    func test_replacingPathAfterVerificationDoesNotChangeReturnedData() throws {
        let payload = Data("approved".utf8)
        let file = rootURL.appendingPathComponent("fixture.bin")
        try payload.write(to: file)
        let replacement = rootURL.appendingPathComponent("replacement.bin")
        let reader = VerifiedArtifactReader(rootFD: rootFD, hooks: .init(afterVerified: {
            try? Data("attacker".utf8).write(to: replacement)
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: replacement, to: file)
        }))
        let result = try reader.read(entry(for: "fixture.bin", data: payload))
        XCTAssertEqual(result.data, payload)
    }

    func test_repeatedReadsDoNotLeakDescriptors() throws {
        let payload = Data("fixture".utf8)
        let nested = rootURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try payload.write(to: nested.appendingPathComponent("fixture.bin"))
        let reader = VerifiedArtifactReader(rootFD: rootFD)
        let before = openFileDescriptorCount()

        for _ in 0..<100 {
            XCTAssertEqual(try reader.read(entry(for: "nested/fixture.bin", data: payload)).data, payload)
        }

        let wrongDigest = GeneratedParakeetManifestEntry(
            path: "nested/fixture.bin",
            size: Int64(payload.count),
            sha256: String(repeating: "0", count: 64)
        )
        for _ in 0..<100 {
            XCTAssertThrowsError(try reader.read(wrongDigest)) { error in
                guard case .checksumMismatch = error as? VerifiedArtifactReaderError else {
                    return XCTFail("unexpected wrong-digest error: \(error)")
                }
            }
        }

        for _ in 0..<100 {
            let missing = GeneratedParakeetManifestEntry(
                path: "nested/missing.bin",
                size: Int64(payload.count),
                sha256: digest(payload)
            )
            XCTAssertThrowsError(try reader.read(missing))
        }

        let nonRegularURL = nested.appendingPathComponent("directory", isDirectory: true)
        try FileManager.default.createDirectory(at: nonRegularURL, withIntermediateDirectories: true)
        let nonRegular = GeneratedParakeetManifestEntry(
            path: "nested/directory",
            size: Int64(payload.count),
            sha256: digest(payload)
        )
        for _ in 0..<100 {
            XCTAssertThrowsError(try reader.read(nonRegular)) { error in
                XCTAssertEqual(error as? VerifiedArtifactReaderError, .notRegularFile)
            }
        }

        let symlinkURL = nested.appendingPathComponent("symlink.bin")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: nested.appendingPathComponent("fixture.bin"))
        let symlink = GeneratedParakeetManifestEntry(
            path: "nested/symlink.bin",
            size: Int64(payload.count),
            sha256: digest(payload)
        )
        for _ in 0..<100 {
            XCTAssertThrowsError(try reader.read(symlink)) { error in
                guard case .openFailed = error as? VerifiedArtifactReaderError else {
                    return XCTFail("unexpected symlink error: \(error)")
                }
            }
        }

        XCTAssertEqual(openFileDescriptorCount(), before)
    }

    func test_fdCensusDetectsDuplicateThatRootFstatWouldMiss() throws {
        let before = openFileDescriptorCount()
        var duplicate = dup(rootFD)
        XCTAssertGreaterThanOrEqual(duplicate, 0)
        defer {
            if duplicate >= 0 { _ = close(duplicate) }
        }

        var info = stat()
        XCTAssertEqual(fstat(rootFD, &info), 0)
        XCTAssertEqual(openFileDescriptorCount(), before + 1)

        _ = close(duplicate)
        duplicate = -1
        XCTAssertEqual(openFileDescriptorCount(), before)
    }

    private func openFileDescriptorCount() -> Int {
        let maximum = getdtablesize()
        return (0..<maximum).reduce(into: 0) { count, descriptor in
            errno = 0
            if fcntl(Int32(descriptor), F_GETFD) >= 0 {
                count += 1
            } else {
                XCTAssertEqual(errno, EBADF, "unexpected fcntl error for descriptor \(descriptor)")
            }
        }
    }

    private func entry(for path: String, data: Data) -> GeneratedParakeetManifestEntry {
        GeneratedParakeetManifestEntry(path: path, size: Int64(data.count), sha256: digest(data))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
