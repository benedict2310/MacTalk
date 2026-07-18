import AppKit

/// Focused AppKit effect adapters. Coordinators return values/effects; these
/// helpers are the only code that builds modal alerts or status-bar imagery.
@MainActor
enum StatusBarAlertPresenter {
    static func showPermissions(_ report: PermissionStatusReport) {
        let alert = NSAlert()
        alert.messageText = "Permissions Status"
        alert.informativeText = """
        Microphone: \(report.microphoneGranted ? "✅ Granted" : "❌ Denied")
        Screen Recording: \(report.screenRecordingGranted ? "✅ Granted" : "❌ Denied")
        Accessibility: \(report.accessibilityTrusted ? "✅ Granted" : "❌ Denied")
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MacTalk v1.0"
        alert.informativeText = """
        A native macOS app for local voice transcription powered by Whisper.

        100% on-device processing. No cloud, no network calls.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func showMicrophoneGuidance() {
        Permissions.showMicrophonePermissionGuidance()
    }

    static func showScreenRecordingGuidance() {
        Permissions.ensureScreenRecordingGuide()
    }

    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    static func confirmDownload(_ requirement: ModelRequirement) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        switch requirement {
        case let .whisper(spec):
            alert.messageText = "Model Not Available"
            alert.informativeText = """
            The model '\(spec.displayName)' is not downloaded yet.

            Size: \(ByteCountFormatter.string(fromByteCount: spec.sizeBytes, countStyle: .file))

            Would you like to download this model now?
            """
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Use Different Model")
            alert.addButton(withTitle: "Cancel")
        case .parakeet:
            alert.messageText = "Download Parakeet Model?"
            alert.informativeText = "This will download approximately 600MB of model files."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
enum StatusBarIconPresenter {
    static func installDefault(on button: NSStatusBarButton) {
        set(button, imageName: "MenuBarIcon", symbolName: "mic.fill", title: "🎙️", description: "MacTalk")
    }

    static func render(recording: Bool, on button: NSStatusBarButton) {
        set(button, imageName: recording ? "MenuBarIconRecording" : "MenuBarIcon", symbolName: recording ? "mic.fill.badge.plus" : "mic.fill", title: recording ? "🔴" : "🎙️", description: recording ? "Recording" : "MacTalk")
    }

    private static func set(_ button: NSStatusBarButton, imageName: String, symbolName: String, title: String, description: String) {
        if let image = NSImage(named: imageName) ?? NSImage(systemSymbolName: symbolName, accessibilityDescription: description) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = title
        }
    }
}
