import AppKit
import MPCutCore
import SwiftUI

struct SettingsExportPage: View {
    @ObservedObject var preferences: EditorPreferences
    /// Nil until checked. A process without an app bundle, such as the test host, always reads unavailable.
    @State private var notificationAuthorization: ExportNotificationAuthorization?

    var body: some View {
        SettingsForm(page: .export, preferences: preferences) {
            Section {
                Picker(SettingsRow.movieMode.title, selection: $preferences.defaultExportMode) {
                    ForEach(ExportMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .settingsRow(.movieMode)
                .help("Set default movie mode")
                Picker(SettingsRow.jpegPreset.title, selection: $preferences.jpegPreset) {
                    Text("Small review images").tag(JPEGPreset.review)
                    Text("Full resolution, high quality").tag(JPEGPreset.full)
                }
                .settingsRow(.jpegPreset)
                .help("Set default JPEG quality")
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
                .help("Choose the starting re-encode codec")
                Picker(SettingsRow.reencodeQuality.title, selection: $preferences.reencodeQuality) {
                    ForEach(EditorPreferences.reencodeQualities, id: \.self) { Text($0.displayName).tag($0) }
                }
                .settingsRow(.reencodeQuality)
                .help("Choose the starting H.264 and HEVC quality")
                Picker(SettingsRow.proresQuality.title, selection: $preferences.proresQuality) {
                    ForEach(EditorPreferences.proresQualities, id: \.self) { Text($0.displayName).tag($0) }
                }
                .settingsRow(.proresQuality)
                .help("Choose the starting ProRes quality")
                Picker(SettingsRow.container.title, selection: $preferences.reencodeContainer) {
                    Text("Automatic").tag(ExportContainerChoice.automatic)
                    Text("MP4").tag(ExportContainerChoice.mp4)
                    Text("MOV").tag(ExportContainerChoice.mov)
                    Text("MKV").tag(ExportContainerChoice.mkv)
                }
                .settingsRow(.container)
                .help("Automatic uses MP4 in the sequence editor and MOV in multicam. ProRes stays MOV.")
                Picker(SettingsRow.multicamAudio.title, selection: $preferences.multicamAudioLayout) {
                    ForEach(MulticamAudioOutput.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .settingsRow(.multicamAudio)
                .help(MulticamAudioOutput.playbackHelp)
            }
            Section("Panels") {
                Toggle(SettingsRow.resultJSON.title, isOn: $preferences.savesExportResult)
                    .settingsRow(.resultJSON)
                    .help("Start export panels with Save Export Result JSON on")
                Toggle(SettingsRow.resolveOpen.title, isOn: $preferences.opensResolveTimeline)
                    .settingsRow(.resolveOpen)
                    .help("Open the timeline in DaVinci Resolve after sending it")
                Picker(SettingsRow.startFolder.title, selection: $preferences.exportStartFolder) {
                    Text("Automatic").tag(ExportStartFolderMode.automatic)
                    Text("Project folder").tag(ExportStartFolderMode.project)
                    Text("Source folder").tag(ExportStartFolderMode.source)
                    Text("Chosen folder").tag(ExportStartFolderMode.chosen)
                }
                .settingsRow(.startFolder)
                .help("Choose the first folder export panels open in")
                if preferences.exportStartFolder == .chosen {
                    LabeledContent("Chosen folder") {
                        HStack {
                            Text(preferences.exportStartFolderPath.isEmpty ? "No folder selected" : preferences.exportStartFolderPath)
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(preferences.exportStartFolderPath.isEmpty ? .secondary : .primary)
                                .help(preferences.exportStartFolderPath)
                            Button(preferences.exportStartFolderPath.isEmpty ? "Choose Folder…" : "Change Folder…", action: chooseFolder)
                                .accessibilityIdentifier("settings.export.start-folder.choose")
                        }
                    }
                    if let folder = preferences.chosenExportFolder, !ExportStartFolder.isAvailable(folder) {
                        Label("This folder is unavailable. Export panels open at their usual folder until it is back.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.export.start-folder.unavailable")
                    }
                }
            }
            Section {
                Toggle(SettingsRow.finishedReveal.title, isOn: $preferences.revealsFinishedExport)
                    .settingsRow(.finishedReveal)
                    .help("Show a finished export in Finder")
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
                    .help("Post a notification when MPCut is in the background")
                if preferences.notifiesFinishedExport, notificationAuthorization == .denied {
                    HStack {
                        Label("Notifications for MPCut are turned off in System Settings.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings…") { ExportCompletion.shared.openNotificationSettings() }
                            .accessibilityIdentifier("settings.export.notify.open-system-settings")
                            .help("Allow notifications for MPCut")
                    }
                }
                Toggle(SettingsRow.finishedSound.title, isOn: $preferences.playsFinishedExportSound)
                    .settingsRow(.finishedSound)
                    .help("Play a sound when an export finishes")
            } header: {
                Text("When an export finishes")
            } footer: {
                SettingsFootnote("Applies to movie, multicam, queue, JPEG frame, ISO, Resolve and project exports. Transcript and caption files are excluded.")
            }
        }
        .task { notificationAuthorization = await ExportCompletion.shared.notificationAuthorization() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose where export panels start"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if !preferences.exportStartFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: preferences.exportStartFolderPath, isDirectory: true)
        }
        ProjectPanels.present(panel, in: NSApp.keyWindow, fromSheet: true) { accepted in
            if accepted, let url = panel.url { preferences.exportStartFolderPath = url.path }
        }
    }
}
