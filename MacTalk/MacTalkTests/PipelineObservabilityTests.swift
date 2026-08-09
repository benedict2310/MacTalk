import Foundation
import XCTest
@testable import MacTalk

final class PipelineObservabilityTests: XCTestCase {
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
        XCTAssertEqual(report.finalInference.failedCount, 1)
        XCTAssertEqual(report.finalInference.completedCount, 2)
        XCTAssertEqual(report.finalInference.realTimeFactor!, 2.0 / 3.0, accuracy: 0.001)
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
        await store.record(makeReport(index: 1, firstPartialMs: 1))
        await store.record(makeReport(index: 2, firstPartialMs: 2))
        await store.record(makeReport(index: 3, firstPartialMs: 100))
        await store.record(makeReport(index: 4, firstPartialMs: nil))
        let formatted = await store.formattedReport(limit: 10)
        XCTAssertTrue(formatted.contains("First partial ms p50/p95: 2.000/100.000"))
    }

    func testEmptyStoreHasUsefulReport() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("pipeline-metrics.jsonl")
        let formatted = await PipelineMetricsStore(fileURL: url).formattedReport(limit: 10)
        XCTAssertTrue(formatted.contains("No completed sessions"))
        XCTAssertTrue(formatted.contains("Schema version: 1"))
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

    private func makeReport(index: Int, provider: ASRProvider = .whisper, modelID: String? = nil, mode: SettingsCaptureMode = .micOnly, firstPartialMs: Double? = nil) -> PipelineSessionReport {
        let context = PipelineSessionContext(id: UUID(), provider: provider, modelID: modelID ?? "model-\(index)", captureMode: mode, language: nil, batteryMode: false, startedAt: Date(timeIntervalSince1970: Double(index)))
        var latency = PipelineLatencyMetrics()
        latency.firstPartialFromStartMs = firstPartialMs
        return PipelineSessionReport(schemaVersion: 1, context: context, outcome: index.isMultiple(of: 2) ? .completed : .cancelled, completedAt: Date(), latency: latency, audio: PipelineAudioMetrics(), capture: .zero, queue: PipelineQueueMetrics(), incrementalInference: PipelineInferenceMetrics(), finalInference: PipelineInferenceMetrics(), output: PipelineOutputMetrics(), composition: .init(), resources: PipelineResourceMetrics(startResidentMemoryBytes: nil, endResidentMemoryBytes: nil, maxObservedResidentMemoryAtCheckpoints: nil))
    }
}

private final class TestPipelineClock: @unchecked Sendable {
    private var value: UInt64 = 0
    var now: UInt64 { value }
    func advance(ms: UInt64) { value += ms * 1_000_000 }
    func set(_ value: UInt64) { self.value = value }
}
