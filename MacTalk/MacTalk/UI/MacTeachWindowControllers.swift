import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []
    @Published private(set) var correctionEvents: [HistoryCorrectionEvent] = []
    @Published var selectedRecordID: UUID?
    @Published var searchText = ""
    @Published var providerFilter = ""
    @Published var languageFilter = ""
    @Published var sourceApplicationFilter = ""
    @Published var correctionFilter = 0
    @Published var isTeaching = false
    @Published var heardForm = ""
    @Published var writtenForm = ""
    @Published var spokenForm = ""
    @Published var improveRecognition = true
    @Published var alwaysReplace = true
    @Published var correctionLanguage = ""
    @Published var useOnlyInSourceApplication = false
    @Published var correctionPriority: PersonalVocabularyPriority = .normal
    @Published var errorMessage: String?

    private let coordinator: MacTeachCoordinator
    private nonisolated(unsafe) var historyObserver: NSObjectProtocol?

    init(coordinator: MacTeachCoordinator) {
        self.coordinator = coordinator
        self.historyObserver = NotificationCenter.default.addObserver(
            forName: .macTalkHistoryDidChange,
            object: coordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.load()
            }
        }
    }

    deinit {
        if let historyObserver {
            NotificationCenter.default.removeObserver(historyObserver)
        }
    }

    var selectedRecord: HistoryRecord? {
        records.first { $0.id == selectedRecordID }
    }

    func load() async {
        do {
            records = try await coordinator.historyRecords(
                searchText: searchText,
                provider: providerFilter.isEmpty ? nil : providerFilter,
                language: languageFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : languageFilter,
                sourceBundleID: sourceApplicationFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : sourceApplicationFilter,
                isCorrected: correctionFilter == 0 ? nil : correctionFilter == 1
            )
            if let selectedRecordID, !records.contains(where: { $0.id == selectedRecordID }) {
                self.selectedRecordID = records.first?.id
            } else if selectedRecordID == nil {
                selectedRecordID = records.first?.id
            }
            await loadCorrections()
            errorMessage = nil
        } catch {
            errorMessage = "History could not be loaded."
        }
    }

    func loadCorrections() async {
        guard let selectedRecordID else {
            correctionEvents = []
            return
        }
        correctionEvents = (try? await coordinator.correctionEvents(for: selectedRecordID)) ?? []
    }

    func selectLatestForCorrection() async {
        searchText = ""
        await load()
        guard let latest = records.first else { return }
        selectedRecordID = latest.id
        beginTeaching(latest)
    }

    func beginTeaching(_ record: HistoryRecord? = nil) {
        guard let record = record ?? selectedRecord else { return }
        selectedRecordID = record.id
        heardForm = Self.suggestedHeardForm(in: record.currentText)
        writtenForm = ""
        spokenForm = ""
        improveRecognition = true
        alwaysReplace = true
        correctionLanguage = record.detectedLanguage ?? record.requestedLanguage ?? ""
        useOnlyInSourceApplication = record.sourceBundleID != nil
        correctionPriority = .normal
        isTeaching = true
    }

    static func suggestedHeardForm(in text: String) -> String {
        var lastWord: String?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, _, _, _ in
            if let word { lastWord = word }
        }
        return lastWord ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func saveTeaching() async {
        guard let record = selectedRecord,
              !heardForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !writtenForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter both what MacTalk heard and what you meant."
            return
        }
        do {
            _ = try await coordinator.teach(
                historyRecordID: record.id,
                wrongForm: heardForm,
                writtenForm: writtenForm,
                spokenForm: spokenForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : spokenForm,
                language: correctionLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : correctionLanguage,
                applicationBundleIDs: useOnlyInSourceApplication
                    ? (record.sourceBundleID.map { [$0] } ?? []) : [],
                recognitionHintEnabled: improveRecognition,
                replacementEnabled: alwaysReplace,
                priority: correctionPriority
            )
            isTeaching = false
            await load()
        } catch {
            errorMessage = "That correction conflicts with an existing vocabulary entry."
        }
    }

    func copySelected() {
        guard let text = selectedRecord?.currentText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportSelected(asJSON: Bool) {
        guard let record = selectedRecord else { return }
        do {
            let data: Data
            if asJSON {
                data = try HistoryExportCodec.json(record)
            } else {
                data = Data(HistoryExportCodec.plainText(record).utf8)
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [asJSON ? .json : .plainText]
            panel.nameFieldStringValue = "MacTalk-Transcript-\(record.id.uuidString).\(asJSON ? "json" : "txt")"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "The History item could not be exported."
        }
    }

    func deleteSelected() async {
        guard let id = selectedRecordID else { return }
        do {
            try await coordinator.deleteHistoryRecord(id: id)
            selectedRecordID = nil
            await load()
        } catch {
            errorMessage = "The History item could not be deleted."
        }
    }

    func deleteAll() async {
        do {
            try await coordinator.deleteAllHistory()
            selectedRecordID = nil
            await load()
        } catch {
            errorMessage = "History could not be cleared."
        }
    }
}

private struct HistoryRootView: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                HStack {
                    TextField("Search History", text: $viewModel.searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search transcription history")
                        .onSubmit { Task { await viewModel.load() } }
                    Button("Search") { Task { await viewModel.load() } }
                }
                .padding([.top, .horizontal], 10)
                HStack {
                    Picker("Provider", selection: $viewModel.providerFilter) {
                        Text("All providers").tag("")
                        Text("Whisper").tag("whisper")
                        Text("Parakeet").tag("parakeet")
                    }
                    Picker("Correction", selection: $viewModel.correctionFilter) {
                        Text("All").tag(0)
                        Text("Corrected").tag(1)
                        Text("Uncorrected").tag(2)
                    }
                }
                .padding(.horizontal, 10)
                HStack {
                    TextField("Language", text: $viewModel.languageFilter)
                    TextField("Source app bundle ID", text: $viewModel.sourceApplicationFilter)
                    Button("Apply") { Task { await viewModel.load() } }
                }
                .padding(.horizontal, 10)
                List(viewModel.records, selection: $viewModel.selectedRecordID) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.currentText)
                            .lineLimit(2)
                        HStack {
                            Text(record.completedAt, style: .date)
                            Text(record.completedAt, style: .time)
                            Text(record.provider.capitalized)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(record.id)
                    .accessibilityLabel("Transcript from \(record.completedAt.formatted()): \(record.currentText)")
                }
                .onChange(of: viewModel.selectedRecordID) { Task { await viewModel.loadCorrections() } }
                Button("Clear History…", role: .destructive) {
                    let alert = NSAlert()
                    alert.messageText = "Delete all transcription History?"
                    alert.informativeText = "This permanently removes all transcripts and retained recordings. Personal Vocabulary is not changed."
                    alert.addButton(withTitle: "Delete All")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    Task { await viewModel.deleteAll() }
                }
                .padding([.horizontal, .bottom], 10)
            }
            .frame(minWidth: 280)

            detail
                .frame(minWidth: 380)
        }
        .task { await viewModel.load() }
        .alert("MacTeach", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let record = viewModel.selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(record.currentText)
                        .font(.title3)
                        .textSelection(.enabled)
                        .accessibilityLabel("Current transcript")
                    HStack {
                        Button("Copy") { viewModel.copySelected() }
                        Button("Teach MacTalk…") { viewModel.beginTeaching() }
                        Menu("Export") {
                            Button("Plain Text…") { viewModel.exportSelected(asJSON: false) }
                            Button("JSON Metadata…") { viewModel.exportSelected(asJSON: true) }
                        }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            let alert = NSAlert()
                            alert.messageText = "Delete this History item?"
                            alert.informativeText = record.hasRetainedAudio
                                ? "The transcript and its retained recording will be permanently removed."
                                : "The transcript will be permanently removed."
                            alert.addButton(withTitle: "Delete")
                            alert.addButton(withTitle: "Cancel")
                            guard alert.runModal() == .alertFirstButtonReturn else { return }
                            Task { await viewModel.deleteSelected() }
                        }
                    }
                    if viewModel.isTeaching {
                        GroupBox("Teach MacTalk") {
                            Form {
                                TextField("MacTalk heard", text: $viewModel.heardForm)
                                TextField("I meant", text: $viewModel.writtenForm)
                                TextField("Spoken form (optional)", text: $viewModel.spokenForm)
                                Toggle("Improve recognition", isOn: $viewModel.improveRecognition)
                                Toggle("Always replace this wrong form", isOn: $viewModel.alwaysReplace)
                                TextField("Language (optional)", text: $viewModel.correctionLanguage)
                                if record.sourceBundleID != nil {
                                    Toggle(
                                        "Use only in \(record.sourceDisplayName ?? "the source app")",
                                        isOn: $viewModel.useOnlyInSourceApplication
                                    )
                                }
                                Picker("Priority", selection: $viewModel.correctionPriority) {
                                    Text("Normal").tag(PersonalVocabularyPriority.normal)
                                    Text("Important").tag(PersonalVocabularyPriority.important)
                                }
                                HStack {
                                    Button("Cancel") { viewModel.isTeaching = false }
                                    Button("Save Correction") { Task { await viewModel.saveTeaching() } }
                                        .keyboardShortcut(.defaultAction)
                                }
                            }
                            .padding(8)
                        }
                    }
                    DisclosureGroup("Transcription provenance") {
                        LabeledContent("Provider", value: record.provider.capitalized)
                        LabeledContent("Model", value: record.modelID)
                        LabeledContent("Language", value: record.detectedLanguage ?? record.requestedLanguage ?? "Auto")
                        LabeledContent("Capture", value: record.captureMode)
                        Divider()
                        Text("Raw ASR").font(.headline)
                        Text(record.rawASRText).textSelection(.enabled)
                        Text("Cleaned").font(.headline)
                        Text(record.cleanedText).textSelection(.enabled)
                        Text("Delivered").font(.headline)
                        Text(record.deliveredText).textSelection(.enabled)
                    }
                    if !viewModel.correctionEvents.isEmpty {
                        DisclosureGroup("Corrections applied") {
                            ForEach(viewModel.correctionEvents) { event in
                                LabeledContent(event.wrongText, value: event.intendedText)
                                    .accessibilityLabel("MacTalk heard \(event.wrongText), intended \(event.intendedText)")
                            }
                        }
                    }
                    Text(record.hasRetainedAudio ? "Recording retained" : "Recording was not retained")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("No Transcript Selected", systemImage: "text.bubble")
        }
    }
}

