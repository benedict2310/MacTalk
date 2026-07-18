import AppKit

/// Errors surfaced while preparing the app-audio picker.
enum ScreenCaptureError: Error, LocalizedError, Equatable {
    case timeout
    case permissionDenied
    case noSourcesAvailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Screen capture system is not responding.\n\nThis is a known macOS bug. Try:\n1. Run: killall -9 replayd\n2. Log out and back in\n3. Restart your Mac"
        case .permissionDenied:
            return "Screen Recording permission is not granted."
        case .noSourcesAvailable:
            return "No audio sources are available for capture."
        case let .failed(message):
            return message
        }
    }
}

/// A source candidate produced by the ScreenCaptureKit adapter. Keeping the
/// candidate value-type makes sorting/deduplication deterministic and keeps
/// ScreenCaptureKit and AppKit out of coordinator tests.
struct ShareableContentSource: @unchecked Sendable {
    let identity: String
    let source: AppPickerWindowController.AudioSource
    let ownsWindow: Bool
    let isSystemAudio: Bool
}

struct ShareableContentSnapshot: @unchecked Sendable {
    let sources: [ShareableContentSource]

    init(sources: [ShareableContentSource]) {
        self.sources = sources
    }
}

@MainActor
protocol ShareableContentClient: AnyObject {
    func loadShareableContent(timeout: TimeInterval) async throws -> ShareableContentSnapshot
}

@MainActor
protocol AppAudioSourceCoordinating: AnyObject {
    func loadSources() async throws -> [AppPickerWindowController.AudioSource]
    func cleanup()
}

@MainActor
final class AppAudioSourceCoordinator: AppAudioSourceCoordinating {
    private let client: any ShareableContentClient
    private let timeout: TimeInterval
    private var operationID = UUID()

    init(client: any ShareableContentClient, timeout: TimeInterval = 5) {
        self.client = client
        self.timeout = timeout
    }

    func loadSources() async throws -> [AppPickerWindowController.AudioSource] {
        let operation = UUID()
        operationID = operation
        let snapshot: ShareableContentSnapshot
        do {
            snapshot = try await client.loadShareableContent(timeout: timeout)
        } catch is TimeoutError {
            throw ScreenCaptureError.timeout
        } catch let error as ScreenCaptureError {
            throw error
        } catch {
            throw ScreenCaptureError.failed(error.localizedDescription)
        }

        // Cancellation or a newer request makes this result stale. The caller
        // also tags its request, so this guard protects direct users of the
        // source coordinator as well as RecordingSessionCoordinator.
        guard operationID == operation else { throw CancellationError() }

        var seen = Set<String>()
        let sources = snapshot.sources
            .filter { $0.isSystemAudio || $0.ownsWindow }
            .sorted { lhs, rhs in
                if lhs.isSystemAudio != rhs.isSystemAudio {
                    return lhs.isSystemAudio
                }
                let nameOrder = lhs.source.name.localizedCaseInsensitiveCompare(rhs.source.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.identity.localizedCaseInsensitiveCompare(rhs.identity) == .orderedAscending
            }
            .compactMap { candidate -> AppPickerWindowController.AudioSource? in
                guard seen.insert(candidate.identity).inserted else { return nil }
                return candidate.source
            }

        guard !sources.isEmpty else { throw ScreenCaptureError.noSourcesAvailable }
        return sources
    }

    func cleanup() { operationID = UUID() }
}
