//
//  RecordingStartGate.swift
//  MacTalk
//
//  Small decision helper for recording startup preparation
//

import Foundation

enum RecordingStartPreparationAction: Equatable {
    case none
    case promptForParakeetDownload
    case prepareParakeetEngineAndRetry
    case waitForParakeetEnginePreparation
}

struct RecordingStartPreparationDecision: Equatable {
    let action: RecordingStartPreparationAction
    let clearMismatchedEngine: Bool
}

enum RecordingStartGate {
    static func decision(
        provider: ASRProvider,
        engineProvider: ASRProvider?,
        modelsAvailable: Bool,
        allowParakeetPrepare: Bool,
        isPreparingParakeetEngine: Bool
    ) -> RecordingStartPreparationDecision {
        let clearMismatchedEngine = engineProvider != nil && engineProvider != provider
        let effectiveEngineProvider = clearMismatchedEngine ? nil : engineProvider

        guard provider == .parakeet else {
            return RecordingStartPreparationDecision(
                action: .none,
                clearMismatchedEngine: clearMismatchedEngine
            )
        }

        guard effectiveEngineProvider == nil else {
            return RecordingStartPreparationDecision(
                action: .none,
                clearMismatchedEngine: clearMismatchedEngine
            )
        }

        guard modelsAvailable else {
            return RecordingStartPreparationDecision(
                action: allowParakeetPrepare ? .promptForParakeetDownload : .none,
                clearMismatchedEngine: clearMismatchedEngine
            )
        }

        let action: RecordingStartPreparationAction = isPreparingParakeetEngine
            ? .waitForParakeetEnginePreparation
            : .prepareParakeetEngineAndRetry

        return RecordingStartPreparationDecision(
            action: action,
            clearMismatchedEngine: clearMismatchedEngine
        )
    }
}
