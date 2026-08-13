import Foundation
import Darwin
import XCTest
@testable import MacTalk

final class PipelineObservabilityTests: XCTestCase {
    func testSessionDimensionsAndPersistedSummaryAreEmittedOnceWithoutSensitiveFields() {
        let sink = RecordingPipelineObservabilitySink()
        let emitter = PipelineObservabilityEmitter(sink: sink)
        let context = PipelineSessionContext(
            id: UUID(), provider: .whisper, modelID: "whisper-base-q5_1",
            captureMode: .micOnly, language: "en", batteryMode: false, startedAt: Date()
        )
        let recorder = PipelineSessionRecorder(context: context, nowNanoseconds: { 0 })
        let report = recorder.finish(outcome: .completed, capture: .zero, composition: .init())
        let signpostID = PipelineSignposts.sessionID()

        emitter.beginSession(signpostID, context: context)
        emitter.endSession(signpostID, context: context)
        emitter.persistedSummary(report)

        XCTAssertEqual(sink.events, [.sessionBegin(context), .sessionEnd(context), .persistedSummary(report)])
        let encoded = String(decoding: try! JSONEncoder().encode(context), as: UTF8.self)
        XCTAssertFalse(encoded.contains("transcript"))
        XCTAssertFalse(encoded.contains("target"))
        XCTAssertFalse(encoded.contains("rawError"))
    }

    func testSchemaOneLegacyLineDefaultsApplicationConversionAndSurvivesNextWrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
        let legacy = makeReport(index: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        var audio = try XCTUnwrap(object["audio"] as? [String: Any])
        audio.removeValue(forKey: "applicationConversionNanoseconds")
        object["audio"] = audio
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try JSONDecoder().decode(PipelineSessionReport.self, from: legacyData)
        try legacyData.write(to: url)
        chmod(url.path, 0o600)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([10]))
        try handle.close()