@MainActor
final class HistoryWindowController: NSWindowController {
    let viewModel: HistoryViewModel

    init(coordinator: MacTeachCoordinator) {
        self.viewModel = HistoryViewModel(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacTalk History"
        window.setAccessibilityLabel("MacTalk transcription history")
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: HistoryRootView(viewModel: viewModel))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func selectLatestForCorrection() async {
        await viewModel.selectLatestForCorrection()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class PersonalVocabularyViewModel: ObservableObject {
    @Published private(set) var entries: [PersonalVocabularyEntry] = []
    @Published var selectedEntryID: UUID?
    @Published var searchText = ""
    @Published var writtenForm = ""
    @Published var wrongForms = ""
    @Published var spokenForm = ""
    @Published var language = ""
    @Published var priority: PersonalVocabularyPriority = .normal
    @Published var recognitionHintEnabled = true
    @Published var replacementEnabled = true
    @Published var errorMessage: String?

    private let coordinator: MacTeachCoordinator
    private nonisolated(unsafe) var vocabularyObserver: NSObjectProtocol?

    init(coordinator: MacTeachCoordinator) {
        self.coordinator = coordinator
        self.vocabularyObserver = NotificationCenter.default.addObserver(
            forName: .macTalkVocabularyDidChange,
            object: coordinator,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.load()
            }
        }
    }

    deinit {
        if let vocabularyObserver {
            NotificationCenter.default.removeObserver(vocabularyObserver)
        }
    }

    var filteredEntries: [PersonalVocabularyEntry] {
        let query = VocabularyNormalization.text(searchText)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            VocabularyNormalization.text(entry.writtenForm).contains(query)
                || entry.wrongForms.contains { VocabularyNormalization.text($0.text).contains(query) }
                || entry.spokenForm.map { VocabularyNormalization.text($0).contains(query) } == true
        }
    }

    var selectedEntry: PersonalVocabularyEntry? {
        entries.first { $0.id == selectedEntryID }
    }

    func effectivenessSummary(for entry: PersonalVocabularyEntry) -> String {
        guard entry.directRecognitionCount + entry.applicationCount > 0 else {
            return "No later uses observed yet"
        }
        var parts = [
            "Recognized directly \(Self.times(entry.directRecognitionCount))",
            "Repaired \(Self.times(entry.applicationCount))",
        ]
        if entry.correctionCount > 0 {
            parts.append(entry.correctionCount == 1 ? "Taught once" : "Taught \(entry.correctionCount) times")
        }
        return parts.joined(separator: " · ")
    }

    private static func times(_ count: Int) -> String {
        count == 1 ? "once" : "\(count) times"
    }

    func load() async {
        do {
            entries = try await coordinator.vocabularyEntries()
            errorMessage = nil
        } catch {
            errorMessage = "Personal Vocabulary could not be loaded."
        }
    }

    func beginAdd() {
        selectedEntryID = nil
        writtenForm = ""
        wrongForms = ""
        spokenForm = ""
        language = ""
        priority = .normal
        recognitionHintEnabled = true
        replacementEnabled = true
    }

    func edit(_ entry: PersonalVocabularyEntry) {
        selectedEntryID = entry.id
        writtenForm = entry.writtenForm
        wrongForms = entry.wrongForms.map(\.text).joined(separator: ", ")
        spokenForm = entry.spokenForm ?? ""
        language = entry.language ?? ""
        priority = entry.priority
        recognitionHintEnabled = entry.recognitionHintEnabled
        replacementEnabled = entry.replacementEnabled
    }

    func selectEntry(id: UUID?) {
        guard let id, let entry = entries.first(where: { $0.id == id }) else { return }
        edit(entry)
    }

    func save() async {
        let existing = entries.first { $0.id == selectedEntryID }
        let timestamp = Date()
        let wrong = wrongForms.split(separator: ",").map {
            PersonalVocabularyWrongForm(text: String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }.filter { !$0.text.isEmpty }
        let entry = PersonalVocabularyEntry(
            id: existing?.id ?? UUID(),
            writtenForm: writtenForm,
            spokenForm: spokenForm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : spokenForm,
            wrongForms: wrong,
            language: language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : language,
            applicationBundleIDs: existing?.applicationBundleIDs ?? [],
            priority: priority,
            recognitionHintEnabled: recognitionHintEnabled,
            replacementEnabled: replacementEnabled,
            isEnabled: existing?.isEnabled ?? true,
            source: existing?.source ?? .manual,
            sourceHistoryRecordID: existing?.sourceHistoryRecordID,
            createdAt: existing?.createdAt ?? timestamp,
            updatedAt: timestamp,
            applicationCount: existing?.applicationCount ?? 0,
            correctionCount: existing?.correctionCount ?? 0,
            lastAppliedAt: existing?.lastAppliedAt,
            directRecognitionCount: existing?.directRecognitionCount ?? 0,
            lastRecognizedAt: existing?.lastRecognizedAt
        )
        do {
            try await coordinator.saveVocabularyEntry(entry)
            await load()
            edit(entry)
        } catch let error as PersonalVocabularyStoreError {
            switch error {
            case let .validation(issues): errorMessage = issues.first?.message ?? "The entry is invalid."
            case .conflicts: errorMessage = "That entry conflicts with an existing correction."
            default: errorMessage = "The vocabulary entry could not be saved."
            }
        } catch {
            errorMessage = "The vocabulary entry could not be saved."
        }
    }

    func setEnabled(_ enabled: Bool, entry: PersonalVocabularyEntry) async {
        do {
            try await coordinator.setVocabularyEntryEnabled(enabled, id: entry.id)
            await load()
        } catch {
            errorMessage = "The vocabulary entry could not be updated."
        }
    }

    func deleteSelected() async {
        guard let selectedEntryID else { return }
        do {
            try await coordinator.deleteVocabularyEntry(id: selectedEntryID)
            beginAdd()
            await load()
        } catch {
            errorMessage = "The vocabulary entry could not be deleted."
        }
    }

    func deleteAll() async {
        do {
            try await coordinator.deleteAllVocabulary()
            beginAdd()
            await load()
        } catch {
            errorMessage = "Personal Vocabulary could not be cleared."
        }
    }

    func importCSV() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let preview = try VocabularyCSVCodec().previewImport(
                data: Data(contentsOf: url),
                existingEntries: entries
            )
            guard preview.issues.isEmpty, preview.conflictCount == 0 else {
                errorMessage = "Import found \(preview.issues.count) issue(s) and \(preview.conflictCount) conflict(s). No entries were changed."
                return
            }
            let confirmation = NSAlert()
            confirmation.messageText = "Import \(preview.entries.count) vocabulary entries?"
            confirmation.informativeText = "Review complete: \(preview.duplicateRowCount) duplicate row(s) will be merged."
            confirmation.addButton(withTitle: "Import")
            confirmation.addButton(withTitle: "Cancel")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
            try await coordinator.importVocabularyEntries(preview.entries)
            await load()
        } catch {
            errorMessage = "The CSV file could not be imported."
        }
    }

