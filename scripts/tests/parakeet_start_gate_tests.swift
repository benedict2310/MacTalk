import Foundation

@main
struct ParakeetStartGateTests {
    static func main() {
        expect(
            .whisper,
            engineProvider: nil,
            modelsAvailable: false,
            allowParakeetPrepare: true,
            isPreparingParakeetEngine: false,
            action: .none,
            clearMismatchedEngine: false,
            "whisper leaves start alone"
        )

        expect(
            .parakeet,
            engineProvider: nil,
            modelsAvailable: false,
            allowParakeetPrepare: true,
            isPreparingParakeetEngine: false,
            action: .promptForParakeetDownload,
            clearMismatchedEngine: false,
            "parakeet prompts when models are missing"
        )

        expect(
            .parakeet,
            engineProvider: nil,
            modelsAvailable: true,
            allowParakeetPrepare: false,
            isPreparingParakeetEngine: false,
            action: .prepareParakeetEngineAndRetry,
            clearMismatchedEngine: false,
            "parakeet prepares after download before retrying start"
        )

        expect(
            .parakeet,
            engineProvider: nil,
            modelsAvailable: true,
            allowParakeetPrepare: true,
            isPreparingParakeetEngine: true,
            action: .waitForParakeetEnginePreparation,
            clearMismatchedEngine: false,
            "parakeet waits for in-flight preparation"
        )

        expect(
            .whisper,
            engineProvider: .parakeet,
            modelsAvailable: false,
            allowParakeetPrepare: false,
            isPreparingParakeetEngine: false,
            action: .none,
            clearMismatchedEngine: true,
            "mismatched engine gets cleared"
        )

        print("parakeet start gate tests passed")
    }

    private static func expect(
        _ provider: ASRProvider,
        engineProvider: ASRProvider?,
        modelsAvailable: Bool,
        allowParakeetPrepare: Bool,
        isPreparingParakeetEngine: Bool,
        action: RecordingStartPreparationAction,
        clearMismatchedEngine: Bool,
        _ label: String
    ) {
        let decision = RecordingStartGate.decision(
            provider: provider,
            engineProvider: engineProvider,
            modelsAvailable: modelsAvailable,
            allowParakeetPrepare: allowParakeetPrepare,
            isPreparingParakeetEngine: isPreparingParakeetEngine
        )

        precondition(decision.action == action, "\(label): expected action \(action), got \(decision.action)")
        precondition(
            decision.clearMismatchedEngine == clearMismatchedEngine,
            "\(label): expected clearMismatchedEngine=\(clearMismatchedEngine), got \(decision.clearMismatchedEngine)"
        )
    }
}