        let store = PipelineMetricsStore(fileURL: url)
        await store.record(makeReport(index: 2))
        let reports = await store.reports(limit: 10)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first?.context.modelID, "model-1")
        XCTAssertEqual(reports.first?.audio.applicationConversionNanoseconds, 0)
    }

    func testRecorderCalculatesDistinctCaptureAndCompositionLatencies() {
        let clock = TestPipelineClock()
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "base", captureMode: .micOnly, language: "en", batteryMode: false, startedAt: Date()), nowNanoseconds: { clock.now })
        clock.advance(ms: 100)
        recorder.recordMicrophoneInput(inputSamples: 4_800, convertedSamples: 1_600, conversionNanoseconds: 2_000_000)
        clock.advance(ms: 20)
        recorder.recordComposedOutput(samples: 1_600)
        let id = UUID()
        recorder.recordInferenceQueued(id: id, kind: .incremental, audioSamples: 16_000)
        clock.advance(ms: 25); recorder.recordInferenceStarted(id: id)
        clock.advance(ms: 200); recorder.recordInferenceCompleted(id: id, succeeded: true)
        clock.advance(ms: 25); recorder.recordPartialPresented(); recorder.recordStopRequested()
        clock.advance(ms: 300); recorder.recordFinalPresented()
        clock.advance(ms: 5); recorder.recordOutputHandoff(clipboardWritten: true, insertOutcome: .notAttempted)
        let report = recorder.finish(outcome: .completed, capture: .zero, composition: .init())
        XCTAssertEqual(report.latency.firstAcceptedCaptureMs!, 100, accuracy: 0.001)
        XCTAssertEqual(report.latency.firstComposedAudioMs!, 120, accuracy: 0.001)
        XCTAssertEqual(report.latency.firstPartialFromStartMs!, 370, accuracy: 0.001)
        XCTAssertEqual(report.latency.firstPartialFromComposedAudioMs!, 250, accuracy: 0.001)
        XCTAssertEqual(report.latency.stopToFinalMs!, 300, accuracy: 0.001)
        XCTAssertEqual(report.latency.finalOutputHandoffMs!, 5, accuracy: 0.001)
        XCTAssertEqual(report.incrementalInference.realTimeFactor!, 0.2, accuracy: 0.001)
        XCTAssertEqual(report.queue.maximumDelayMs!, 25, accuracy: 0.001)
    }

    func testHistoryPersistenceOutcomeIsRecordedWithoutTranscriptOrRawError() throws {
        let recorder = PipelineSessionRecorder(
            context: .init(id: UUID(), provider: .whisper, modelID: "base", captureMode: .micOnly, language: "en", batteryMode: false, startedAt: Date()),
            nowNanoseconds: { 0 }
        )
        recorder.recordHistoryPersistence(.inserted)

        let report = recorder.finish(outcome: .completed, capture: .zero, composition: .init())

        XCTAssertEqual(report.historyPersistence, .inserted)
        XCTAssertEqual(report.schemaVersion, 2)
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(json.contains("transcript"))
        XCTAssertFalse(json.contains("rawError"))
    }

    func testFinishIsIdempotentAndClockBackwardsSaturates() {
        let clock = TestPipelineClock()
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .parakeet, modelID: "parakeet", captureMode: .micPlusAppAudio, language: nil, batteryMode: true, startedAt: Date()), nowNanoseconds: { clock.now })
        clock.advance(ms: 5); recorder.recordMicrophoneInput(inputSamples: 1, convertedSamples: 1, conversionNanoseconds: 1)
        clock.set(1); recorder.recordPartialPresented()
        let first = recorder.finish(outcome: .cancelled, capture: .zero, composition: .init())
        let second = recorder.finish(outcome: .completed, capture: .zero, composition: .init(lateFramesDropped: 4))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.latency.firstPartialFromStartMs!, 5, accuracy: 0.001)
        XCTAssertEqual(first.outcome, .cancelled)
    }

    func testApplicationFirstAcceptedCaptureWinsWithoutLossOrZeroCallback() {
        let clock = TestPipelineClock()
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .parakeet, modelID: "parakeet", captureMode: .micPlusAppAudio, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { clock.now })

        XCTAssertFalse(recorder.recordApplicationInput(callbacks: 0, samples: 0))
        recorder.recordApplicationLoss()
        clock.advance(ms: 10)
        XCTAssertTrue(recorder.recordApplicationInput(callbacks: 1, samples: 32))
        clock.advance(ms: 10)
        XCTAssertFalse(recorder.recordMicrophoneInput(inputSamples: 32, convertedSamples: 32, conversionNanoseconds: 1))

        let report = recorder.finish(outcome: .completed, capture: .zero, composition: .init())
        XCTAssertEqual(report.latency.firstAcceptedCaptureMs!, 10, accuracy: 0.001)
        XCTAssertEqual(report.capture.applicationCallbacks, 1)
        XCTAssertEqual(report.capture.applicationLossEvents, 1)
        XCTAssertEqual(report.audio.applicationInputSamples, 32)
    }

    func testAllCountersAndPrivacySchema() throws {
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { 0 })
        recorder.recordMicrophoneInput(inputSamples: 10, convertedSamples: 8, conversionNanoseconds: 3, conversionFailed: true)
        recorder.recordApplicationInput(callbacks: 2, samples: 20, lossEvents: 1)
        recorder.recordVADSkip(); recorder.recordTrimmedAudio(samples: 7); recorder.recordFallback(); recorder.recordInferenceQueueDepth(3)
        let report = recorder.finish(outcome: .inferenceFailed, capture: .init(microphoneDroppedBuffers: 4, microphoneCallbacks: 5, applicationCallbacks: 6, applicationLossEvents: 7), composition: .init(nonFiniteSamplesReplaced: 2))
        XCTAssertEqual(report.audio.conversionFailures, 1); XCTAssertEqual(report.audio.vadSkips, 1); XCTAssertEqual(report.audio.trimmedSamples, 7); XCTAssertEqual(report.audio.fallbackCount, 1)
        XCTAssertEqual(report.queue.maximumPending, 3); XCTAssertEqual(report.capture.microphoneDroppedBuffers, 4)
        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("transcript")); XCTAssertFalse(json.contains("target")); XCTAssertFalse(json.contains("rawError"))
    }

    func testOutputCmdVIsScheduledNotCompleted() {
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { 0 })
        recorder.recordOutputHandoff(clipboardWritten: false, insertOutcome: .cmdVScheduledUnverified)
        let output = recorder.finish(outcome: .completed, capture: .zero, composition: .init()).output
        XCTAssertEqual(output.insertOutcome, .cmdVScheduledUnverified)
        XCTAssertFalse(output.insertCompleted)
    }

    func testRejectedOutputHandoffIsTypedAndNotCompleted() {
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { 0 })
        recorder.recordFinalPresented()
        recorder.recordOutputHandoff(clipboardWritten: false, insertOutcome: .rejected)
        let report = recorder.finish(outcome: .completed, capture: .zero, composition: .init())
        XCTAssertEqual(report.output.insertOutcome.rawValue, "rejected")
        XCTAssertFalse(report.output.insertCompleted)
        XCTAssertNotNil(report.latency.finalOutputHandoffMs)
    }

    func testFinishMergesExternalDropSnapshotButRetainsRecorderCallbackAndLossCounters() {
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { 0 })
        recorder.recordMicrophoneInput(inputSamples: 1, convertedSamples: 1, conversionNanoseconds: 1)
        recorder.recordApplicationInput(callbacks: 2, lossEvents: 3)
        recorder.recordCaptureDrop(count: 4)
        let external = CaptureHealthMetrics(microphoneDroppedBuffers: 9, microphoneCallbacks: 99, applicationCallbacks: 98, applicationLossEvents: 97)
        let capture = recorder.finish(outcome: .completed, capture: external, composition: .init()).capture
        XCTAssertEqual(capture.microphoneDroppedBuffers, 13)
        XCTAssertEqual(capture.microphoneCallbacks, 1)
        XCTAssertEqual(capture.applicationCallbacks, 2)
        XCTAssertEqual(capture.applicationLossEvents, 3)
    }

    func testUpdatesAfterFinishDoNotChangeCachedReport() {
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { 0 })
        let first = recorder.finish(outcome: .completed, capture: .zero, composition: .init())
        recorder.recordVADSkip(); recorder.recordCaptureDrop(count: 4)
        let second = recorder.finish(outcome: .completed, capture: .zero, composition: .init(lateFramesDropped: 3))
        XCTAssertEqual(first, second)
    }

    func testInferenceFailureAndFinalRTFAreRecorded() {
        let clock = TestPipelineClock()
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .parakeet, modelID: "parakeet", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { clock.now })
        let successfulID = UUID()
        recorder.recordInferenceQueued(id: successfulID, kind: .final, audioSamples: 16_000)
        recorder.recordInferenceStarted(id: successfulID)
        clock.advance(ms: 1_000)
        recorder.recordInferenceCompleted(id: successfulID, succeeded: true)
        let failedID = UUID()
        recorder.recordInferenceQueued(id: failedID, kind: .final, audioSamples: 8_000)
        recorder.recordInferenceFailed(id: failedID)
        let report = recorder.finish(outcome: .inferenceFailed, capture: .zero, composition: .init())
        XCTAssertEqual(report.queue.failedCount, 1)
        XCTAssertEqual(report.finalInference.failedCount, 0)
        XCTAssertEqual(report.finalInference.completedCount, 1)
        XCTAssertEqual(report.finalInference.audioSamples, 16_000)
        XCTAssertEqual(report.finalInference.realTimeFactor!, 1.0, accuracy: 0.001)
    }

    func testFormatterIsolatesStatisticsByProviderModelAndModeDimension() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PipelineMetricsStore(fileURL: directory.appendingPathComponent("pipeline-metrics.jsonl"))
        let reportA1 = makeReport(index: 1, provider: .whisper, modelID: "whisper-base", mode: .micOnly, outcome: .completed, firstPartialMs: 10, stopToFinalMs: 100, incrementalRTF: 1, finalRTF: 4, droppedBuffers: 2, conversionFailures: 1, compositionAnomalies: 3, vadSkips: 4, trimmedSamples: 5, fallbackCount: 6)
        let reportA2 = makeReport(index: 2, provider: .whisper, modelID: "whisper-base", mode: .micOnly, outcome: .cancelled, firstPartialMs: 20, stopToFinalMs: 200, incrementalRTF: 2, finalRTF: 5, droppedBuffers: 2, conversionFailures: 1, compositionAnomalies: 3, vadSkips: 4, trimmedSamples: 5, fallbackCount: 6)
        let reportA3 = makeReport(index: 3, provider: .whisper, modelID: "whisper-base", mode: .micOnly, outcome: .completed, firstPartialMs: 30, stopToFinalMs: 300, incrementalRTF: 3, finalRTF: 6, droppedBuffers: 2, conversionFailures: 1, compositionAnomalies: 3, vadSkips: 4, trimmedSamples: 5, fallbackCount: 6)
        let reportB1 = makeReport(index: 4, provider: .parakeet, modelID: "parakeet", mode: .micPlusAppAudio, outcome: .inferenceFailed, firstPartialMs: 400, stopToFinalMs: 4_000, incrementalRTF: 10, finalRTF: 13, droppedBuffers: 15, conversionFailures: 6, compositionAnomalies: 7, vadSkips: 8, trimmedSamples: 9, fallbackCount: 10)
        let reportB2 = makeReport(index: 5, provider: .parakeet, modelID: "parakeet", mode: .micPlusAppAudio, outcome: .cancelled, firstPartialMs: 500, stopToFinalMs: 5_000, incrementalRTF: 11, finalRTF: 14, droppedBuffers: 15, conversionFailures: 6, compositionAnomalies: 7, vadSkips: 8, trimmedSamples: 9, fallbackCount: 10)
        let groupA = [reportA1, reportA2, reportA3]
        let groupB = [reportB1, reportB2]
        for report in groupA + groupB { await store.record(report) }

        let formatted = await store.formattedReport(limit: 10)
        let sectionA = try! section(named: "whisper/whisper-base/micOnly", in: formatted)
        let sectionB = try! section(named: "parakeet/parakeet/micPlusAppAudio", in: formatted)

        XCTAssertTrue(sectionA.contains("whisper/whisper-base/micOnly: 3 observations"))
        XCTAssertTrue(sectionA.contains("Outcomes: cancelled=1, completed=2"))
        XCTAssertTrue(sectionA.contains("First partial ms p50/p95: 20.000/30.000"))
        XCTAssertTrue(sectionA.contains("Stop to final ms p50/p95: 200.000/300.000"))
        XCTAssertTrue(sectionA.contains("Incremental RTF p50/p95: 2.000/3.000"))
        XCTAssertTrue(sectionA.contains("Final RTF p50/p95: 5.000/6.000"))
        XCTAssertTrue(sectionA.contains("Capture drops: 6; conversion failures: 3; composition anomalies: 9; VAD skips: 12; trimmed samples: 15; fallback: 18"))
        XCTAssertFalse(sectionA.contains("inferenceFailed")); XCTAssertFalse(sectionA.contains("100.000/500.000")); XCTAssertFalse(sectionA.contains("30; conversion failures: 12"))

        XCTAssertTrue(sectionB.contains("parakeet/parakeet/micPlusAppAudio: 2 observations"))
        XCTAssertTrue(sectionB.contains("Outcomes: cancelled=1, inferenceFailed=1"))
        XCTAssertTrue(sectionB.contains("First partial ms p50/p95: 400.000/500.000"))
        XCTAssertTrue(sectionB.contains("Stop to final ms p50/p95: 4000.000/5000.000"))
        XCTAssertTrue(sectionB.contains("Incremental RTF p50/p95: 10.000/11.000"))
        XCTAssertTrue(sectionB.contains("Final RTF p50/p95: 13.000/14.000"))
        XCTAssertTrue(sectionB.contains("Capture drops: 30; conversion failures: 12; composition anomalies: 14; VAD skips: 16; trimmed samples: 18; fallback: 20"))
        XCTAssertFalse(sectionB.contains("completed=2")); XCTAssertFalse(sectionB.contains("20.000/30.000")); XCTAssertFalse(sectionB.contains("6; conversion failures: 3"))
    }

    private func section(named name: String, in formatted: String) throws -> String {
        let marker = "Dimension \(name):"
        guard let start = formatted.range(of: marker) else { throw NSError(domain: "PipelineObservabilityTests", code: 1) }
        let end = formatted.range(of: "\nDimension ", range: start.upperBound..<formatted.endIndex)?.lowerBound ?? formatted.endIndex
        return String(formatted[start.lowerBound..<end])
    }

    func testRecorderAndStoreSchemaKeepProviderModelAndModeDimensionsSeparate() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
        let store = PipelineMetricsStore(fileURL: url)
        await store.record(makeReport(index: 1, provider: .whisper, modelID: "whisper-base", mode: .micOnly))
        await store.record(makeReport(index: 2, provider: .parakeet, modelID: "parakeet", mode: .micPlusAppAudio))
        let reports = await store.reports(limit: 10)
        XCTAssertEqual(reports.map(\.context.provider), [.whisper, .parakeet])
        let formatted = await store.formattedReport(limit: 10)
        XCTAssertTrue(formatted.contains("Dimension whisper/whisper-base/micOnly"))
        XCTAssertTrue(formatted.contains("Dimension parakeet/parakeet/micPlusAppAudio"))
    }

    func testStoreRejectsSameUserFIFOWithoutBlocking() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        defer { try? FileManager.default.removeItem(at: directory) }

        let finished = expectation(description: "FIFO metrics operation returns")
        let report = makeReport(index: 1)
        Task {
            await PipelineMetricsStore(fileURL: url).record(report)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1.0)
    }

    func testStoreDiscardsSemanticallyInvalidNegativeCompositionReport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
        let invalid = makeReport(index: 1, compositionMetrics: AudioCompositionMetrics(lateFramesDropped: -1))
        try JSONEncoder().encode(invalid).write(to: url)
        chmod(url.path, 0o600)

        let store = PipelineMetricsStore(fileURL: url)
        let formatted = await store.formattedReport(limit: 10)
        XCTAssertTrue(formatted.contains("No completed sessions"))
        let reports = await store.reports(limit: 10)
        XCTAssertEqual(reports, [])
    }

    func testFormatterSaturatesUInt64AndCompositionTotalsAcrossRecords() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PipelineMetricsStore(fileURL: directory.appendingPathComponent("pipeline-metrics.jsonl"))
        let maximum = UInt64.max
        let composition = AudioCompositionMetrics(lateFramesDropped: Int.max, bufferedOverlapFramesDropped: Int.max, preAnchorFramesDropped: Int.max, invalidMicrophoneTimestamps: Int.max, invalidApplicationTimestamps: Int.max, discontinuitiesElided: Int.max, nonFiniteSamplesReplaced: Int.max, clippedSamples: Int.max)
        await store.record(makeReport(index: 1, droppedBuffers: maximum, conversionFailures: maximum, compositionMetrics: composition, vadSkips: maximum, trimmedSamples: maximum, fallbackCount: maximum))
        await store.record(makeReport(index: 2, droppedBuffers: maximum, conversionFailures: maximum, compositionMetrics: composition, vadSkips: maximum, trimmedSamples: maximum, fallbackCount: maximum))

        let formatted = await store.formattedReport(limit: 10)
        XCTAssertTrue(formatted.contains("Capture drops: \(maximum); conversion failures: \(maximum); composition anomalies: \(maximum); VAD skips: \(maximum); trimmed samples: \(maximum); fallback: \(maximum)"))
    }

    func testFormatterUsesPOSIXDecimalSeparator() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PipelineMetricsStore(fileURL: directory.appendingPathComponent("pipeline-metrics.jsonl"))
        await store.record(makeReport(index: 1, firstPartialMs: 1.25, stopToFinalMs: 2.5, incrementalRTF: 3.75, finalRTF: 4.125))

        let formatted = await store.formattedReport(limit: 10)
        XCTAssertTrue(formatted.contains("First partial ms p50/p95: 1.250/1.250"))
        XCTAssertFalse(formatted.contains("1,250"))
    }

    func testStoreRejectsSymlinkedDirectoryAndFileWithoutTouchingTargets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realDirectory = root.appendingPathComponent("real")
        let symlinkDirectory = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        chmod(realDirectory.path, 0o700)
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: realDirectory)
        let linkedStore = PipelineMetricsStore(fileURL: symlinkDirectory.appendingPathComponent("pipeline-metrics.jsonl"))
        await linkedStore.record(makeReport(index: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: realDirectory.appendingPathComponent("pipeline-metrics.jsonl").path))

        let safeDirectory = root.appendingPathComponent("safe")
        try FileManager.default.createDirectory(at: safeDirectory, withIntermediateDirectories: true)
        chmod(safeDirectory.path, 0o700)
        let target = safeDirectory.appendingPathComponent("target.jsonl")
        let fileLink = safeDirectory.appendingPathComponent("pipeline-metrics.jsonl")
        try Data("do-not-replace".utf8).write(to: target)
        chmod(target.path, 0o600)
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: target)
        let linkedFileStore = PipelineMetricsStore(fileURL: fileLink)
        await linkedFileStore.record(makeReport(index: 2))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "do-not-replace")
    }

    func testStoreRejectsInsecureExistingDirectoryWithoutChangingPermissions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o755)
        let store = PipelineMetricsStore(fileURL: directory.appendingPathComponent("pipeline-metrics.jsonl"))
        await store.record(makeReport(index: 1))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pipeline-metrics.jsonl").path))
    }

    func testStoreRecoversFromOversizedFileUsingBoundedTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
        var data = Data(repeating: 65, count: 100_000)
        data.append(10)
        try data.write(to: url)
        chmod(url.path, 0o600)
        let store = PipelineMetricsStore(fileURL: url, maximumFileBytes: 2_048, maximumLineBytes: 2_048)
        await store.record(makeReport(index: 9))
        let reports = await store.reports(limit: 10)
        XCTAssertEqual(reports.map { $0.context.modelID }, ["model-9"])
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 2_048)
    }

    func testFormatterUsesNearestRankAndExcludesMissingValues() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PipelineMetricsStore(fileURL: directory.appendingPathComponent("pipeline-metrics.jsonl"))
        await store.record(makeReport(index: 1, modelID: "same-dimension", firstPartialMs: 1))
        await store.record(makeReport(index: 2, modelID: "same-dimension", firstPartialMs: 2))
        await store.record(makeReport(index: 3, modelID: "same-dimension", firstPartialMs: 100))
        await store.record(makeReport(index: 4, modelID: "same-dimension", firstPartialMs: nil))
        let formatted = await store.formattedReport(limit: 10)
        XCTAssertTrue(formatted.contains("First partial ms p50/p95: 2.000/100.000"))
    }

    func testEmptyStoreHasUsefulReport() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pipeline-metrics.jsonl")
        let formatted = await PipelineMetricsStore(fileURL: url).formattedReport(limit: 10)
        XCTAssertTrue(formatted.contains("No completed sessions"))
        XCTAssertTrue(formatted.contains("Schema version: 2"))
    }

    func testRecorderHotPathDoesNotPersistUntilStoreRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
        let store = PipelineMetricsStore(fileURL: url)
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { 0 })
        recorder.recordVADSkip(); recorder.recordCaptureDrop(); recorder.recordPartialPresented()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await store.record(recorder.finish(outcome: .completed, capture: .zero, composition: .init()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testContentionFinishingWhileCaptureUpdatesProgress() {
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { DispatchTime.now().uptimeNanoseconds })
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<20_000 { recorder.recordVADSkip() }
            group.leave()
        }
        let report = recorder.finish(outcome: .completed, capture: .zero, composition: .init())
        group.wait()
        XCTAssertLessThanOrEqual(report.audio.vadSkips, 20_000)
        XCTAssertEqual(recorder.finish(outcome: .cancelled, capture: .zero, composition: .init()), report)
    }

    func testResourceCheckpointsTrackStartEndAndMaximum() {
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { 0 })
        recorder.recordResourceCheckpoint(residentMemoryBytes: 10)
        recorder.recordResourceCheckpoint(residentMemoryBytes: 30)
        recorder.recordResourceCheckpoint(residentMemoryBytes: 20)
        let resources = recorder.finish(outcome: .completed, capture: .zero, composition: .init()).resources
        XCTAssertEqual(resources.startResidentMemoryBytes, 10)
        XCTAssertEqual(resources.endResidentMemoryBytes, 20)
        XCTAssertEqual(resources.maxObservedResidentMemoryAtCheckpoints, 30)
    }

    func testStoreCapsRetentionAtOneHundredReports() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PipelineMetricsStore(fileURL: directory.appendingPathComponent("pipeline-metrics.jsonl"), retentionLimit: 200)
        for index in 0..<105 { await store.record(makeReport(index: index)) }
        let reports = await store.reports(limit: 200)
        XCTAssertEqual(reports.count, 100)
        XCTAssertEqual(reports.first?.context.modelID, "model-5")
    }

    func testStoreIsBoundedAndFormatsMissingDistributions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
        let store = PipelineMetricsStore(fileURL: url, retentionLimit: 3, maximumFileBytes: 512 * 1024, maximumLineBytes: 8 * 1024)
        for index in 0..<5 { await store.record(makeReport(index: index)) }
        let reports = await store.reports(limit: 20)
        XCTAssertEqual(reports.count, 3)
        XCTAssertEqual(reports.first?.context.modelID, "model-2")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber, 0o600)
        let text = await store.formattedReport(limit: 20)
        XCTAssertTrue(text.contains("Dimension whisper/model-2/micOnly"))
        XCTAssertTrue(text.contains("n/a"))
    }

    func testStoreSkipsMalformedAndOversizedLines() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
        let url = directory.appendingPathComponent("pipeline-metrics.jsonl")
        let valid = try JSONEncoder().encode(makeReport(index: 1))
        var data = Data("not-json\n".utf8); data.append(valid); data.append(10); data.append(Data(repeating: 65, count: 9_000)); data.append(10)
        try data.write(to: url); chmod(url.path, 0o600)
        let store = PipelineMetricsStore(fileURL: url)
        await store.record(makeReport(index: 2))
        let reports = await store.reports(limit: 10)
        XCTAssertEqual(reports.map { $0.context.modelID }, ["model-1", "model-2"])
    }

    func testRecorderContentionDoesNotLosePrimitiveUpdates() {
        let recorder = PipelineSessionRecorder(context: .init(id: UUID(), provider: .whisper, modelID: "m", captureMode: .micOnly, language: nil, batteryMode: false, startedAt: Date()), nowNanoseconds: { DispatchTime.now().uptimeNanoseconds })
        let group = DispatchGroup()
        for _ in 0..<8 { group.enter(); DispatchQueue.global().async { for _ in 0..<2_000 { recorder.recordVADSkip() }; group.leave() } }
        group.wait()
        let report = recorder.finish(outcome: .completed, capture: .zero, composition: .init())
        XCTAssertEqual(report.audio.vadSkips, 16_000)
    }

    private func makeReport(index: Int, provider: ASRProvider = .whisper, modelID: String? = nil, mode: SettingsCaptureMode = .micOnly, outcome: PipelineSessionOutcome? = nil, firstPartialMs: Double? = nil, stopToFinalMs: Double? = nil, incrementalRTF: Double? = nil, finalRTF: Double? = nil, droppedBuffers: UInt64 = 0, conversionFailures: UInt64 = 0, compositionAnomalies: UInt64 = 0, compositionMetrics: AudioCompositionMetrics? = nil, vadSkips: UInt64 = 0, trimmedSamples: UInt64 = 0, fallbackCount: UInt64 = 0) -> PipelineSessionReport {
        let context = PipelineSessionContext(id: UUID(), provider: provider, modelID: modelID ?? "model-\(index)", captureMode: mode, language: nil, batteryMode: false, startedAt: Date(timeIntervalSince1970: Double(index)))
        var latency = PipelineLatencyMetrics()
        latency.firstPartialFromStartMs = firstPartialMs
        latency.stopToFinalMs = stopToFinalMs
        var audio = PipelineAudioMetrics()
        audio.conversionFailures = conversionFailures
        audio.vadSkips = vadSkips
        audio.trimmedSamples = trimmedSamples
        audio.fallbackCount = fallbackCount
        var capture = CaptureHealthMetrics.zero
        capture.microphoneDroppedBuffers = droppedBuffers
        var incrementalInference = PipelineInferenceMetrics()
        incrementalInference.realTimeFactor = incrementalRTF
        var finalInference = PipelineInferenceMetrics()
        finalInference.realTimeFactor = finalRTF
        return PipelineSessionReport(schemaVersion: 1, context: context, outcome: outcome ?? (index.isMultiple(of: 2) ? .completed : .cancelled), completedAt: Date(), latency: latency, audio: audio, capture: capture, queue: PipelineQueueMetrics(), incrementalInference: incrementalInference, finalInference: finalInference, output: PipelineOutputMetrics(), composition: compositionMetrics ?? .init(lateFramesDropped: Int(compositionAnomalies)), resources: PipelineResourceMetrics(startResidentMemoryBytes: nil, endResidentMemoryBytes: nil, maxObservedResidentMemoryAtCheckpoints: nil))
    }
}

private final class RecordingPipelineObservabilitySink: PipelineObservabilityEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PipelineObservabilityEvent] = []
    var events: [PipelineObservabilityEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func emit(_ event: PipelineObservabilityEvent) {
        lock.lock(); storage.append(event); lock.unlock()
    }
}

private final class TestPipelineClock: @unchecked Sendable {
    private var value: UInt64 = 0
    var now: UInt64 { value }
    func advance(ms: UInt64) { value += ms * 1_000_000 }
    func set(_ value: UInt64) { self.value = value }
}
