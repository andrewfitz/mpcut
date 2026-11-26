import AppKit
import MPCutCore
import SwiftUI

struct SettingsExportPage: View {
    @ObservedObject var preferences: EditorPreferences
    /// Nil until checked. A process without an app bundle, such as the test host, always reads unavailable.
    @State private var notificationAuthorization: ExportNotificationAuthorization?
    /// Whether the chosen start folder is reachable, checked off the main actor: an offline volume can take a long time
    /// to answer. Nil until checked, which shows no warning.
    @State private var chosenFolderAvailable: Bool?

    var body: some View {
        SettingsForm(page: .export, preferences: preferences) {
            Section {
                Picker(SettingsRow.movieMode.title, selection: $preferences.defaultExportMode) {
                    ForEach(ExportMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .settingsRow(.movieMode)
                .help("Choose the mode movie exports start with.")
                Picker(SettingsRow.jpegPreset.title, selection: $preferences.jpegPreset) {
                    Text("Small review images").tag(JPEGPreset.review)
                    Text("Full resolution, high quality").tag(JPEGPreset.full)
                }
                .settingsRow(.jpegPreset)
                .help("Choose the preset JPEG frame exports start with.")
            } header: {
                Text("Defaults")
            } footer: {
                SettingsFootnote("Export rules still decide what a timeline can use. A panel shows the effective choice when a default is unavailable.")
            }
            Section("Encoding") {
                Picker(SettingsRow.reencodeCodec.title, selection: $preferences.reencodeCodec) {
                    ForEach(EditorPreferences.reencodeCodecs, id: \.self) { Text($0.displayName).tag($0) }
                }
                .settingsRow(.reencodeCodec)
                .help("Choose the codec re-encoded exports start with.")
                Picker(SettingsRow.reencodeQuality.title, selection: $preferences.reencodeQuality) {
                    ForEach(EditorPreferences.reencodeQualities, id: \.self) { Text($0.displayName).tag($0) }
                }
                .settingsRow(.reencodeQuality)
                .help("Choose the quality H.264 and HEVC exports start with.")
                Picker(SettingsRow.proresQuality.title, selection: $preferences.proresQuality) {
                    ForEach(EditorPreferences.proresQualities, id: \.self) { Text($0.displayName).tag($0) }
                }
                .settingsRow(.proresQuality)
                .help("Choose the quality ProRes exports start with.")
                SettingsLabeledControl(SettingsRow.container.title) {
                    Picker(SettingsRow.container.title, selection: $preferences.reencodeContainer) {
                        Text("Automatic").tag(ExportContainerChoice.automatic)
                        Text("MP4").tag(ExportContainerChoice.mp4)
                        Text("MOV").tag(ExportContainerChoice.mov)
                        Text("MKV").tag(ExportContainerChoice.mkv)
                    }
                    .settingsRow(.container)
                    .help("Choose the container H.264 and HEVC exports start with. Automatic uses MP4 in the sequence editor and MOV in multicam; ProRes is always MOV.")
                }
                Picker(SettingsRow.multicamAudio.title, selection: $preferences.multicamAudioLayout) {
                    ForEach(MulticamAudioOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .settingsRow(.multicamAudio)
                .help("Choose the sound multicam exports start with: separate tracks, or one track downmixed to mono or stereo. " + MulticamAudioOutput.playbackHelp)
            }
            Section("Panels") {
                Toggle(SettingsRow.resultJSON.title, isOn: $preferences.savesExportResult)
                    .settingsRow(.resultJSON)
                    .help("Start export panels with “Save Export Result JSON” turned on.")
                Toggle(SettingsRow.resolveOpen.title, isOn: $preferences.opensResolveTimeline)
                    .settingsRow(.resolveOpen)
                    .help("Open the timeline in DaVinci Resolve after sending it there.")
                Picker(SettingsRow.startFolder.title, selection: $preferences.exportStartFolder) {
                    Text("Automatic").tag(ExportStartFolderMode.automatic)
                    Text("Project folder").tag(ExportStartFolderMode.project)
                    Text("Source folder").tag(ExportStartFolderMode.source)
                    Text("Chosen folder").tag(ExportStartFolderMode.chosen)
                }
                .settingsRow(.startFolder)
                .help("Choose the folder export panels open in first.")
                if preferences.exportStartFolder == .chosen {
                    LabeledContent("Chosen folder") {
                        VStack(alignment: .trailing, spacing: 4) {
                            if preferences.exportStartFolderPath.isEmpty {
                                // Said once: the row has no folder yet, and the panels' fallback is in the button's help.
                                Text("Not chosen yet").foregroundStyle(.secondary)
                                    .accessibilityIdentifier("settings.export.start-folder.none")
                            } else {
                                SettingsPathText(path: preferences.exportStartFolderPath)
                                    .accessibilityIdentifier("settings.export.start-folder.path")
                            }
                            Button(preferences.exportStartFolderPath.isEmpty ? "Choose Folder…" : "Change Folder…", action: chooseFolder)
                                .accessibilityIdentifier("settings.export.start-folder.choose")
                                .help(preferences.exportStartFolderPath.isEmpty
                                      ? "Choose the folder export panels start in. Until you do, they open at their automatic location."
                                      : "Choose another folder for export panels to start in.")
                        }
                    }
                    if preferences.chosenExportFolder != nil, chosenFolderAvailable == false {
                        Label("This folder is unavailable. Export panels open at their automatic location until it is back.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.export.start-folder.unavailable")
                    }
                }
            }
            .task(id: preferences.exportStartFolder == .chosen ? preferences.exportStartFolderPath : "") {
                chosenFolderAvailable = nil
                guard preferences.exportStartFolder == .chosen, let folder = preferences.chosenExportFolder else { return }
                let available = await Task.detached(priority: .utility) { ExportStartFolder.isAvailable(folder) }.value
                guard !Task.isCancelled else { return }
                chosenFolderAvailable = available
            }
            Section {
                Toggle(SettingsRow.finishedReveal.title, isOn: $preferences.revealsFinishedExport)
                    .settingsRow(.finishedReveal)
                    .help("Show each finished export in Finder.")
                // Permission is asked only here, when the editor turns Notify on. An agent or a launch argument setting the
                // key never asks, because neither goes through this binding.
                Toggle(SettingsRow.finishedNotify.title, isOn: Binding(
                    get: { preferences.notifiesFinishedExport },
                    set: { on in
                        preferences.notifiesFinishedExport = on
                        guard on else { return }
                        Task { notificationAuthorization = await ExportCompletion.shared.requestNotificationPermission() }
                    }))
                    .settingsRow(.finishedNotify)
                    .help("Post a notification when an export finishes while MPCut is in the background.")
                if preferences.notifiesFinishedExport, notificationAuthorization == .denied {
                    HStack {
                        Label("Notifications for MPCut are turned off in System Settings.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        // No ellipsis: it opens another app, not a panel or dialog in MPCut.
                        Button("Open System Settings") { ExportCompletion.shared.openNotificationSettings() }
                            .accessibilityIdentifier("settings.export.notify.open-system-settings")
                            .help("Open Notifications in System Settings, where you can allow notifications from MPCut.")
                    }
                }
                Toggle(SettingsRow.finishedSound.title, isOn: $preferences.playsFinishedExportSound)
                    .settingsRow(.finishedSound)
                    .help("Play a sound when an export finishes.")
            } header: {
                Text("When an export finishes")
            } footer: {
                SettingsFootnote("Applies to the movie, multicam, queue, JPEG frame, Export Current Frame, ISO, Tiles program, Resolve and project exports you start. Exports an agent starts, and transcript and caption files, are excluded.")
            }
        }
        .task { notificationAuthorization = await ExportCompletion.shared.notificationAuthorization() }
    }

    private func chooseFolder() {
        let current = preferences.exportStartFolderPath
        SettingsPath.choose(title: "Choose where export panels start",
                            message: "Export panels open in this folder at the start of each window’s session.",
                            canCreateFolders: true,
                            startingIn: current.isEmpty ? nil : URL(fileURLWithPath: current, isDirectory: true)) { url in
            preferences.exportStartFolderPath = url.path
        }
    }
}