    func exportCSV() {
        do {
            let data = try VocabularyCSVCodec().export(entries)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "MacTalk-Personal-Vocabulary.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            errorMessage = "Personal Vocabulary could not be exported."
        }
    }
}

private struct PersonalVocabularyRootView: View {
    @ObservedObject var viewModel: PersonalVocabularyViewModel

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                TextField("Search vocabulary", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding([.top, .horizontal], 10)
                List(viewModel.filteredEntries, selection: $viewModel.selectedEntryID) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.writtenForm).font(.headline)
                            Text(entry.wrongForms.map(\.text).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(viewModel.effectivenessSummary(for: entry))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(
                            get: { entry.isEnabled },
                            set: { enabled in Task { await viewModel.setEnabled(enabled, entry: entry) } }
                        ))
                        .labelsHidden()
                    }
                    .tag(entry.id)
                    .accessibilityLabel(
                        "\(entry.writtenForm), heard forms \(entry.wrongForms.map(\.text).joined(separator: ", ")), "
                        + "\(entry.applicationBundleIDs.isEmpty ? "all applications" : entry.applicationBundleIDs.sorted().joined(separator: ", ")), "
                        + "priority \(entry.priority.rawValue), \(entry.isEnabled ? "enabled" : "disabled"), source \(entry.source.rawValue), "
                        + viewModel.effectivenessSummary(for: entry)
                    )
                }
                .onChange(of: viewModel.selectedEntryID) { viewModel.selectEntry(id: viewModel.selectedEntryID) }
                HStack {
                    Button("Add") { viewModel.beginAdd() }
                    Button("Import…") { Task { await viewModel.importCSV() } }
                    Button("Export…") { viewModel.exportCSV() }
                    Button("Delete All…", role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Delete all Personal Vocabulary?"
                        alert.informativeText = "This permanently removes every recognition hint and correction rule."
                        alert.addButton(withTitle: "Delete All")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        Task { await viewModel.deleteAll() }
                    }
                }
                .padding([.horizontal, .bottom], 10)
            }
            .frame(minWidth: 310)

            Form {
                TextField("Written form", text: $viewModel.writtenForm)
                TextField("Known wrong forms (comma-separated)", text: $viewModel.wrongForms)
                TextField("Spoken form", text: $viewModel.spokenForm)
                TextField("Language (optional)", text: $viewModel.language)
                Picker("Priority", selection: $viewModel.priority) {
                    Text("Normal").tag(PersonalVocabularyPriority.normal)
                    Text("Important").tag(PersonalVocabularyPriority.important)
                }
                Toggle("Improve recognition", isOn: $viewModel.recognitionHintEnabled)
                Toggle("Always replace known wrong forms", isOn: $viewModel.replacementEnabled)
                if let selectedEntry = viewModel.selectedEntry {
                    LabeledContent("Effectiveness", value: viewModel.effectivenessSummary(for: selectedEntry))
                }
                HStack {
                    Button("Save") { Task { await viewModel.save() } }
                        .keyboardShortcut(.defaultAction)
                    Button("Delete", role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = "Delete this vocabulary entry?"
                        alert.informativeText = "Its recognition hint and correction behavior will stop immediately."
                        alert.addButton(withTitle: "Delete")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        Task { await viewModel.deleteSelected() }
                    }
                        .disabled(viewModel.selectedEntryID == nil)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 400)
        }
        .task { await viewModel.load() }
        .alert("MacTeach", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

@MainActor
final class PersonalVocabularyWindowController: NSWindowController {
    let viewModel: PersonalVocabularyViewModel

    init(coordinator: MacTeachCoordinator) {
        self.viewModel = PersonalVocabularyViewModel(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Personal Vocabulary"
        window.setAccessibilityLabel("MacTalk personal vocabulary")
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: PersonalVocabularyRootView(viewModel: viewModel))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
