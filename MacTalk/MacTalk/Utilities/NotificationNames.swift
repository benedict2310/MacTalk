//
//  NotificationNames.swift
//  MacTalk
//
//  Shared notification names used across UI and engine components
//

import Foundation

extension Notification.Name {
    static let shortcutsDidChange = Notification.Name("shortcutsDidChange")
    static let settingsDidChange = Notification.Name("settingsDidChange")
    static let permissionsDidChange = Notification.Name("permissionsDidChange")
    static let providerDidChange = Notification.Name("providerDidChange")
    static let parakeetDownloadStateDidChange = Notification.Name("parakeetDownloadStateDidChange")
    static let parakeetEngineStateDidChange = Notification.Name("parakeetEngineStateDidChange")
}
