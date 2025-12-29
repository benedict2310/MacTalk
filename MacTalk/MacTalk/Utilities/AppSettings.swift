//
//  AppSettings.swift
//  MacTalk
//
//  Thread-safe access to persistent app settings
//

import Foundation
import os

final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()

    private struct State {
        var provider: ASRProvider
    }

    private let stateLock: OSAllocatedUnfairLock<State>
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedProvider = defaults.string(forKey: Self.providerKey)
        let provider = ASRProvider(rawValue: storedProvider ?? "") ?? .whisper
        self.stateLock = OSAllocatedUnfairLock(initialState: State(provider: provider))
    }

    var provider: ASRProvider {
        get {
            stateLock.withLock { $0.provider }
        }
        set {
            let shouldNotify = stateLock.withLock { state -> Bool in
                guard state.provider != newValue else { return false }
                state.provider = newValue
                return true
            }

            guard shouldNotify else { return }

            defaults.set(newValue.rawValue, forKey: Self.providerKey)
            NotificationCenter.default.post(name: .providerDidChange, object: newValue)
        }
    }

    private static let providerKey = "asrProvider"

    #if DEBUG
    static func makeForTesting(defaults: UserDefaults) -> AppSettings {
        return AppSettings(defaults: defaults)
    }
    #endif
}
