import AppKit

/// Owns MacTeach windows so the status-bar composition root only routes menu actions.
@MainActor
final class MacTeachWindowCoordinator {
    private let coordinator: MacTeachCoordinator?
    private var historyController: HistoryWindowController?
    private var vocabularyController: PersonalVocabularyWindowController?

    init(coordinator: MacTeachCoordinator?) {
        self.coordinator = coordinator
    }

    func showHistory() {
        guard let coordinator else {
            StatusBarAlertPresenter.showError("History storage could not be opened.")
            return
        }
        if historyController == nil {
            historyController = HistoryWindowController(coordinator: coordinator)
        }
        historyController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPersonalVocabulary() {
        guard let coordinator else {
            StatusBarAlertPresenter.showError("Personal Vocabulary storage could not be opened.")
            return
        }
        if vocabularyController == nil {
            vocabularyController = PersonalVocabularyWindowController(coordinator: coordinator)
        }
        vocabularyController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func correctLastTranscription() {
        guard let coordinator else {
            StatusBarAlertPresenter.showError("History storage could not be opened.")
            return
        }
        if historyController == nil {
            historyController = HistoryWindowController(coordinator: coordinator)
        }
        Task { @MainActor [weak self] in
            await self?.historyController?.selectLatestForCorrection()
        }
    }

    func close() {
        historyController?.close()
        historyController = nil
        vocabularyController?.close()
        vocabularyController = nil
    }
}
