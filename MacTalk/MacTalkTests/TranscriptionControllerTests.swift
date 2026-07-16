//
//  TranscriptionControllerTests.swift
//  MacTalkTests
//
//  Tests for the deterministic transcript-cleaning pipeline. Controller lifecycle
//  coverage requires an injectable fake ASR engine and capture boundaries.
//

import XCTest
@testable import MacTalk

final class TranscriptionControllerTests: XCTestCase {
    func test_whisperUsesIncrementalChunkProcessing() {
        XCTAssertTrue(ASRProvider.whisper.usesIncrementalChunkProcessing)
    }

    func test_parakeetUsesFinalOnlyProcessingToAvoidInferenceOverlap() {
        XCTAssertFalse(ASRProvider.parakeet.usesIncrementalChunkProcessing)
    }

    func test_stripsLeadingPunctuationArtifacts() {
        XCTAssertEqual(TranscriptCleaner.clean(". this is a test"), "This is a test.")
        XCTAssertEqual(TranscriptCleaner.clean("... okay let's try this"), "Okay let's try this.")
        XCTAssertEqual(TranscriptCleaner.clean(", uh this started with a comma"), "This started with a comma.")
    }

    func test_normalizesPunctuationSpacing() {
        XCTAssertEqual(TranscriptCleaner.clean("hello , world !"), "Hello, world!")
        XCTAssertEqual(TranscriptCleaner.clean("is this working ?"), "Is this working?")
    }

    func test_preservesValidTerminalPunctuation() {
        XCTAssertEqual(TranscriptCleaner.clean("already done!"), "Already done!")
        XCTAssertEqual(TranscriptCleaner.clean("is this done?"), "Is this done?")
    }

    func test_removesStandaloneFillerWords() {
        XCTAssertEqual(
            TranscriptCleaner.clean("Okay, let's give this um a quick test. Uh and I'm specifically putting a lot of um thinking into this."),
            "Okay, let's give this a quick test. And I'm specifically putting a lot of thinking into this."
        )
        XCTAssertEqual(
            TranscriptCleaner.clean("Um, this starts with filler. Hmm, this also has hesitation."),
            "This starts with filler. This also has hesitation."
        )
    }

    func test_doesNotRemoveFillerSubstringsInsideWords() {
        XCTAssertEqual(
            TranscriptCleaner.clean("The summary number, umbrella, and humming are important."),
            "The summary number, umbrella, and humming are important."
        )
    }

    func test_capitalizesSentenceStartsAfterFillerRemoval() {
        XCTAssertEqual(
            TranscriptCleaner.clean("this is first. uh this should be capitalized. um this too"),
            "This is first. This should be capitalized. This too."
        )
    }

    func test_emptyAndWhitespaceOnlyInputProduceEmptyOutput() {
        XCTAssertEqual(TranscriptCleaner.clean(""), "")
        XCTAssertEqual(TranscriptCleaner.clean("   \n\t"), "")
    }
}
