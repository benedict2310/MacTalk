//
//  NativeWhisperEngineTests.swift
//  MacTalkTests
//
//  Deterministic validation of model-path rejection. Successful inference belongs
//  in a separately provisioned real-model integration suite.
//

import XCTest
@preconcurrency import AVFoundation
@testable import MacTalk

final class NativeWhisperEngineTests: XCTestCase {
    func test_requestContextPreservesSessionVocabularySnapshot() {
        let snapshotID = UUID()
        let hint = ASRVocabularyHint(
            id: UUID(),
            writtenForm: "NVIDIA",
            spokenForm: "en-vid-ee-uh",
            priority: .high
        )

        let context = ASRRequestContext(
            language: "en",
            vocabularyHints: [hint],
            vocabularySnapshotID: snapshotID
        )

        XCTAssertEqual(context.language, "en")
        XCTAssertEqual(context.vocabularyHints, [hint])
        XCTAssertEqual(context.vocabularySnapshotID, snapshotID)
    }

    func test_emptyRequestContextHasNoLanguageOrVocabularyHints() {
        let context = ASRRequestContext()

        XCTAssertNil(context.language)
        XCTAssertTrue(context.vocabularyHints.isEmpty)
        XCTAssertNil(context.vocabularySnapshotID)
    }

    func test_whisperInitialPromptPreservesRankedUnicodeWrittenForms() {
        let context = ASRRequestContext(
            language: "en",
            vocabularyHints: [
                ASRVocabularyHint(id: UUID(), writtenForm: " Žižek ", spokenForm: nil, priority: .high),
                ASRVocabularyHint(id: UUID(), writtenForm: "NVIDIA", spokenForm: nil, priority: .normal),
                ASRVocabularyHint(id: UUID(), writtenForm: "Žižek", spokenForm: nil, priority: .low),
                ASRVocabularyHint(id: UUID(), writtenForm: "   ", spokenForm: nil, priority: .low),
            ]
        )

        XCTAssertEqual(NativeWhisperEngine.initialPrompt(for: context), "Žižek, NVIDIA")
    }

    func test_whisperInitialPromptIsNilWithoutUsableHints() {
        XCTAssertNil(NativeWhisperEngine.initialPrompt(for: ASRRequestContext()))
    }

    func test_whisperInitialPromptEnforcesFinalUTF8BudgetIncludingSeparators() throws {
        let hints = (0..<100).map { index in
            ASRVocabularyHint(
                id: UUID(),
                writtenForm: "Élodie-\(index)-\(String(repeating: "界", count: 8))",
                spokenForm: nil,
                priority: .normal
            )
        }

        let prompt = try XCTUnwrap(NativeWhisperEngine.initialPrompt(for: ASRRequestContext(vocabularyHints: hints)))

        XCTAssertLessThanOrEqual(prompt.utf8.count, NativeWhisperEngine.maximumInitialPromptUTF8Bytes)
        XCTAssertFalse(prompt.hasSuffix(", "))
    }

    func test_whisperAdvertisesInitialPromptHinting() {
        XCTAssertEqual(ASRProvider.whisper.vocabularyHintingCapability, .initialPrompt)
    }

    func test_requestContextOverloadDynamicallyDispatchesThroughEngineExistential() async throws {
        let engine: any ASREngine = RequestContextProbeEngine()
        let context = ASRRequestContext(
            language: "de",
            vocabularyHints: [
                ASRVocabularyHint(id: UUID(), writtenForm: "MacTalk", spokenForm: nil, priority: .high)
            ]
        )

        let result = try await engine.process(samples: [0.1], context: context)

        XCTAssertEqual(result?.text, "context:de:MacTalk")
    }

    func test_missingModelIsRejected() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).bin")

        XCTAssertNil(NativeWhisperEngine(modelSpec: fixtureSpec(), modelURL: url))
    }

    func test_directoryIsRejectedAsModel() {
        XCTAssertNil(NativeWhisperEngine(modelSpec: fixtureSpec(), modelURL: FileManager.default.temporaryDirectory))
    }

    func test_corruptModelFileIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).bin")
        try Data("not a whisper model".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(NativeWhisperEngine(modelSpec: fixtureSpec(), modelURL: url))
    }

    func test_nativeBoundaryRejectsSymlinkModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("symlink-\(UUID().uuidString)")
        let target = directory.appendingPathComponent("target.bin")
        let link = directory.appendingPathComponent("model.bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0, count: 1).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ModelIntegrityVerifier.openValidated(source: link, spec: fixtureSpec()))
    }

    private func fixtureSpec() -> ModelSpec {
        ModelSpec(id: "fixture", displayName: "Fixture", filename: "fixture.bin",
                  sha256: String(repeating: "a", count: 64), sizeBytes: 1,
                  urls: [URL(string: "https://example.invalid/fixture")!], license: nil, languages: nil)
    }
}

private final class RequestContextProbeEngine: ASREngine, @unchecked Sendable {
    let provider: ASRProvider = .whisper

    func prepare() async throws {}
    func reset() async {}

    func process(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRPartial? {
        ASRPartial(text: "legacy", words: [])
    }

    func finalize(_ buffer: AVAudioPCMBuffer, language: String?) async throws -> ASRFinalSegment? {
        nil
    }

    func process(_ buffer: AVAudioPCMBuffer, context: ASRRequestContext) async throws -> ASRPartial? {
        let terms = context.vocabularyHints.map(\.writtenForm).joined(separator: ",")
        return ASRPartial(text: "context:\(context.language ?? "auto"):\(terms)", words: [])
    }
}
