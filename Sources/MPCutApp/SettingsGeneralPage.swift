import SwiftUI

struct SettingsGeneralPage: View {
    @ObservedObject var preferences: EditorPreferences

    var body: some View {
        SettingsForm(page: .general, preferences: preferences) {
            Section("Opening") {
                Picker(SettingsRow.multipleRecordings.title, selection: $preferences.multipleRecordingsAction) {
                    Text("Ask").tag(MultipleRecordingsAction.ask)
                    Text("Join clips").tag(MultipleRecordingsAction.join)
                    Text("Open as multicam").tag(MultipleRecordingsAction.multicam)
                }
                .settingsRow(.multipleRecordings)
                .help("Choose what opening several recordings from Finder does")
                SettingsNumericField(.recentItems, value: $preferences.recentFilesLimit, in: EditorPreferences.recentFilesRange,
                                     step: 1, help: "Enter how many recent items File → Open Recent lists")
                Toggle(SettingsRow.draftRecovery.title, isOn: $preferences.offersDraftRecovery)
                    .settingsRow(.draftRecovery)
                    .help("Ask about unsaved untitled projects when MPCut opens")
            }
            Section {
                HistoryLimitField(limit: $preferences.historyLimit)
            } header: {
                Text("History")
            } footer: {
                SettingsFootnote("Undo and redo share this limit. Lowering it immediately removes older history from open projects. Set it to 0 to turn off history.")
            }
            Section {
                Toggle(SettingsRow.tierWarning.title, isOn: $preferences.warnBeforeLoweringExportTier)
                    .settingsRow(.tierWarning)
                    .help("Warn about export limits")
                Toggle(SettingsRow.rescanConfirmation.title, isOn: $preferences.confirmsSceneRescan)
                    .settingsRow(.rescanConfirmation)
                    .help("Ask before scanning a recording's scenes again")
                Toggle(SettingsRow.exportMessage.title, isOn: $preferences.showsProjectExportMessage)
                    .settingsRow(.exportMessage)
                    .help("Confirm that a project interchange export finished")
                HStack {
                    Spacer()
                    Button(SettingsRow.resetWarnings.title, action: preferences.resetAllWarnings)
                        .disabled(!preferences.hasSuppressedWarnings)
                        .settingsRow(.resetWarnings)
                        .help("Show every warning again")
                }
            } header: {
                Text("Warnings")
            } footer: {
                SettingsFootnote("“Restart scene analysis?” discards a paused scan’s progress, so it always asks. Save, discard and quit confirmations always ask.")
            }
        }
    }
}
