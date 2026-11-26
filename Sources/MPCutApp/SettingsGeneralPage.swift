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
                .help("Choose what happens when you open several recordings from Finder at once: ask, join them as clips or open them as a multicam project.")
                SettingsNumericField(.recentItems, value: $preferences.recentFilesLimit, in: EditorPreferences.recentFilesRange,
                                     step: 1, help: "Type how many recent items File → Open Recent lists")
                Toggle(SettingsRow.draftRecovery.title, isOn: $preferences.offersDraftRecovery)
                    .settingsRow(.draftRecovery)
                    .help("When MPCut opens, offer to recover untitled projects that were not saved.")
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
                    .help("Warn before an edit you make lowers the export tier of the timeline.")
                Toggle(SettingsRow.rescanConfirmation.title, isOn: $preferences.confirmsSceneRescan)
                    .settingsRow(.rescanConfirmation)
                    .help("Ask before scanning a recording’s scenes again.")
                Toggle(SettingsRow.exportMessage.title, isOn: $preferences.showsProjectExportMessage)
                    .settingsRow(.exportMessage)
                    .help("Show a message when a project export finishes with no warnings.")
                HStack {
                    Spacer()
                    Button(SettingsRow.resetWarnings.title, action: preferences.resetAllWarnings)
                        .disabled(!preferences.hasSuppressedWarnings)
                        .settingsRow(.resetWarnings)
                        .help(preferences.hasSuppressedWarnings
                              ? "Turn every warning above back on. A Finder choice made with “Don’t ask again” goes back to Ask."
                              : "Every warning already asks.")
                }
            } header: {
                Text("Warnings")
            } footer: {
                SettingsFootnote("Some confirmations always ask and have no switch: “Restart scene analysis?”, which discards a paused scan’s progress, and the save, discard and quit confirmations.")
            }
        }
    }
}
