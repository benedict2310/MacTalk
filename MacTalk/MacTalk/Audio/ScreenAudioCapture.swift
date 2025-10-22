//
//  ScreenAudioCapture.swift
//  MacTalk
//
//  App/System audio capture via ScreenCaptureKit
//

import ScreenCaptureKit
import AVFoundation

final class ScreenAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onStreamError: ((Error) -> Void)?

    func selectFirstWindow(named name: String) async throws {
        let content = try await SCShareableContent.current

        guard let app = content.applications.first(where: { $0.applicationName == name }),
              let window = app.windows.first else {
            throw NSError(domain: "ScreenAudioCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not find app named '\(name)' or it has no windows"
            ])
        }

        try await startCapture(filter: SCContentFilter(desktopIndependentWindow: window))
    }

    func selectApp(app: SCRunningApplication) async throws {
        guard let window = app.windows.first else {
            throw NSError(domain: "ScreenAudioCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "App '\(app.applicationName)' has no windows"
            ])
        }

        try await startCapture(filter: SCContentFilter(desktopIndependentWindow: window))
    }

    func selectDisplay(display: SCDisplay) async throws {
        try await startCapture(filter: SCContentFilter(display: display, excludingWindows: []))
    }

    func selectDisplay() async throws {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenAudioCapture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No displays found"
            ])
        }

        try await startCapture(filter: SCContentFilter(display: display, excludingWindows: []))
    }

    private func startCapture(filter: SCContentFilter) async throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.queueDepth = 8

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream

        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: .global(qos: .userInitiated)
        )

        try await stream.startCapture()
    }

    func stop() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else { return }
        onAudioSampleBuffer?(sampleBuffer)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("ScreenCaptureKit stream stopped with error: \(error)")
        onStreamError?(error)
    }

    deinit {
        stop()
    }
}
